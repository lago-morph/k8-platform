terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  backend "s3" {
    # Configure via -backend-config flags or a backend.hcl file.
    # Use a different key than terraform/base/ — separate state files.
    # Example:
    #   terraform init \
    #     -backend-config="bucket=my-tfstate" \
    #     -backend-config="key=k8-platform/management/terraform.tfstate" \
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
      Cluster     = "management"
      Environment = var.environment
    }
  }
}

# Helm provider is configured after EKS is up.
#
# Auth uses the `aws eks get-token` EXEC plugin, NOT a static
# data.aws_eks_cluster_auth token. Rationale (run 27070902703): a static token
# is fetched once during apply-graph evaluation and EKS tokens expire after 15
# minutes. When the EKS control plane is slow to create (that run took 18m53s),
# the helm_release resources run AFTER the token has expired, failing with
# "the server has asked for the client to provide credentials". The exec plugin
# mints a fresh token at the moment each helm operation runs, so a slow
# control-plane create can never expire it mid-apply. The runner's AWS creds are
# inherited from the environment. (test_eks_module_defaults.sh tripwires this.)
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}
