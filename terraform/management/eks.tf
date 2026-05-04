# EKS cluster for the management plane.
# Provisioned by Terraform (not Crossplane) so it can be recovered independently
# of the tooling that runs on it — see ADR-001.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = try(data.terraform_remote_state.base.outputs.vpc_id, "")
  subnet_ids = aws_subnet.management[*].id

  # Public endpoint for local kubectl and Terraform access.
  # Restrict to operator IP ranges in production environments.
  cluster_endpoint_public_access = true

  # Enable OIDC provider — required for IRSA.
  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # IMDSv2 required — prevents SSRF attacks against the instance metadata service.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  tags = { Cluster = var.cluster_name }
}
