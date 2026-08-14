# S3 bucket (private)
resource "aws_s3_bucket" "website" {
  bucket = var.bucket_name

  tags = {
    Name = "${var.com_domain_name}-website"
  }
}

resource "aws_s3_bucket_versioning" "website" {
  bucket = aws_s3_bucket.website.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Enforce bucket ownership
resource "aws_s3_bucket_ownership_controls" "website_ownership" {
  bucket = aws_s3_bucket.website.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "website_access_block" {
  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Origin Access Control (OAC) for CloudFront
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "website-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront distribution
# Security response headers for browser responses. HSTS, nosniff, DENY framing,
# and a conservative referrer policy. `preload` is intentionally left off HSTS
# until we're confident. No CSP here — added separately if/when scoped to the app.
resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "radomskyi-com-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

resource "aws_cloudfront_distribution" "website_distribution" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  aliases = [
    var.dev_domain_name,
    "www.${var.dev_domain_name}",
    var.com_domain_name,
    "www.${var.com_domain_name}"
  ]

  origin {
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_id                = "s3-website"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "s3-website"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.redirect.arn
    }

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

  # SPA fallback - serve the bare app shell for genuine misses (client-side routing).
  #
  # /200.html, not /index.html: index.html is the fully prerendered home page, so
  # using it here served home page markup at every unmatched URL. The viewer-request
  # function now rewrites extensionless URLs to their real .html files, which leaves
  # these responses for what they are meant to be - actual 404s and dynamic routes.
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/200.html"
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/200.html"
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Bucket policy – allow only CloudFront distribution to access
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
