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

variable "google_client_id" {
  description = "Google OAuth client ID used by the Lambda to verify Google ID tokens"
  type        = string
  sensitive   = true
  default     = ""
}

variable "admin_emails" {
  description = "Comma-separated Google-verified emails allowed to use the admin console"
  type        = string
  sensitive   = true
  default     = ""
}
