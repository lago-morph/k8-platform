# Phase 3 Crossplane wiring for the XPlatformCluster Composition.
#
# Adds, on the management cluster's Crossplane:
#   1. The provider-aws child providers the cluster Composition needs
#      (eks, iam, acm, route53) — provider-family-aws is a meta-package
#      and ships no service controllers on its own.
#   2. function-environment-configs — merges the cluster-network
#      EnvironmentConfig (below) into the Composition pipeline environment.
#   3. The cluster-network EnvironmentConfig itself, materialized from the
#      base Terraform output (private subnet IDs, route53 zone id) + the
#      root domain. This is how account-ephemeral values reach the
#      Composition without being committed to git (AGENTS §8.1;
#      ADR-e557a40123 / docs/decisions/0003).
#
# All three follow the established idiom in helm.tf: terraform_data +
# local-exec `kubectl apply` (no kubernetes Terraform provider), keyed to
# the management EKS cluster via `aws eks update-kubeconfig`.

# ---- AWS service providers for the cluster Composition ------------------
# eks + iam provision the cluster/nodegroup/roles; acm + route53 provision
# and DNS-validate the per-cluster wildcard certificate.
resource "terraform_data" "crossplane_provider_aws_cluster_services" {
  triggers_replace = [
    var.crossplane_provider_aws_eks_version,
    var.crossplane_provider_aws_iam_version,
    var.crossplane_provider_aws_acm_version,
    var.crossplane_provider_aws_route53_version,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl apply -f - <<'MANIFEST'
      apiVersion: pkg.crossplane.io/v1
      kind: Provider
      metadata:
        name: provider-aws-eks
      spec:
        package: "xpkg.upbound.io/upbound/provider-aws-eks:${var.crossplane_provider_aws_eks_version}"
      ---
      apiVersion: pkg.crossplane.io/v1
      kind: Provider
      metadata:
        name: provider-aws-iam
      spec:
        package: "xpkg.upbound.io/upbound/provider-aws-iam:${var.crossplane_provider_aws_iam_version}"
      ---
      apiVersion: pkg.crossplane.io/v1
      kind: Provider
      metadata:
        name: provider-aws-acm
      spec:
        package: "xpkg.upbound.io/upbound/provider-aws-acm:${var.crossplane_provider_aws_acm_version}"
      ---
      apiVersion: pkg.crossplane.io/v1
      kind: Provider
      metadata:
        name: provider-aws-route53
      spec:
        package: "xpkg.upbound.io/upbound/provider-aws-route53:${var.crossplane_provider_aws_route53_version}"
      MANIFEST
    EOT
  }

  # Apply the child providers ONLY AFTER the family Provider
  # (terraform_data.crossplane_aws_provider in helm.tf) has been applied and
  # reached Healthy. The family Provider is named upbound-provider-family-aws —
  # exactly the name these child providers' dependency resolver derives for the
  # family package. Ordering after it means the family object already exists
  # when the children resolve their dependency, so they de-dupe onto it instead
  # of racing to create a second Provider for the same package. Without this
  # ordering the two were applied in the same unordered terraform batch (~6s
  # apart) and deadlocked the package manager (OI-2026-06-06-2).
  depends_on = [terraform_data.crossplane_aws_provider]
}

# ---- function-environment-configs --------------------------------------
# Net-new function (no v1beta1 predecessor to pre-delete, unlike
# function-patch-and-transform). Installed as pkg.crossplane.io/v1.
resource "terraform_data" "crossplane_function_environment_configs" {
  triggers_replace = [
    var.crossplane_function_environment_configs_version,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl apply -f - <<'MANIFEST'
      apiVersion: pkg.crossplane.io/v1
      kind: Function
      metadata:
        name: function-environment-configs
      spec:
        package: "xpkg.upbound.io/crossplane-contrib/function-environment-configs:${var.crossplane_function_environment_configs_version}"
      MANIFEST
    EOT
  }

  depends_on = [helm_release.crossplane]
}

# ---- cluster-network EnvironmentConfig ---------------------------------
# Carries the account-ephemeral networking/DNS facts the cluster
# Composition reads (privateSubnetIds, route53ZoneId, domain). Sourced
# from the base Terraform output so the platform cluster XR carries no
# ephemeral values (AGENTS §8.1). triggers_replace on the manifest hash
# re-applies it when the account rotates and the subnet IDs / zone id
# change.
locals {
  cluster_network_envconfig = yamlencode({
    apiVersion = "apiextensions.crossplane.io/v1beta1"
    kind       = "EnvironmentConfig"
    metadata = {
      name = "cluster-network"
    }
    data = {
      privateSubnetIds = try(data.terraform_remote_state.base.outputs.private_subnet_ids, [])
      route53ZoneId    = try(data.terraform_remote_state.base.outputs.route53_zone_id, "")
      domain           = var.domain
    }
  })
}

resource "terraform_data" "crossplane_cluster_network_envconfig" {
  triggers_replace = [
    sha256(local.cluster_network_envconfig),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl apply -f - <<'MANIFEST'
${local.cluster_network_envconfig}
MANIFEST
    EOT
  }

  depends_on = [helm_release.crossplane]
}
