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

  # EKS module v20 defaults this to false. Without it, the IAM principal that
  # creates the cluster has no access entry and the helm provider's token is
  # rejected ("the server has asked for the client to provide credentials").
  enable_cluster_creator_admin_permissions = true

  # Enable OIDC provider — required for IRSA.
  enable_irsa = true

  # VPC-CNI as a managed addon with PREFIX DELEGATION. The account caps nodes at
  # t3.medium, whose default max-pods is ~17 (3 ENIs x 6 IPs). The management
  # stack (Crossplane + 6 providers + functions + ESO + Kyverno + ArgoCD +
  # ingress-nginx + external-dns) exhausts the pod-IP slots — both nodes were
  # observed at 3/3 ENIs and 18/18 IPs, so new pods (e.g. the ingress-nginx
  # kube-webhook-certgen hook Job) couldn't get an IP and failed to schedule,
  # timing out the helm hook. Prefix delegation assigns /28 prefixes instead of
  # single IPs, raising t3.medium max-pods from ~17 to ~110. resolve_conflicts
  # OVERWRITE lets the managed addon adopt the existing self-managed aws-node.
  cluster_addons = {
    vpc-cni = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Prefix delegation only helps if the kubelet pod cap is also raised — the
      # CNI having spare /28 prefixes is moot while --max-pods stays at ~17.
      # AL2023 (cluster_version >= 1.30) sets kubelet config via nodeadm, so
      # inject maxPods=110 (the AWS max-pods-calculator value for t3.medium with
      # prefix delegation) as a pre-nodeadm cloudinit part. Changing this rolls
      # the node group so every node relaunches with the higher cap.
      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  maxPods: 110
          EOT
        }
      ]

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
