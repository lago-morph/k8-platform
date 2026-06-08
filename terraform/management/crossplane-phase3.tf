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
    var.crossplane_provider_aws_ec2_version,
    # Bump when the embedded manifest body changes (the version vars above
    # don't cover a manifest-shape edit, so a body-only change would no-op
    # the apply — same trap as helm.tf:crossplane_aws_provider). 2026-06-06:
    # added runtimeConfigRef=aws-provider-config to each child provider for
    # IRSA (auto-011 blocker #3, Option A). 2026-06-07: added provider-aws-ec2
    # for the kube-relay-ingress MR (docs/decisions/0008).
    "kube-relay-ec2-2026-06-07",
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
        # IRSA: run this child provider's pod under the family SA
        # (upbound-provider-family-aws) which carries the
        # eks.amazonaws.com/role-arn annotation and is the ONLY subject the
        # crossplane IRSA role trusts (StringEquals, irsa.tf). Without this
        # the child pod gets a default un-annotated SA → no web-identity token
        # → every MR fails "token file name cannot be empty"
        # (auto-011 blocker #3; decisions/auto-011-child-provider-irsa.md, Option A).
        runtimeConfigRef:
          apiVersion: pkg.crossplane.io/v1beta1
          kind: DeploymentRuntimeConfig
          name: aws-provider-config
      ---
      apiVersion: pkg.crossplane.io/v1
      kind: Provider
      metadata:
        name: provider-aws-iam
      spec:
        package: "xpkg.upbound.io/upbound/provider-aws-iam:${var.crossplane_provider_aws_iam_version}"
        runtimeConfigRef:
          apiVersion: pkg.crossplane.io/v1beta1
          kind: DeploymentRuntimeConfig
          name: aws-provider-config
      ---
      apiVersion: pkg.crossplane.io/v1
      kind: Provider
      metadata:
        name: provider-aws-acm
      spec:
        package: "xpkg.upbound.io/upbound/provider-aws-acm:${var.crossplane_provider_aws_acm_version}"
        runtimeConfigRef:
          apiVersion: pkg.crossplane.io/v1beta1
          kind: DeploymentRuntimeConfig
          name: aws-provider-config
      ---
      apiVersion: pkg.crossplane.io/v1
      kind: Provider
      metadata:
        name: provider-aws-route53
      spec:
        package: "xpkg.upbound.io/upbound/provider-aws-route53:${var.crossplane_provider_aws_route53_version}"
        runtimeConfigRef:
          apiVersion: pkg.crossplane.io/v1beta1
          kind: DeploymentRuntimeConfig
          name: aws-provider-config
      ---
      apiVersion: pkg.crossplane.io/v1
      kind: Provider
      metadata:
        name: provider-aws-ec2
      spec:
        # Needed by the XPlatformCluster Composition's kube-relay-ingress MR
        # (ec2 SecurityGroupIngressRule) that admits the shared SSM relay to the
        # cluster API (docs/decisions/0008).
        package: "xpkg.upbound.io/upbound/provider-aws-ec2:${var.crossplane_provider_aws_ec2_version}"
        runtimeConfigRef:
          apiVersion: pkg.crossplane.io/v1beta1
          kind: DeploymentRuntimeConfig
          name: aws-provider-config
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
      # auto-008 C3 — the XSpokeAccess Composition reads accountId +
      # argocdRoleArn from this same EnvironmentConfig (FromEnvironment
      # FieldPath / CombineFromEnvironment) to build the external-dns IRSA
      # trust policy's OIDC-provider ARN and the EKS AccessEntry/
      # AccessPolicyAssociation principalArn. Both are sourced from live
      # data/outputs so the XR carries no account-ephemeral literals
      # (AGENTS §8.1). argocdRoleArn is the FULL ARN of the
      # ${cluster_name}-argocd role created in irsa.tf.
      accountId     = data.aws_caller_identity.current.account_id
      argocdRoleArn = module.irsa_argocd.iam_role_arn
      # Security-group id of the ONE shared SSM kube-API relay (provisioned by
      # kube-access.tf on the hub). The platform-cluster Composition adds an
      # ingress rule on each cluster's SG admitting this relay on 443, so the
      # single relay can tunnel kubectl to every cluster — no per-cluster relay
      # instance (the account is capped at 9 EC2 instances). See docs/decisions/0008.
      relaySecurityGroupId = aws_security_group.kube_relay.id
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

# ---- provider-kubernetes + hub ProviderConfig (auto-008 C5) -------------
# The XSpokeAccess delivery path needs to write the ArgoCD spoke cluster
# Secret (hub-local) so the ArgoCD application-controller can register the
# spoke. That is a Kubernetes-object write, which needs provider-kubernetes
# (currently NOT installed). Install it as a pkg.crossplane.io/v1 Provider
# PLUS a hub ProviderConfig that targets the management cluster itself via
# the in-cluster ServiceAccount (source: InjectedIdentity) — no spoke
# ProviderConfig (which would be the rejected Option C surface; auto-008
# §8). The cert ARN reaches the spoke via the ArgoCD values path
# (cluster-Secret annotation → Application values), not a Crossplane-written
# spoke ConfigMap (auto-008 C5).
#
# Same idiom as the AWS child providers above: terraform_data + local-exec
# kubectl apply. Ordered AFTER helm_release.crossplane so the
# pkg.crossplane.io CRDs exist; the ProviderConfig (kubernetes.crossplane.io
# group) is applied after a Healthy-wait so provider-kubernetes has
# registered its CRD.
resource "terraform_data" "crossplane_provider_kubernetes" {
  triggers_replace = [
    var.crossplane_provider_kubernetes_version,
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
        name: provider-kubernetes
      spec:
        package: "xpkg.upbound.io/crossplane-contrib/provider-kubernetes:${var.crossplane_provider_kubernetes_version}"
      MANIFEST
      # Wait for the provider to become Healthy so its CRDs
      # (kubernetes.crossplane.io) are registered before we apply the
      # ProviderConfig below.
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl wait \
        --for=condition=Healthy --timeout=300s \
        provider.pkg.crossplane.io/provider-kubernetes
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl apply -f - <<'MANIFEST'
      apiVersion: kubernetes.crossplane.io/v1alpha1
      kind: ProviderConfig
      metadata:
        # Hub-local config: provider-kubernetes writes objects (the ArgoCD
        # spoke cluster Secret) into THIS management cluster using the
        # in-cluster SA. The XSpokeAccess add-on apps reference this config.
        name: hub
      spec:
        credentials:
          source: InjectedIdentity
      MANIFEST
    EOT
  }

  depends_on = [helm_release.crossplane]
}
