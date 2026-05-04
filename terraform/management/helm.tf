# Helm installs for the management cluster bootstrap stack.
#
# This is the ONLY place Helm is driven by Terraform in this project.
# After this apply, ArgoCD takes over managing everything via GitOps.
#
# TLS strategy: TLS terminates at the ingress-nginx NLB using the ACM wildcard
# certificate provisioned in terraform/base. No cert-manager ACME needed on
# the management cluster itself. The NLB presents *.{domain} for all hosts,
# and ExternalDNS creates the per-service DNS CNAMEs automatically.

# ---- ingress-nginx ----
# NLB in TLS-termination mode: port 443 decrypts with the ACM cert and
# proxies plain HTTP to nginx (port 80). nginx routes by Host header.

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_version
  namespace        = "ingress-nginx"
  create_namespace = true

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }
  # ACM wildcard cert — NLB terminates TLS; nginx sees plain HTTP.
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-cert"
    value = try(data.terraform_remote_state.base.outputs.acm_certificate_arn, "")
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-ports"
    value = "443"
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-backend-protocol"
    value = "http"
  }
  # NLB sends decrypted traffic to nginx's HTTP port, not its HTTPS port.
  set {
    name  = "controller.service.targetPorts.https"
    value = "http"
  }

  depends_on = [module.eks]
}

# ---- External Secrets Operator ----

resource "helm_release" "eso" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.eso_version
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_eso.iam_role_arn
  }

  depends_on = [module.eks]
}

# ---- Crossplane ----

resource "helm_release" "crossplane" {
  name             = "crossplane"
  repository       = "https://charts.crossplane.io/stable"
  chart            = "crossplane"
  version          = var.crossplane_version
  namespace        = "crossplane-system"
  create_namespace = true

  depends_on = [module.eks]
}

# Install the Crossplane AWS provider family using Crossplane v2 APIs.
# DeploymentRuntimeConfig (v1beta1) replaces the v1 ControllerConfig;
# IRSA annotation moves into spec.serviceAccountTemplate rather than
# a top-level annotation on the config object.
# Using local-exec avoids the kubernetes Terraform provider (which requires
# a live API server at plan time) and lets us template the IRSA ARN directly.
resource "terraform_data" "crossplane_aws_provider" {
  triggers_replace = [
    module.irsa_crossplane.iam_role_arn,
    var.crossplane_provider_family_aws_version,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl apply -f - <<'MANIFEST'
      ---
      apiVersion: pkg.crossplane.io/v1beta1
      kind: DeploymentRuntimeConfig
      metadata:
        name: aws-provider-config
      spec:
        serviceAccountTemplate:
          metadata:
            annotations:
              eks.amazonaws.com/role-arn: "${module.irsa_crossplane.iam_role_arn}"
      ---
      apiVersion: pkg.crossplane.io/v1
      kind: Provider
      metadata:
        name: provider-family-aws
      spec:
        package: "xpkg.upbound.io/upbound/provider-family-aws:${var.crossplane_provider_family_aws_version}"
        runtimeConfigRef:
          apiVersion: pkg.crossplane.io/v1beta1
          kind: DeploymentRuntimeConfig
          name: aws-provider-config
      MANIFEST
    EOT
  }

  depends_on = [helm_release.crossplane]
}

# ---- ArgoCD ----

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  namespace        = "argocd"
  create_namespace = true

  # ArgoCD serves HTTP; TLS is terminated upstream at the NLB.
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "server.extraArgs[0]"
    value = "--insecure"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_argocd.iam_role_arn
  }
  # Ingress configured here so no separate kubernetes_ingress_v1 resource is
  # needed (which would require the kubernetes provider at plan time).
  set {
    name  = "server.ingress.enabled"
    value = "true"
  }
  set {
    name  = "server.ingress.ingressClassName"
    value = "nginx"
  }
  set {
    name  = "server.ingress.annotations.external-dns\\.alpha\\.kubernetes\\.io/hostname"
    value = "argocd.management.${var.domain}"
  }
  set {
    name  = "server.ingress.hosts[0]"
    value = "argocd.management.${var.domain}"
  }

  depends_on = [helm_release.ingress_nginx]
}
