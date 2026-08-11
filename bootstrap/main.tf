terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"

  default_tags {
    tags = {
      Project   = "infrastructure-bootstrap"
      Terraform = "true"
    }
  }
}

# ---------------------------------------------------------------------------
# Terraform state bucket
#
# Holds state for every stack in this repo EXCEPT this bootstrap stack itself
# (chicken-and-egg: this stack uses local state, see README).
# Locking uses Terraform >= 1.10 native S3 lockfiles (use_lockfile = true in
# each stack's backend block) — no DynamoDB table needed.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = "radomskyi-tfstate"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms" # AWS-managed aws/s3 key
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC — read-only role for `terraform plan` in CI
#
# CI must run plan with -lock=false: this role is read-only and cannot write
# the S3 lockfile. Apply is always run manually from a workstation.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Scoped to the pull_request context only (plan.yml runs on `pull_request`),
      # not the old `:*` wildcard that also matched branch pushes, tags and any
      # environment. Once this repo is public, the sub claim is the trust boundary,
      # so it must not be broader than what CI actually uses. plan.yml additionally
      # skips forked PRs (see its job-level `if`), so a fork cannot even trigger a run.
      #
      # V-M-Pioneer-Trading/infrastructure was removed from this list: its CI runs
      # `terraform init -backend=false` + `validate` only and never assumes an AWS
      # role, so the old `repo:V-M-Pioneer-Trading/infrastructure:*` entry was an
      # unused wildcard grant of account-wide read. If that repo ever needs real
      # plans, re-add it scoped to `:pull_request` (with the same fork-PR guard).
      values = [
        "repo:mradomsky/infrastructure:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name               = "github-actions-terraform-plan"
  assume_role_policy = data.aws_iam_policy_document.github_plan_trust.json
}

resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Defence in depth: ReadOnlyAccess can read secret *values*, which a compromised plan
# run must never do. An explicit Deny always overrides the managed Allow. Scoped so the
# public AWS SSM parameter that `plan` genuinely reads
# (data.aws_ssm_parameter.amazon_linux_2023_ami, under /aws/service/*) stays readable.
resource "aws_iam_role_policy" "github_plan_deny_secret_reads" {
  name = "github-actions-terraform-plan-deny-secrets"
  role = aws_iam_role.github_plan.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenySecretsManagerReads"
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "*"
      },
      {
        Sid    = "DenySsmSecureStringSecretReads"
        Effect = "Deny"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        # The SecureString secrets only — extend this list when new ones are added
        # (e.g. the VAPID key from stagehopper#75). Public /aws/service/* stays allowed.
        Resource = [
          "arn:aws:ssm:*:*:parameter/navigation-service-ghcr-pat"
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC — apply role for the manually-triggered `terraform apply`
# workflow (.github/workflows/apply.yml, workflow_dispatch only).
#
# Trust is restricted to the `main` branch ref: a workflow_dispatch run on main
# gets sub `repo:mradomsky/infrastructure:ref:refs/heads/main`, so a run from any
# PR/feature branch cannot assume this role. It holds write permissions and can
# take the state lock (unlike the read-only plan role), so apply runs with locking.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "github_apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:mradomsky/infrastructure:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_apply" {
  name               = "github-actions-terraform-apply"
  assume_role_policy = data.aws_iam_policy_document.github_apply_trust.json
}

resource "aws_iam_role_policy_attachment" "github_apply_admin" {
  role       = aws_iam_role.github_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC — website/Lambda deploy role for the app repos
#
# Pre-existed this repo (created by hand) and was previously unmanaged: project
# stacks only referenced it via `data "aws_iam_role"` and attached deploy
# policies to it, while its trust policy — `repo:mradomsky/*:*`, i.e. ANY repo
# under the account, any ref — lived nowhere in code. Adopted into state with
# `terraform import github-website-deployment-worker` (one-off, already done)
# so the trust is reviewable and scoped to the exact CI contexts that deploy:
#   - mradomsky/stagehopper:   release tags (`v*`) + workflow_dispatch re-runs
#     from main (.github/workflows/deploy.yml in that repo)
#   - mradomsky/radomskyi.com: push to main
#
# The per-project deploy policies stay attached from the project stacks
# (projects/stagehopper, which grants S3 sync, CloudFront invalidation and
# lambda:UpdateFunctionCode) — this block owns only the role and its trust.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "github_website_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:mradomsky/stagehopper:ref:refs/tags/v*",
        "repo:mradomsky/stagehopper:ref:refs/heads/main",
        "repo:mradomsky/radomskyi.com:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "github_website_deploy" {
  name               = "github-website-deployment-worker"
  description        = "GitHub Actions CI deploy role for the website/app repos (stagehopper, radomskyi.com)"
  assume_role_policy = data.aws_iam_policy_document.github_website_deploy_trust.json
}

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "github_plan_role_arn" {
  value = aws_iam_role.github_plan.arn
}

output "github_apply_role_arn" {
  value = aws_iam_role.github_apply.arn
}
