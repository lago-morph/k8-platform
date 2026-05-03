# Helm installs for the management cluster bootstrap stack.
#
# This is the ONLY place Helm is driven by Terraform in this project.
# After this apply, ArgoCD takes over managing everything via GitOps.
# cert-manager and ingress-nginx are also installed here (management cluster
# only) so that the ArgoCD UI is reachable with valid TLS at the end of
# Iteration 1 — without these two, ArgoCD has no ingress and no certificate.
# See DESIGN.md section 4, Iteration 1 design note.

# ---- cert-manager ----
# Must be installed before any cert-manager CRDs are referenced.

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_cert_manager.iam_role_arn
  }

  depends_on = [module.eks]
}

# ---- ClusterIssuer for Let's Encrypt (management cluster) ----
# Applied as a raw Kubernetes manifest after cert-manager is ready.

resource "kubernetes_manifest" "cluster_issuer_prod" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.acme_email
        privateKeySecretRef = { name = "letsencrypt-prod-key" }
        solvers = [{
          dns01 = {
            route53 = {
              region       = var.aws_region
              hostedZoneID = data.terraform_remote_state.base.outputs.route53_zone_id
            }
          }
        }]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

# ---- ingress-nginx (management cluster only) ----

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

# Crossplane AWS Provider — installed via a Kubernetes manifest so the
# provider version and package are tracked in Git rather than hardcoded here.
resource "kubernetes_manifest" "crossplane_aws_provider" {
  manifest = {
    apiVersion = "pkg.crossplane.io/v1"
    kind       = "Provider"
    metadata = {
      name = "provider-aws"
    }
    spec = {
      package = "xpkg.upbound.io/upbound/provider-aws:v0.46.0"
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
      name = "aws-provider-config"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.irsa_crossplane.iam_role_arn
      }
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

  # Expose ArgoCD server as ClusterIP; ingress-nginx handles external access.
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # Disable the built-in TLS on the ArgoCD server — TLS is terminated at
  # ingress-nginx with a cert-manager certificate.
  set {
    name  = "server.extraArgs[0]"
    value = "--insecure"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_argocd.iam_role_arn
  }

  depends_on = [
    helm_release.ingress_nginx,
    helm_release.cert_manager,
  ]
}

# ---- ArgoCD Ingress ----
# ExternalDNS annotation creates argocd.management.<domain> in Route53.
# cert-manager annotation provisions a Let's Encrypt certificate.

resource "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "argocd"
    namespace = "argocd"
    annotations = {
      "kubernetes.io/ingress.class"                = "nginx"
      "cert-manager.io/cluster-issuer"             = "letsencrypt-prod"
      "external-dns.alpha.kubernetes.io/hostname"  = "argocd.management.${var.domain}"
    }
  }

  spec {
    tls {
      hosts       = ["argocd.management.${var.domain}"]
      secret_name = "argocd-tls"
    }

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

  depends_on = [
    helm_release.argocd,
    kubernetes_manifest.cluster_issuer_prod,
  ]
}
