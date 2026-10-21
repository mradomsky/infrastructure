# ============================================================
# Festival space — Picks, chat, moderation
#
# Every Festival is one open space (mradomsky/stagehopper#203): Picks and Messages are keyed
# by Festival, not by Room. Everything here is additive. The Room tables, routes and env vars
# stay until the release that stops reading them is live; their removal is a later, separate
# change (app repo: docs/rooms-removal-infra.md).
#
# Change-lists this file implements, all in mradomsky/stagehopper:
#   docs/festival-picks-infra.md  §1-4, §7   (#204, #207)
#   docs/festival-chat-infra.md   §1-4       (#205)
#   docs/moderation-infra.md      §1         (#209)
# Not here: picks §5, the `username` claim on Clerk's `apigw` JWT template, is Clerk
# dashboard configuration; picks §6 is the one-off migration an operator runs by hand.
#
# Apply before the `v*` tag that ships any of them (app CLAUDE.md trap 2): with PICKS_TABLE
# or MESSAGES_TABLE unset the Lambda fails closed, and the notifier throws at start.
# ============================================================

# ---- DynamoDB ----

# One row per (Festival, user): the user's Picks for that Festival plus a denormalised copy
# of their handle and colour. `userId-index` is how a handle or colour change reaches every
# row of that user, and how an admin user delete finds them. KEYS_ONLY: both callers refetch
# or delete by key.
resource "aws_dynamodb_table" "stagehopper_picks" {
  name                        = "stagehopper-picks"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "festivalId"
  range_key                   = "userId"
  deletion_protection_enabled = true

  attribute {
    name = "festivalId"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }

  global_secondary_index {
    name            = "userId-index"
    hash_key        = "userId"
    range_key       = "festivalId"
    projection_type = "KEYS_ONLY"
  }

  # Real user data — point-in-time recovery for accidental writes/deletes.
  point_in_time_recovery {
    enabled = true
  }
}

# One row per Message (PK festivalId, SK messageId). A messageId starts with a zero-padded
# millisecond timestamp, so the range key sorts by time and the chat reads are plain
# Queries. No TTL: Messages stay until deleted. `userId-index` is read by the admin user
# delete cascade only; it is created now because a GSI key cannot change later.
resource "aws_dynamodb_table" "stagehopper_messages" {
  name                        = "stagehopper-messages"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "festivalId"
  range_key                   = "messageId"
  deletion_protection_enabled = true

  attribute {
    name = "festivalId"
    type = "S"
  }

  attribute {
    name = "messageId"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }

  global_secondary_index {
    name            = "userId-index"
    hash_key        = "userId"
    range_key       = "messageId"
    projection_type = "KEYS_ONLY"
  }

  # Real user data — point-in-time recovery for accidental writes/deletes.
  point_in_time_recovery {
    enabled = true
  }
}

# ---- IAM: extend the API Lambda ----

# Attached as its own inline policy so the base policy (main.tf) is untouched; the grants
# are exactly what the routes below use. The users-table writes these features also make
# (ban/unban UpdateItem, the tombstone PutItem, the rate-limit UpdateItem) and the festivals
# GetItem are already in the base policy.
resource "aws_iam_role_policy" "stagehopper_lambda_festival_space" {
  name = "stagehopper-lambda-festival-space-policy"
  role = aws_iam_role.stagehopper_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PicksReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:Query",
        ]
        Resource = aws_dynamodb_table.stagehopper_picks.arn
      },
      {
        Sid    = "MessagesReadWrite"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:Query",
        ]
        Resource = aws_dynamodb_table.stagehopper_messages.arn
      },
      {
        # Query on a GSI is authorised against the index ARN, not the table's.
        Sid    = "UserIndexQuery"
        Effect = "Allow"
        Action = ["dynamodb:Query"]
        Resource = [
          "${aws_dynamodb_table.stagehopper_picks.arn}/index/userId-index",
          "${aws_dynamodb_table.stagehopper_messages.arn}/index/userId-index",
        ]
      }
    ]
  })
}

# ---- API Gateway routes: Picks (festival-picks-infra.md §4) ----

# Public read: the Timetable shows everyone's Picks to signed-out visitors too. Not cached at
# the edge — the /api/* behaviour has TTL 0 and forwards the query string.
resource "aws_apigatewayv2_route" "get_festival_picks" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "GET /api/stagehopper/festivals/{id}/picks"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "get_festival_picks_me" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "GET /api/stagehopper/festivals/{id}/picks/me"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

resource "aws_apigatewayv2_route" "put_festival_picks" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "PUT /api/stagehopper/festivals/{id}/picks"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

resource "aws_apigatewayv2_route" "get_my_profile" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "GET /api/stagehopper/users/me/profile"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

resource "aws_apigatewayv2_route" "put_my_profile" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "PUT /api/stagehopper/users/me/profile"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

# ---- API Gateway routes: chat (festival-chat-infra.md §4) ----

# Public reads. `GET messages` takes `after`/`before` query parameters, which the /api/*
# behaviour forwards.
resource "aws_apigatewayv2_route" "get_festival_messages" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "GET /api/stagehopper/festivals/{id}/messages"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "get_festival_summary" {
  api_id    = aws_apigatewayv2_api.stagehopper.id
  route_key = "GET /api/stagehopper/festivals/{id}/summary"
  target    = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
}

resource "aws_apigatewayv2_route" "post_festival_message" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "POST /api/stagehopper/festivals/{id}/messages"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

# Deliberately no `admin` scope: the Lambda lets an author delete their own Message and an
# admin-scoped caller delete any, so the gateway cannot decide this one.
resource "aws_apigatewayv2_route" "delete_festival_message" {
  api_id             = aws_apigatewayv2_api.stagehopper.id
  route_key          = "DELETE /api/stagehopper/festivals/{id}/messages/{messageId}"
  target             = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.clerk.id
}

# ---- API Gateway routes: moderation (moderation-infra.md §1) ----

# Gated on the `admin` scope like every other /admin/* route. `{userId}` arrives URL-encoded
# (`clerk%3A...`); API Gateway decodes it before the Lambda sees it.
resource "aws_apigatewayv2_route" "admin_ban_user" {
  api_id               = aws_apigatewayv2_api.stagehopper.id
  route_key            = "POST /api/stagehopper/admin/users/{userId}/ban"
  target               = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.clerk.id
  authorization_scopes = ["admin"]
}

resource "aws_apigatewayv2_route" "admin_unban_user" {
  api_id               = aws_apigatewayv2_api.stagehopper.id
  route_key            = "DELETE /api/stagehopper/admin/users/{userId}/ban"
  target               = "integrations/${aws_apigatewayv2_integration.stagehopper.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.clerk.id
  authorization_scopes = ["admin"]
}
