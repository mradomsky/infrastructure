# ============================================================
# Shared state — alerts topic
# ============================================================

data "terraform_remote_state" "personal" {
  backend = "s3"

  config = {
    bucket = "radomskyi-tfstate"
    key    = "personal/terraform.tfstate"
    region = var.aws_region
  }
}

# ============================================================
# S3 — static SvelteKit build
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

# Admin cover-image uploads PUT straight from the browser to S3 via a presigned URL,
# so the bucket must allow cross-origin PUT from the site origin. Everything the site
# reads is served through CloudFront (same-origin), so only the upload path needs CORS.
resource "aws_s3_bucket_cors_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  cors_rule {
    allowed_origins = ["https://${var.domain_name}"]
    allowed_methods = ["PUT"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# ============================================================
# CloudFront — OAC + distribution
# ============================================================

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "stagehopper-oac"
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

  origin {
    domain_name = replace(aws_apigatewayv2_api.stagehopper.api_endpoint, "https://", "")
    origin_id   = "apigw-stagehopper"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # API routes — no caching, all methods forwarded
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "apigw-stagehopper"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = false

    forwarded_values {
      query_string = true
      headers      = ["Origin", "Access-Control-Request-Headers", "Access-Control-Request-Method"]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
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
    acm_certificate_arn      = aws_acm_certificate_validation.stagehopper.certificate_arn
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
# DynamoDB
# ============================================================

resource "aws_dynamodb_table" "stagehopper_selections" {
  name         = "stagehopper-selections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "roomId"
  range_key    = "userId"

  attribute {
    name = "roomId"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
}

# One row per user (PK userId). A `rooms` map (roomId -> {color, updatedAt, name}) is the
# inverse index of the selections table — the user's room list — and replaces the old
# room-memberships table. Notification settings (enabled, leadMinutes, notifyAttending,
# notifyMaybe, folded in from the old user-settings table) live on the same row. Only the
# key is a defined attribute; `rooms` and the settings are schemaless.
resource "aws_dynamodb_table" "stagehopper_users" {
  name         = "stagehopper-users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"

  attribute {
    name = "userId"
    type = "S"
  }
}

# ============================================================
# Lambda IAM
# ============================================================

resource "aws_iam_role" "stagehopper_lambda" {
  name = "stagehopper-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "stagehopper_lambda" {
  name = "stagehopper-lambda-policy"
  role = aws_iam_role.stagehopper_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          # UpdateItem backs the users-table writes: a save SETs the user's `rooms.<id>`
          # entry and their settings; leave/room-delete REMOVE it.
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          # Scan backs the admin room/user listing (no GSI for a global index);
          # BatchWriteItem backs the chunked admin deletes across both tables.
          "dynamodb:Scan",
          "dynamodb:BatchWriteItem",
          "dynamodb:TransactWriteItems",
        ]
        Resource = [
          aws_dynamodb_table.stagehopper_selections.arn,
          aws_dynamodb_table.stagehopper_users.arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "AdminDataReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:HeadObject",
        ]
        # Covers data/festivals.json, data/timetable-{id}.json,
        # data/festival-images/* and data/festival-maps/* — the presigned uploads are
        # signed with this role's credentials, so it needs PutObject even though the
        # browser is what actually performs the PUT.
        Resource = "${aws_s3_bucket.website.arn}/data/*"
      },
      {
        # Without ListBucket, S3 answers a GET/HEAD on a *missing* key with 403, not
        # 404. The write-once timetable import HEADs data/timetable-{id}.json to check
        # it doesn't exist yet; a 403 there is indistinguishable from a real error and
        # 500s the import. ListBucket makes the missing-key case a clean 404.
        Sid      = "AdminDataListBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.website.arn
      },
      {
        Sid      = "AdminDataInvalidate"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = aws_cloudfront_distribution.website_distribution.arn
      }
    ]
  })
}

# ============================================================
# Lambda function
# ============================================================

# Code deploys are owned by mradomsky/stagehopper CI via
# `aws lambda update-function-code` — Terraform manages only configuration.
# lambda_seed.zip is used solely on initial creation.
resource "aws_lambda_function" "stagehopper" {
  function_name = "stagehopper"
  role          = aws_iam_role.stagehopper_lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  filename      = "${path.module}/lambda_seed.zip"
  timeout       = 10

  # GOOGLE_CLIENT_ID and ADMIN_EMAILS are secrets injected at apply time; they have
  # empty-string defaults so a plan/apply run without them doesn't error. Ignoring
  # them here means such a run also can't silently blank them in the live function —
  # a secret-less `apply` once wiped auth in prod. They're set out-of-band and persist.
  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash,
      environment[0].variables["GOOGLE_CLIENT_ID"],
      environment[0].variables["ADMIN_EMAILS"],
    ]
  }

  environment {
    variables = {
      TABLE_NAME             = aws_dynamodb_table.stagehopper_selections.name
      USERS_TABLE            = aws_dynamodb_table.stagehopper_users.name
      SITE_ORIGIN            = "https://${var.domain_name}"
      GOOGLE_CLIENT_ID       = var.google_client_id
      ADMIN_EMAILS           = var.admin_emails
      SITE_BUCKET            = aws_s3_bucket.website.id
      CF_DISTRIBUTION_ID     = aws_cloudfront_distribution.website_distribution.id
    }
  }
}

resource "aws_lambda_permission" "stagehopper_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stagehopper.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.stagehopper.execution_arn}/*/*"
}

resource "aws_cloudwatch_metric_alarm" "stagehopper_lambda_errors" {
  alarm_name          = "stagehopper-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "stagehopper Lambda returned one or more errors."
  dimensions = {
    FunctionName = aws_lambda_function.stagehopper.function_name
  }
  alarm_actions = [data.terraform_remote_state.personal.outputs.alerts_topic_arn]
  ok_actions    = [data.terraform_remote_state.personal.outputs.alerts_topic_arn]
}

# ============================================================
# API Gateway HTTP API
# ============================================================

resource "aws_apigatewayv2_api" "stagehopper" {
  name          = "stagehopper-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins     = ["https://${var.domain_name}"]
    allow_methods     = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    allow_headers     = ["Content-Type"]
    allow_credentials = true
    max_age           = 300
  }
}

resource "aws_apigatewayv2_integration" "stagehopper" {
  api_id                 = aws_apigatewayv2_api.stagehopper.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.stagehopper.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "create_room" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/rooms"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "get_selections" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "GET /api/stagehopper/rooms/{roomId}/selections"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "put_selections_self" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "PUT /api/stagehopper/rooms/{roomId}/selections"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "delete_selections_self" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "DELETE /api/stagehopper/rooms/{roomId}/selections"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "list_my_rooms" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/users/me/rooms"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_me" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/admin/me"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_put_festivals" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "PUT /api/stagehopper/admin/festivals"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_festival_image_upload" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/admin/festivals/{id}/image-upload"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_festival_map_upload" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/admin/festivals/{id}/map-upload"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_festival_timetable_import" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/admin/festivals/{id}/timetable-import"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_festival_timetable_patch" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "PATCH /api/stagehopper/admin/festivals/{id}/timetable"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_list_rooms" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/admin/rooms"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_list_users" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/admin/users"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_delete_room" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "DELETE /api/stagehopper/admin/rooms/{roomId}"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "admin_delete_user" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "DELETE /api/stagehopper/admin/users/{userId}"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_stage" "stagehopper_default" {
  api_id      = aws_apigatewayv2_api.stagehopper.id
  name        = "$default"
  auto_deploy = true
}

# ============================================================
# ACM Certificate (us-east-1 — required for CloudFront)
# ============================================================

resource "aws_acm_certificate" "stagehopper" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "stagehopper" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.stagehopper.arn
  validation_record_fqdns = [for r in aws_route53_record.stagehopper_cert_validation : r.fqdn]
}

# ============================================================
# Route53
# ============================================================

data "aws_route53_zone" "parent" {
  name = var.parent_domain
}

resource "aws_route53_record" "stagehopper_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.stagehopper.domain_validation_options : dvo.domain_name => {
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

resource "aws_route53_record" "stagehopper" {
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
# GitHub Actions IAM — CI deployment from mradomsky/stagehopper
# ============================================================

data "aws_iam_role" "github_actions" {
  name = "github-website-deployment-worker"
}

resource "aws_iam_role_policy" "stagehopper_github_actions" {
  name = "stagehopper-github-actions-policy"
  role = data.aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3DeployBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = "arn:aws:s3:::${var.bucket_name}"
      },
      {
        Sid      = "S3DeployObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.bucket_name}/*"
      },
      {
        Sid      = "CloudFrontInvalidate"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations"]
        Resource = aws_cloudfront_distribution.website_distribution.arn
      },
      {
        Sid      = "LambdaDeploy"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode"]
        Resource = aws_lambda_function.stagehopper.arn
      }
    ]
  })
}
