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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
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

# Kubernetes and Helm providers are configured after EKS is up.
# They read auth from the EKS cluster data source to avoid a chicken-and-egg.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.management.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.management.token
  }
}

data "aws_eks_cluster_auth" "management" {
  name = module.eks.cluster_name
}
