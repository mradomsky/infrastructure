variable "aws_region" {
  description = "AWS region for shared infrastructure"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment tag for shared infrastructure"
  type        = string
  default     = "personal"
}

variable "instance_name" {
  description = "Name prefix for shared EC2 resources"
  type        = string
  default     = "personal-shared-ec2"
}

variable "instance_type" {
  description = "EC2 instance type for shared container workloads"
  type        = string
  default     = "t3.small"
}

variable "root_volume_size_gib" {
  description = "Root volume size in GiB"
  type        = number
  default     = 20
}

variable "allowed_ingress_cidrs" {
  description = "CIDR ranges allowed to reach exposed container ports"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 || length(var.allowed_tcp_ports) == 0
    error_message = "allowed_ingress_cidrs must be set when allowed_tcp_ports is non-empty."
  }
}

variable "allowed_tcp_ports" {
  description = "TCP ports to expose for containers on the shared host"
  type        = list(number)
  default     = []

  validation {
    condition     = alltrue([for port in var.allowed_tcp_ports : port >= 1 && port <= 65535])
    error_message = "allowed_tcp_ports values must be between 1 and 65535."
  }
}
