# S3 bucket (private)
resource "aws_s3_bucket" "website" {
  bucket = var.bucket_name

  tags = {
    Name        = "${var.domain_name}-website"
    Environment = var.environment
    Project     = "My Website"
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

  # SPA fallback - serve index.html for 404s (client-side routing)
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
    acm_certificate_arn      = var.acm_certificate_arn
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

# ============================================================
# StageHopper — DynamoDB
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

  tags = {
    Project     = "StageHopper"
    Environment = var.environment
  }
}

# ============================================================
# StageHopper — Lambda IAM
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

  tags = {
    Project = "StageHopper"
  }
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
          "dynamodb:Query",
        ]
        Resource = aws_dynamodb_table.stagehopper_selections.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ============================================================
# StageHopper — Lambda function
# ============================================================

# Code deploys are owned by the app repo (radomskyi.com) CI via
# `aws lambda update-function-code` — Terraform manages only the function's
# configuration. lambda_seed.zip is used solely on initial creation.
resource "aws_lambda_function" "stagehopper" {
  function_name = "stagehopper"
  role          = aws_iam_role.stagehopper_lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  filename      = "${path.module}/lambda_seed.zip"
  timeout       = 10

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.stagehopper_selections.name
      SITE_ORIGIN = "https://${var.domain_name}"
    }
  }

  tags = {
    Project = "StageHopper"
  }
}

resource "aws_lambda_permission" "stagehopper_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stagehopper.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.stagehopper.execution_arn}/*/*"
}

# ============================================================
# StageHopper — API Gateway HTTP API
# ============================================================

resource "aws_apigatewayv2_api" "stagehopper" {
  name          = "stagehopper-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins     = ["https://${var.domain_name}"]
    allow_methods     = ["GET", "POST", "PUT", "OPTIONS"]
    allow_headers     = ["Content-Type"]
    allow_credentials = true
    max_age           = 300
  }

  tags = {
    Project = "StageHopper"
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

resource "aws_apigatewayv2_route" "put_selections" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "PUT /api/stagehopper/rooms/{roomId}/selections/{userId}"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "put_selections_self" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "PUT /api/stagehopper/rooms/{roomId}/selections"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_stage" "stagehopper_default" {
  api_id      = aws_apigatewayv2_api.stagehopper.id
  name        = "$default"
  auto_deploy = true
}

# ============================================================
# GitHub Actions — Terraform deployment permissions
# ============================================================

data "aws_iam_role" "github_actions" {
  name = "github-website-deployment-worker"
}

resource "aws_iam_role_policy" "github_actions_terraform" {
  name = "terraform-infrastructure-policy"
  role = data.aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Terraform"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${var.bucket_name}",
          "arn:aws:s3:::${var.bucket_name}/*"
        ]
      },
      {
        Sid      = "CloudFrontTerraform"
        Effect   = "Allow"
        Action   = ["cloudfront:*"]
        Resource = "*"
      },
      {
        Sid      = "DynamoDBTerraform"
        Effect   = "Allow"
        Action   = ["dynamodb:*"]
        Resource = "*"
      },
      {
        Sid    = "IAMTerraform"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:UpdateRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:GetRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:PassRole",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
        ]
        Resource = "*"
      },
      {
        Sid      = "LambdaTerraform"
        Effect   = "Allow"
        Action   = ["lambda:*"]
        Resource = "*"
      },
      {
        Sid      = "APIGatewayTerraform"
        Effect   = "Allow"
        Action   = ["apigateway:*", "execute-api:*"]
        Resource = "*"
      },
      {
        Sid      = "LogsTerraform"
        Effect   = "Allow"
        Action   = ["logs:*"]
        Resource = "*"
      },
    ]
  })
}
