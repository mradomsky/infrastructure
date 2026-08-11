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
  description = "Domain name for the SpaceTraders command interface"
  type        = string
  default     = "spacetraders.radomskyi.com"
}

variable "parent_domain" {
  description = "Parent domain for Route53 hosted zone lookup"
  type        = string
  default     = "radomskyi.com"
}

variable "bucket_name" {
  description = "Name of the S3 bucket to host the static site"
  type        = string
  default     = "spacetraders-radomskyi-com"
}

variable "origin_verify_secret" {
  description = "Shared X-Origin-Verify secret CloudFront sends to the Caddy origin. Supply at apply via TF_VAR_origin_verify_secret, sourced from the spacetraders-origin-verify SSM SecureString (the same value Caddy reads). Empty default so the read-only CI plan role never needs it; apply must set it."
  type        = string
  default     = ""
  sensitive   = true
}
