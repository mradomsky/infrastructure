variable "project_name" {
  description = "Project name — used to name all resources."
  type        = string
}

variable "service_name" {
  description = "Service name (e.g. navigation-service). Combined with project_name for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
}

variable "container_image" {
  description = "Full container image URI, including tag (e.g. 123456789.dkr.ecr.eu-central-1.amazonaws.com/navigation-service:latest)."
  type        = string
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Number of task instances to run. Set to 0 to stop the service without destroying infrastructure."
  type        = number
  default     = 1
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for ECS tasks and EFS mount targets. Must be in the same VPC."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Whether to assign a public IP to Fargate tasks. Required when using public subnets without a NAT gateway."
  type        = bool
  default     = false
}

variable "sqlite_mount_path" {
  description = "Absolute path inside the container where the EFS volume is mounted (the SQLite file lives here)."
  type        = string
  default     = "/data"
}

variable "environment_variables" {
  description = "Map of environment variables injected into the container."
  type        = map(string)
  default     = {}
}

variable "task_role_policy_json" {
  description = "Optional additional IAM policy document (JSON) attached to the ECS task role. Leave empty to grant no extra permissions."
  type        = string
  default     = ""
}

variable "efs_throughput_mode" {
  description = "EFS throughput mode: bursting or elastic."
  type        = string
  default     = "bursting"
}

variable "ingress_cidr_blocks" {
  description = "CIDR blocks allowed to reach the container port (e.g. VPC CIDR for internal-only access)."
  type        = list(string)
  default     = []
}

variable "ingress_security_group_ids" {
  description = "Security group IDs allowed to reach the container port."
  type        = list(string)
  default     = []
}
