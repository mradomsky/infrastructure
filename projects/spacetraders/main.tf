# ============================================================
# Cross-repo state — shared EC2 host
#
# Only navigation-service state is read now, for the backend host's Elastic IP.
# Routing to the individual services moved to the on-host Caddy edge proxy, so the
# per-service port outputs this stack used to read are no longer needed here.
# ============================================================

data "terraform_remote_state" "navigation_service" {
  backend = "s3"

  config = {
    bucket = "radomskyi-tfstate"
    key    = "navigation-service/terraform.tfstate"
    region = var.aws_region
  }
}

# The shared secret proving a request came through *our* CloudFront distribution.
# Created out-of-band as an SSM SecureString and read by the on-host Caddy proxy
# too, so both sides use one source of truth. The value lands in this stack's
# state (private bucket, 7-day noncurrent expiry) — acceptable, and rotatable if
# it ever leaks. (The #32 issue suggested a TF_VAR; a single SSM source avoids
# keeping the CloudFront header and Caddy's expected value manually in sync.)
data "aws_ssm_parameter" "origin_verify" {
  name = var.origin_verify_param_name
}

# ============================================================
# S3 — static Vite build
# ============================================================

resource "aws_s3_bucket" "website" {
  bucket = var.bucket_name

  tags = {
    Name = "${var.domain_name}-website"
  }
}

resource "aws_s3_bucket_versioning" "website" {
  bucket = aws_s3_bucket.website.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "website_ownership" {
  bucket = aws_s3_bucket.website.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "website_access_block" {
  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ============================================================
# CloudFront — OAC + distribution
# ============================================================

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "spacetraders-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "website_distribution" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  aliases             = [var.domain_name]

  origin {
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_id                = "s3-website"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  # Single HTTPS origin: the on-host Caddy edge proxy terminates TLS on 443 and
  # routes each /api/<service>/* path to the right container. TLS replaces the old
  # per-service plaintext http-only origins (one per port); Caddy owns the routing
  # now, so path patterns — not distinct origins — decide the backend.
  origin {
    domain_name = aws_route53_record.backend_host.fqdn
    origin_id   = "backend"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Proves the request came through our distribution. Caddy rejects anything
    # missing this header with 403, so a stranger's distribution pointed at the
    # host (the prefix list can't tell them apart) cannot reach the backends.
    custom_header {
      name  = "X-Origin-Verify"
      value = data.aws_ssm_parameter.origin_verify.value
    }
  }

  # Backend routes — no caching, all methods + auth/CORS headers forwarded.
  # Every service now self-mounts under a consistent /api/<service>/v1 prefix,
  # plus an unversioned /api/<service>/health liveness probe used by
  # command-interface's browser-side SystemStatus panel (health is
  # deliberately not under /v1 — see each service's health handler).
  dynamic "ordered_cache_behavior" {
    # All backend paths go to the single Caddy origin, which routes by prefix.
    for_each = toset([
      "/api/navigation/v1/*",
      "/api/navigation/health",
      "/api/agent/v1/*",
      "/api/agent/health",
      "/api/fleet/v1/*",
      "/api/fleet/health",
      "/api/automation/v1/*",
      "/api/automation/health",
      "/api/st-gateway/health",
    ])

    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "backend"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods         = ["GET", "HEAD"]
      compress               = false

      forwarded_values {
        query_string = true
        headers      = ["Origin", "Authorization", "Content-Type", "Access-Control-Request-Headers", "Access-Control-Request-Method"]
        cookies {
          forward = "none"
        }
      }

      min_ttl     = 0
      default_ttl = 0
      max_ttl     = 0
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-website"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # SPA fallback
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.spacetraders.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_s3_bucket_policy" "website_policy" {
  bucket = aws_s3_bucket.website.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.website.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.website_distribution.arn
          }
        }
      }
    ]
  })
}

# ============================================================
# ACM Certificate (us-east-1 — required for CloudFront)
# ============================================================

resource "aws_acm_certificate" "spacetraders" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "spacetraders" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.spacetraders.arn
  validation_record_fqdns = [for r in aws_route53_record.spacetraders_cert_validation : r.fqdn]
}

# ============================================================
# Route53
# ============================================================

data "aws_route53_zone" "parent" {
  name = var.parent_domain
}

# CloudFront custom origins reject bare IP addresses as domain_name ("The parameter origin
# name cannot be an IP address") — this gives the shared EC2 host a real DNS name for all
# three backend origins to use.
resource "aws_route53_record" "backend_host" {
  zone_id = data.aws_route53_zone.parent.zone_id
  name    = "spacetraders-backend.${var.parent_domain}"
  type    = "A"
  ttl     = 300
  records = [data.terraform_remote_state.navigation_service.outputs.navigation_service_ec2_ip]
}

resource "aws_route53_record" "spacetraders_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.spacetraders.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.parent.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_route53_record" "spacetraders" {
  zone_id = data.aws_route53_zone.parent.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.website_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

# ============================================================
# GitHub Actions IAM — dedicated CI deployment role for
# V-M-Pioneer-Trading/command-interface (not the shared
# github-website-deployment-worker role, which is managed in bootstrap/
# and deliberately scoped to the mradomsky app repos only)
# ============================================================

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "command_interface_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:V-M-Pioneer-Trading/command-interface:*"]
    }
  }
}

resource "aws_iam_role" "command_interface_deploy" {
  name               = "command-interface-deploy"
  assume_role_policy = data.aws_iam_policy_document.command_interface_deploy_trust.json
}

resource "aws_iam_role_policy" "command_interface_deploy" {
  name = "command-interface-deploy-policy"
  role = aws_iam_role.command_interface_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3DeployBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.website.arn
      },
      {
        Sid      = "S3DeployObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.website.arn}/*"
      },
      {
        Sid      = "CloudFrontInvalidate"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations"]
        Resource = aws_cloudfront_distribution.website_distribution.arn
      }
    ]
  })
}
