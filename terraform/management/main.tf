locals {
  name_prefix = "k8-platform"
  cluster_subdomain = "management.${var.domain}"

  # Pull base outputs via remote state.
  base_state_bucket = var.tf_state_bucket
  base_state_key    = "k8-platform/base/terraform.tfstate"
}

# Read outputs from terraform/base so we don't repeat VPC/zone IDs.
data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = var.tf_state_bucket
    key    = local.base_state_key
    region = var.aws_region
  }
}

data "aws_caller_identity" "current" {}
