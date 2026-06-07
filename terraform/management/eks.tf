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

  # Access entries are how the sandbox identity gets read-only kube RBAC
  # (see kube-access.tf). This is the module v20 default; pinned explicitly so a
  # future default change can't silently drop the cluster into CONFIG_MAP-only
  # and break aws_eks_access_entry.sandbox.
  authentication_mode = "API_AND_CONFIG_MAP"

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

      # Pin the AMI family to AL2023 so the module renders **nodeadm**-format
      # user-data (a MIME multipart NodeConfig), NOT the legacy AL2
      # `/etc/eks/bootstrap.sh` script. This pin is load-bearing: a prior
      # attempt that left ami_type implicit made the module emit AL2
      # bootstrap.sh with no maxPods, which would have failed node bootstrap
      # (run 27047740806, caught by user-data decode). With AL2023 pinned, the
      # cloudinit_pre_nodeadm NodeConfig below is merged by nodeadm at boot.
      ami_type = "AL2023_x86_64_STANDARD"

      # Realize prefix delegation's higher pod density at the kubelet layer.
      # The vpc-cni addon above raises the IP ceiling (/28 prefixes); this
      # raises the kubelet's advertised pod capacity from t3.medium's default
      # ~17 to 110 (the EKS soft cap for small instances). BOTH are required:
      # without this, kubelet still advertises ~17 even though IPs are
      # available. nodeadm merges this NodeConfig with the EKS-injected one;
      # later docs override, so maxPods here is authoritative.
      # SAFETY GATE: before any apply, decode the launch-template user_data in
      # the `management plan` output and confirm it is nodeadm MIME format
      # carrying `maxPods: 110` — NOT an AL2 `bootstrap.sh` line (AGENTS §6).
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
