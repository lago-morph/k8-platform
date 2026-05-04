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

resource "kubernetes_manifest" "crossplane_aws_provider" {
  manifest = {
    apiVersion = "pkg.crossplane.io/v1"
    kind       = "Provider"
    metadata   = { name = "provider-aws" }
    spec = {
      package             = "xpkg.upbound.io/upbound/provider-aws:v0.46.0"
      controllerConfigRef = { name = "aws-provider-config" }
    }
  }
  depends_on = [helm_release.crossplane]
}

resource "kubernetes_manifest" "crossplane_aws_controller_config" {
  manifest = {
    apiVersion = "pkg.crossplane.io/v1alpha1"
    kind       = "ControllerConfig"
    metadata = {
      name        = "aws-provider-config"
      annotations = { "eks.amazonaws.com/role-arn" = module.irsa_crossplane.iam_role_arn }
    }
    spec = {}
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

  depends_on = [helm_release.ingress_nginx]
}

# ---- ArgoCD Ingress ----
# ExternalDNS creates argocd.management.<domain> → NLB CNAME in Route53.
# TLS is handled by the NLB+ACM wildcard; no cert-manager annotation needed.

resource "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "argocd"
    namespace = "argocd"
    annotations = {
      "kubernetes.io/ingress.class"               = "nginx"
      "external-dns.alpha.kubernetes.io/hostname" = "argocd.management.${var.domain}"
    }
  }

  spec {
    rule {
      host = "argocd.management.${var.domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "argocd-server"
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.argocd]
}
