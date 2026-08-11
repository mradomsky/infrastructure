# ============================================================
# Push notifications
#
# Web Push delivered by a dedicated scheduled Lambda (stagehopper-notifier), fired every
# minute by EventBridge. It reads each enabled user's settings + picks and sends a push
# some minutes before a marked set starts. Everything here is additive — no existing
# resource is modified; new IAM is attached as separate inline policies.
#
# Application code:  mradomsky/stagehopper (lambda/notifier.ts, routes in lambda/index.ts).
# Code deploys are owned by that repo's CI via `aws lambda update-function-code`.
# ============================================================

# ---- Secrets (set out-of-band on the function, like GOOGLE_CLIENT_ID) ----

variable "vapid_private_key" {
  description = "VAPID private key used by the notifier to sign Web Push requests"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vapid_public_key" {
  description = "VAPID public key (also shipped to the client as VITE_VAPID_PUBLIC_KEY)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vapid_subject" {
  description = "VAPID subject, a mailto: contact for the push service"
  type        = string
  default     = ""
}

# ---- DynamoDB ----
#
# Notification preferences (enabled, leadMinutes, notifyAttending, notifyMaybe) live on the
# `stagehopper-users` row (see main.tf), not a separate table.

# Per-device Web Push subscriptions (one row per device).
resource "aws_dynamodb_table" "stagehopper_push_subscriptions" {
  name         = "stagehopper-push-subscriptions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"
  range_key    = "endpoint"

  attribute {
    name = "userId"
    type = "S"
  }

  attribute {
    name = "endpoint"
    type = "S"
  }
}

# Sent-markers so a notification fires at most once per (user, performance). TTL reaps
# them a few hours after the set; the app writes `ttl` as epoch seconds.
resource "aws_dynamodb_table" "stagehopper_notif_dedup" {
  name         = "stagehopper-notif-dedup"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"
  range_key    = "performanceId"

  attribute {
    name = "userId"
    type = "S"
  }

  attribute {
    name = "performanceId"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

# ---- IAM: extend the API Lambda for the notification routes ----

# The 4 notification routes on the existing `stagehopper` function need access to the
# push-subscriptions table (the settings now live on `stagehopper-users`, already granted
# by the base policy). Attached as its own inline policy so the base policy is untouched.
resource "aws_iam_role_policy" "stagehopper_lambda_notifications" {
  name = "stagehopper-lambda-notifications-policy"
  role = aws_iam_role.stagehopper_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
        ]
        Resource = [
          aws_dynamodb_table.stagehopper_push_subscriptions.arn,
        ]
      }
    ]
  })
}

# ---- IAM: the notifier's own role ----

resource "aws_iam_role" "stagehopper_notifier" {
  name = "stagehopper-notifier-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "stagehopper_notifier" {
  name = "stagehopper-notifier-policy"
  role = aws_iam_role.stagehopper_notifier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "UsersScan"
        Effect = "Allow"
        # Scans the users table for notification-enabled users and reads each one's `rooms`
        # map off the same row (no separate membership lookup). The notifier never writes it.
        Action   = ["dynamodb:Scan", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.stagehopper_users.arn
      },
      {
        Sid      = "SubscriptionsQueryAndPrune"
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.stagehopper_push_subscriptions.arn
      },
      {
        Sid      = "DedupConditionalPut"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.stagehopper_notif_dedup.arn
      },
      {
        Sid      = "SelectionsRead"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = aws_dynamodb_table.stagehopper_selections.arn
      },
      {
        Sid      = "FestivalDataRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.website.arn}/data/*"
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

# ---- Notifier Lambda ----

# Code deploys owned by mradomsky/stagehopper CI (`update-function-code`, targeting this
# exact function name). Terraform manages only configuration; lambda_seed.zip is used
# solely on initial creation, before the first real bundle is shipped.
resource "aws_lambda_function" "stagehopper_notifier" {
  function_name = "stagehopper-notifier"
  role          = aws_iam_role.stagehopper_notifier.arn
  handler       = "notifier.handler"
  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  filename      = "${path.module}/lambda_seed.zip"
  # Bursty: loops enabled users, reads their picks, sends each push. Longer than the API fn.
  timeout = 30

  # VAPID keys are secrets injected out-of-band (empty-string defaults so a secret-less
  # plan/apply doesn't error, ignore_changes so it can't silently blank them — same
  # contract as GOOGLE_CLIENT_ID on the API function).
  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash,
      environment[0].variables["VAPID_PRIVATE_KEY"],
      environment[0].variables["VAPID_PUBLIC_KEY"],
      environment[0].variables["VAPID_SUBJECT"],
    ]
  }

  environment {
    variables = {
      TABLE_NAME               = aws_dynamodb_table.stagehopper_selections.name
      USERS_TABLE              = aws_dynamodb_table.stagehopper_users.name
      PUSH_SUBSCRIPTIONS_TABLE = aws_dynamodb_table.stagehopper_push_subscriptions.name
      NOTIF_DEDUP_TABLE        = aws_dynamodb_table.stagehopper_notif_dedup.name
      SITE_BUCKET              = aws_s3_bucket.website.id
      VAPID_PRIVATE_KEY        = var.vapid_private_key
      VAPID_PUBLIC_KEY         = var.vapid_public_key
      VAPID_SUBJECT            = var.vapid_subject
    }
  }
}

# ---- EventBridge: fire the notifier every minute ----

resource "aws_cloudwatch_event_rule" "stagehopper_notifier" {
  name                = "stagehopper-notifier-schedule"
  description         = "Fires the StageHopper push notifier every minute."
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "stagehopper_notifier" {
  rule = aws_cloudwatch_event_rule.stagehopper_notifier.name
  arn  = aws_lambda_function.stagehopper_notifier.arn
}

resource "aws_lambda_permission" "stagehopper_notifier_events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stagehopper_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stagehopper_notifier.arn
}

# ---- Alarm (mirror of the API Lambda's) ----

resource "aws_cloudwatch_metric_alarm" "stagehopper_notifier_errors" {
  alarm_name          = "stagehopper-notifier-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "stagehopper-notifier Lambda returned one or more errors."
  dimensions = {
    FunctionName = aws_lambda_function.stagehopper_notifier.function_name
  }
  alarm_actions = [data.terraform_remote_state.personal.outputs.alerts_topic_arn]
  ok_actions    = [data.terraform_remote_state.personal.outputs.alerts_topic_arn]
}

# ---- API Gateway routes (target the existing stagehopper integration) ----

resource "aws_apigatewayv2_route" "get_notifications" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/users/me/notifications"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "put_notifications" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "PUT /api/stagehopper/users/me/notifications"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "add_push_subscription" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "POST /api/stagehopper/users/me/notifications/subscription"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "remove_push_subscription" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "DELETE /api/stagehopper/users/me/notifications/subscription"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

# ---- CI: let the deploy role ship the notifier bundle ----

resource "aws_iam_role_policy" "stagehopper_notifier_github_actions" {
  name = "stagehopper-notifier-github-actions-policy"
  role = data.aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "NotifierLambdaDeploy"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode"]
        Resource = aws_lambda_function.stagehopper_notifier.arn
      }
    ]
  })
}
