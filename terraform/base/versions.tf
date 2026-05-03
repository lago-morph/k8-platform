terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Configure via -backend-config or backend.hcl — do not hardcode here.
    # Example:
    #   terraform init \
    #     -backend-config="bucket=my-tfstate" \
    #     -backend-config="key=k8-platform/base/terraform.tfstate" \
    #     -backend-config="region=us-east-1" \
    #     -backend-config="dynamodb_table=my-tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "k8-platform"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
