terraform {
  backend "s3" {
    bucket       = "radomskyi-tfstate"
    key          = "radomskyi-com/terraform.tfstate"
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
      Project     = "radomskyi-com"
      Terraform   = "true"
    }
  }
}

# CloudFront ACM certificates and the Route 53 Domains API both live in us-east-1.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "radomskyi-com"
      Terraform   = "true"
    }
  }
}
