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

# ---- VAPID configuration ----
#
# The private key is NOT a variable and never reaches Terraform: a value set as a
# Lambda environment variable is recorded in state on every refresh, so it would
# sit in plaintext in the state object and in each retained version of it
# (`ignore_changes` hides the diff, not the read). The parameter is created out of
# band as a SecureString and the notifier resolves it at runtime — see
# `lambda/secrets.ts` in mradomsky/stagehopper:
#
#   aws ssm put-parameter --name /stagehopper/vapid-private-key \
#     --type SecureString --value "<key>"
#
# The public key and subject stay plain variables: the browser receives both, so
# there is nothing to protect and no reason to pay a cold-start SSM read.

data "aws_caller_identity" "current" {}

# KMS resource-based matching needs the key ARN, not the alias ARN.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

variable "vapid_private_key_param" {
  description = "Name of the SSM SecureString holding the VAPID private key. The value never passes through Terraform."
  type        = string
  default     = "/stagehopper/vapid-private-key"
}

variable "vapid_public_key" {
  description = "VAPID public key (also shipped to the client as VITE_VAPID_PUBLIC_KEY)"
  type        = string
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
  name                        = "stagehopper-push-subscriptions"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "userId"
  range_key                   = "endpoint"
  deletion_protection_enabled = true
  # No PITR: clients re-subscribe, so these rows are regenerable.

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
  name                        = "stagehopper-notif-dedup"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "userId"
  range_key                   = "performanceId"
  deletion_protection_enabled = true
  # No PITR: sent-markers are TTL-reaped within hours, worthless to restore.

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

# The notification routes on the existing `stagehopper` function need access to the
# push-subscriptions table (the settings now live on `stagehopper-users`, already granted
# by the base policy). It also invokes the notifier for the admin "send test notification"
# route — reusing the one function that holds web-push and the VAPID keys, rather than
# duplicating them here. Attached as its own inline policy so the base policy is untouched.
resource "aws_iam_role_policy" "stagehopper_lambda_notifications" {
  name = "stagehopper-lambda-notifications-policy"
  role = aws_iam_role.stagehopper_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PushSubscriptions"
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
      },
      {
        # POST /admin/users/{userId}/test-notification invokes the notifier synchronously
        # with a { test, userId } event. Identity-based invoke is sufficient for an
        # in-account caller — no aws_lambda_permission is needed on the notifier.
        Sid      = "InvokeNotifierForTestSend"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.stagehopper_notifier.arn
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
        # map off the same row (no separate membership lookup). Scan is the only action the
        # notifier uses here — it never GetItems or writes the users table.
        Action   = ["dynamodb:Scan"]
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
        # The notifier resolves its Web Push signing key from Parameter Store at
        # runtime so the value stays out of Terraform state. Decrypt is needed
        # too: the parameter is a SecureString under the SSM default key.
        Sid      = "VapidPrivateKeyRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.vapid_private_key_param}"
      },
      {
        Sid      = "VapidPrivateKeyDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.aws_kms_alias.ssm.target_key_arn
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

  # The public key and subject are injected out-of-band (empty-string defaults so a
  # value-less plan/apply doesn't error, ignore_changes so it can't silently blank
  # them — same contract as GOOGLE_CLIENT_ID on the API function).
  #
  # VAPID_PRIVATE_KEY is deliberately absent from this list. The key is no longer a
  # Lambda environment variable at all: the notifier resolves it from SSM at runtime,
  # so nothing here should keep a stale copy alive on the function — or record one in
  # state on the next refresh.
  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash,
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
      VAPID_PRIVATE_KEY_PARAM  = var.vapid_private_key_param
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

# These four stay POST/PUT with a body. Unlike the reads in main.tf they were never POSTs
# only to carry a token — the body carries a push `endpoint`, an opaque and long
# push-service URL that has no business in a query string.
resource "aws_apigatewayv2_route" "get_notifications" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "POST /api/stagehopper/users/me/notifications"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

resource "aws_apigatewayv2_route" "put_notifications" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "PUT /api/stagehopper/users/me/notifications"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

resource "aws_apigatewayv2_route" "add_push_subscription" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "POST /api/stagehopper/users/me/notifications/subscription"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

resource "aws_apigatewayv2_route" "remove_push_subscription" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "DELETE /api/stagehopper/users/me/notifications/subscription"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

# Admin-only: fire an on-demand test push to a user's devices. Gated at the gateway on the
# `admin` scope, like every other admin route (see the authorizer in main.tf).
resource "aws_apigatewayv2_route" "admin_test_notification" {
  api_id               = aws_apigatewayv2_api.stagehopper.id
  route_key            = "POST /api/stagehopper/admin/users/{userId}/test-notification"
  target               = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.clerk.id
  authorization_scopes = ["admin"]
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
