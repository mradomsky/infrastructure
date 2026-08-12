terraform {
  backend "s3" {
    bucket       = "radomskyi-tfstate"
    key          = "personal/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
  }

  required_version = ">= 1.10.0"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "personal-shared"
      Terraform   = "true"
    }
  }
}
