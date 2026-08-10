variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name (e.g., prod, staging, dev)"
  type        = string
  default     = "dev"
}

variable "com_domain_name" {
  description = "Legacy domain name (redirect source, kept alive indefinitely)"
  type        = string
  default     = "radomskyi.com"
}

variable "dev_domain_name" {
  description = "New canonical domain name for the website"
  type        = string
  default     = "radomsky.dev"
}

variable "bucket_name" {
  description = "Name of the S3 bucket to host the website"
  type        = string
  default     = "radomskyi-com-website"
}


