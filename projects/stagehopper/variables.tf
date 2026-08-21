variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name (e.g., prod, staging, dev)"
  type        = string
  default     = "prod"
}

variable "domain_name" {
  description = "Domain name for the StageHopper app"
  type        = string
  default     = "stagehopper.radomskyi.com"
}

variable "parent_domain" {
  description = "Parent domain for Route53 hosted zone lookup"
  type        = string
  default     = "radomskyi.com"
}

variable "bucket_name" {
  description = "Name of the S3 bucket to host the static site"
  type        = string
  default     = "stagehopper-radomskyi-com"
}

# Clerk is the identity provider; API Gateway's JWT authorizer verifies its tokens before
# the Lambda is invoked. Neither value below is a secret — the issuer is a public URL and
# the audience is a public string agreed with the JWT template — so both are plain
# variables and neither is marked `sensitive`.

variable "clerk_issuer" {
  description = <<-EOT
    Clerk Frontend API URL, used as the JWT authorizer's issuer. Production instances use
    https://clerk.<domain>; development instances use https://<slug>.clerk.accounts.dev.
    API Gateway resolves the signing keys from <issuer>/.well-known/openid-configuration.

    Deliberately has no default. An empty or wrong issuer is a JWT authorizer that trusts
    nothing (or the wrong tenant), which fails as a puzzling 401 on every route rather than
    as an error — so this fails at plan time instead.
  EOT
  type        = string
}

# The five CNAMEs `clerk deploy status` reports as `pendingDnsRecords` once a
# production instance and domain are chosen. Keyed by host so a rerun that
# reorders the API response still maps onto the same Terraform resource
# instances, rather than destroying and recreating them.
variable "clerk_dns_records" {
  description = "CNAME records Clerk requires for the production domain — from `clerk deploy status`"
  type = map(object({
    host  = string
    type  = string
    value = string
  }))
  default = {
    "clerk" = {
      host  = "clerk.clerk.stagehopper.radomskyi.com"
      type  = "CNAME"
      value = "frontend-api.clerk.services"
    }
    "accounts" = {
      host  = "accounts.clerk.stagehopper.radomskyi.com"
      type  = "CNAME"
      value = "accounts.clerk.services"
    }
    "clkmail" = {
      host  = "clkmail.clerk.stagehopper.radomskyi.com"
      type  = "CNAME"
      value = "mail.0aaktimnb3rg.clerk.services"
    }
    "clk-domainkey" = {
      host  = "clk._domainkey.clerk.stagehopper.radomskyi.com"
      type  = "CNAME"
      value = "dkim1.0aaktimnb3rg.clerk.services"
    }
    "clk2-domainkey" = {
      host  = "clk2._domainkey.clerk.stagehopper.radomskyi.com"
      type  = "CNAME"
      value = "dkim2.0aaktimnb3rg.clerk.services"
    }
  }
}

variable "clerk_audience" {
  description = <<-EOT
    The `aud` claim the authorizer requires. Must match the `aud` in Clerk's `apigw` JWT
    template exactly. Clerk's default session token carries no `aud` at all, which is why
    the client fetches a template token rather than the session token.
  EOT
  type        = string
  default     = "stagehopper-api"
}
