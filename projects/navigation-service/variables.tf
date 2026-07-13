variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name (dev, prod)."
  type        = string
}

variable "container_image" {
  description = "Full container image URI including tag. Updated by app CI; Terraform sets the initial value only."
  type        = string
}

variable "container_port" {
  description = "Port the navigation-service Spring Boot app listens on."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Number of running task replicas. Set to 0 to stop without destroying."
  type        = number
  default     = 1
}

variable "sqlite_db_filename" {
  description = "SQLite database filename inside the mounted /data directory (e.g. nav.db)."
  type        = string
  default     = "nav.db"
}

variable "vpc_id" {
  description = "VPC ID. Defaults to the account default VPC when empty — override for non-default VPCs."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Subnet IDs for tasks and EFS mounts. Leave empty to use all subnets of the resolved VPC."
  type        = list(string)
  default     = []
}

variable "assign_public_ip" {
  description = "Assign public IP to tasks. True when using public subnets without a NAT gateway."
  type        = bool
  default     = true
}

variable "ingress_cidr_blocks" {
  description = "CIDRs allowed to call the service directly (e.g. VPC CIDR for internal access, or 0.0.0.0/0 for dev)."
  type        = list(string)
  default     = []
}
