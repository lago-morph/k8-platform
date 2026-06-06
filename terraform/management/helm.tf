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
  # ACM cert — NLB terminates TLS; nginx sees plain HTTP. Uses the
  # *.management.<domain> cert (acm-management.tf), NOT the base *.<domain>
  # wildcard: the base wildcard matches only one label and does NOT cover the
  # two-label service hosts like argocd.management.<domain>, which made strict
  # TLS clients reject the listener cert on SAN (OI-2026-06-05-5). The management
  # NLB only serves *.management.<domain> hosts, so this is correct coverage.
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-cert"
    value = local.management_acm_certificate_arn
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

# ---- ExternalDNS ----
# Watches Ingress/Service objects with external-dns annotations and reconciles
# the corresponding Route53 records. The account's pre-existing hosted zone is
# discovered automatically by the zone-type/domain filters.

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.external_dns_version
  namespace        = "external-dns"
  create_namespace = true
  timeout          = 600
  wait             = false
  replace          = true

  set {
    name  = "provider.name"
    value = "aws"
  }
  set {
    name  = "policy"
    value = "upsert-only"
  }
  set {
    # Narrowed from var.domain (the whole zone) to management.<domain> so the
    # hub instance only owns its own subdomain and cannot clobber the platform
    # (spoke) external-dns records in the shared account zone (auto-008 S3 /
    # dual-instance TXT-registry safety). Safe to narrow because policy is
    # upsert-only (this instance never deletes records), so existing records
    # outside the new filter are simply left alone, not pruned. The hub only
    # publishes argocd.management.<domain>, so nothing it owns falls outside.
    # Disjointness from the spoke filter (platform.<domain>) is gated by
    # tests/unit/test_external_dns_disjoint_filters.sh.
    name  = "domainFilters[0]"
    value = "management.${var.domain}"
  }
  set {
    name  = "txtOwnerId"
    value = "k8-platform-mgmt"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_external_dns.iam_role_arn
  }
  set {
    name  = "sources[0]"
    value = "ingress"
  }
  set {
    name  = "sources[1]"
    value = "service"
  }
  set {
    name  = "env[0].name"
    value = "AWS_REGION"
  }
  set {
    name  = "env[0].value"
    value = var.aws_region
  }

  depends_on = [helm_release.ingress_nginx]
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
  name = "crossplane"
  # Vendored chart, NOT a live repo fetch. charts.crossplane.io/stable/index.yaml
  # returns 403 Forbidden to the GitHub Actions runner network (the same URL
  # serves 200 from elsewhere) — OI-2026-06-05-2. Installing from the
  # digest-verified local tarball (vendor/README.md) makes the apply hermetic
  # and independent of that CDN. The version is encoded in the filename via
  # var.crossplane_version, so a version bump = vendor the matching .tgz.
  chart            = "${path.module}/vendor/crossplane-${var.crossplane_version}.tgz"
  namespace        = "crossplane-system"
  create_namespace = true

  # Disable the three beta features that v2.3 newly turns on by default.
  # These caused observable regressions for our v1-XRD-based Composition
  # pipeline (chainsaw runs 26385090086 / 26385825898 / 26386596063):
  #   - EnableBetaRealtimeCompositions: aggressive re-render loop (30+
  #     function invocations per minute per claim) starves the composite
  #     reconciler so MR creation takes 100+ seconds, well past the ESO
  #     refresh-interval window.
  #   - EnableBetaClaimSSA: server-side-apply path enforces strict
  #     schema validation on rendered MRs and fails with "field not
  #     declared in schema" for fields permitted by v2.0's permissive
  #     reconciler.
  #   - EnableBetaCustomToManagedResourceConversion: unused; off by
  #     parsimony.
  # KEPT enabled (still beta in 2.3, but already enabled on 2.0.1 and
  # depended on by our setup):
  #   - DeploymentRuntimeConfigs (used by terraform_data.crossplane_aws_provider
  #     below to pin the upbound-provider-family-aws SA name for IRSA).
  #   - Usages (not used today but harmless).
  set {
    name  = "args[0]"
    value = "--enable-realtime-compositions=false"
  }
  set {
    name  = "args[1]"
    value = "--enable-ssa-claims=false"
  }
  set {
    name  = "args[2]"
    value = "--enable-custom-to-managed-resource-conversion=false"
  }

  depends_on = [module.eks]
}

# Install the Crossplane AWS provider family using Crossplane v2 APIs.
# DeploymentRuntimeConfig (v1beta1) replaces the v1 ControllerConfig;
# IRSA annotation moves into spec.serviceAccountTemplate rather than
# a top-level annotation on the config object.
# Using local-exec avoids the kubernetes Terraform provider (which requires
# a live API server at plan time) and lets us template the IRSA ARN directly.
locals {
  crossplane_aws_provider_manifest = <<-MANIFEST
    ---
    apiVersion: pkg.crossplane.io/v1beta1
    kind: DeploymentRuntimeConfig
    metadata:
      name: aws-provider-config
    spec:
      serviceAccountTemplate:
        metadata:
          # Pin the SA name so it matches the IRSA trust policy in
          # irsa.tf (namespace_service_accounts =
          # ["crossplane-system:upbound-provider-family-aws"]).
          # Without this, Crossplane derives a revision-hash-suffixed
          # name like provider-family-aws-24aaab54a3a0;
          # AssumeRoleWithWebIdentity then fails for the OIDC subject
          # mismatch, every ASM Secret MR stalls Ready=False with no
          # atProvider.arn, and PlatformSecret claims sit Waiting
          # forever. Observed in phase-2-diagnose run 26353150253.
          name: upbound-provider-family-aws
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
}

resource "terraform_data" "crossplane_aws_provider" {
  # Hash the manifest body so ANY edit to the inline YAML (e.g. pinning
  # the SA name, adjusting tolerations, bumping a label) forces a
  # re-apply. The pre-existing trigger pair only covered the templated
  # values, so a manifest-body-only change (#66) silently no-op'd the
  # apply on run 26354235231 ("No changes ... Apply complete! 0 added").
  triggers_replace = [
    module.irsa_crossplane.iam_role_arn,
    var.crossplane_provider_family_aws_version,
    sha256(local.crossplane_aws_provider_manifest),
    # Bump when the local-exec command body changes (kubectl apply +
    # delete-deploy steps) — those live outside the manifest local
    # so the sha256 above doesn't cover them. v2: added rebuild
    # of the provider Deployment after the apply. v2-migration: added
    # rollout-status wait + SA post-check to turn a silent IRSA
    # misconfiguration into a hard terraform apply failure.
    # 2026-06-05: dropped the by-label delete/rollout (the v2.5.0
    # family-provider Deployment isn't labelled
    # pkg.crossplane.io/provider=provider-family-aws — OI-2026-06-05-4),
    # replaced with a Healthy-wait + SA-readiness wait + diagnostics dump.
    "provisioner-command-2026-06-05-sa-readiness",
  ]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl apply -f - <<'MANIFEST'
${local.crossplane_aws_provider_manifest}
MANIFEST
      # On a FRESH Crossplane install the Provider object is created above but
      # the package manager lags creating its ProviderRevision + Deployment +
      # ServiceAccount (cold xpkg image pull on a t3.medium). Wait for the
      # provider to be Healthy so its Deployment + SA exist before we verify
      # them (OI-2026-06-05-3, run 27023573285).
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl wait \
        --for=condition=Healthy provider.pkg.crossplane.io/provider-family-aws \
        --timeout=300s

      # Diagnostics (best-effort, never fails the apply). The v2.5.0
      # family-provider Deployment is NOT labelled
      # pkg.crossplane.io/provider=provider-family-aws — that selector matched
      # nothing in run 27023830973 even though the Provider was Healthy — so the
      # old delete+rollout-by-label dance is gone. Dump what the package manager
      # actually created so any future label/SA drift is visible in the log.
      echo "--- crossplane-system deploy/sa (labels) ---"
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl -n crossplane-system get deploy,sa --show-labels 2>&1 || true
      echo "--- crossplane-system pod serviceAccounts ---"
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl -n crossplane-system get pods \
        -o 'jsonpath={range .items[*]}{.metadata.name}{"  sa="}{.spec.serviceAccountName}{"\n"}{end}' 2>&1 || true
      echo "--- providers / providerrevisions ---"
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl get providers.pkg.crossplane.io,providerrevisions.pkg.crossplane.io 2>&1 || true

      # The DRC (applied WITH the Provider above) pins the family-provider SA to
      # upbound-provider-family-aws so it matches the IRSA trust subject in
      # irsa.tf. On a fresh install the package manager creates the Deployment
      # with that SA from the start — no Deployment re-roll is needed; just wait
      # for the SA to materialise (poll up to ~3 min for a cold pull). The hard
      # gate below then asserts the SA name. POSIX /bin/sh.
      i=0
      until KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl get sa -n crossplane-system \
            upbound-provider-family-aws -o name >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -ge 36 ] && break
        sleep 5
      done

      # v2-migration: post-check that the package manager honoured the DRC
      # SA-name override (spec.serviceAccountTemplate.metadata.name in the
      # manifest above). If v2.5.0 silently ignores the override and falls
      # back to the default upbound-provider-aws-<hash> SA name, the IRSA
      # trust policy pinned in irsa.tf (system:serviceaccount:crossplane-system:
      # upbound-provider-family-aws) will no longer match the pod's SA
      # subject claim, every AssumeRoleWithWebIdentity will return
      # AccessDenied, and every MR will stall Ready=False. This check
      # turns that silent IRSA misconfiguration into a hard terraform
      # apply failure caught in CI rather than surfaced as AccessDenied
      # during chainsaw.
      SA=$(KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl get sa -n crossplane-system \
        upbound-provider-family-aws \
        -o jsonpath='{.metadata.name}' 2>/dev/null || echo "MISSING")
      if [ "$SA" != "upbound-provider-family-aws" ]; then
        echo "ERROR: expected SA upbound-provider-family-aws, got: $SA" >&2
        echo "DRC serviceAccountTemplate.metadata.name override appears ineffective." >&2
        echo "See ai/crossplane-v1-v2-un-fuckify/20-plan-SEG-2-terraform-infra.md §4 path (b)." >&2
        exit 1
      fi
    EOT
  }

  depends_on = [helm_release.crossplane]
}

# Install function-patch-and-transform. Required by every Composition that
# uses v2 Pipeline mode with the legacy resources/patches input shape;
# Crossplane v2 removed `spec.resources` from the v1 Composition schema, so
# every Composition the platform ships goes through this function.
#
# v2 migration note: the Function CR was promoted from `pkg.crossplane.io/v1beta1`
# to `pkg.crossplane.io/v1` on the Crossplane v1.x line (>= v1.17.1). On
# Crossplane v2.3 the v1beta1 apiVersion is NOT a served version — there is no
# conversion webhook, so any pre-existing v1beta1 Function object must be
# unconditionally deleted before re-applying as v1. The pre-delete is
# idempotent (`--ignore-not-found`) and tolerates the case where the v1beta1
# resource type itself is no longer registered (`|| true`).
resource "terraform_data" "crossplane_function_patch_and_transform" {
  triggers_replace = [
    var.crossplane_function_patch_and_transform_version,
    # Bump this sentinel when the local-exec command body or the embedded
    # manifest shape changes (e.g. v1beta1 -> v1 promotion + pre-delete).
    # The version-variable trigger above does not fire on a manifest-shape
    # edit alone, so the pre-delete + v1 apply would otherwise no-op on the
    # next terraform run.
    "v2-migration-2026-05-26",
  ]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig
      # Unconditional pre-delete of any pre-existing v1beta1 Function object.
      # v2.3 does not serve the v1beta1 apiVersion (no conversion webhook),
      # so applying v1 over an existing v1beta1 object would fail with
      # "no matches for kind \"Function\" in version \"pkg.crossplane.io/v1beta1\"".
      # --ignore-not-found handles the "no such object" case; || true handles
      # the "no such resource type registered" case.
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl delete function function-patch-and-transform --ignore-not-found || true
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl apply -f - <<'MANIFEST'
      apiVersion: pkg.crossplane.io/v1
      kind: Function
      metadata:
        name: function-patch-and-transform
      spec:
        package: "xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:${var.crossplane_function_patch_and_transform_version}"
      MANIFEST
    EOT
  }

  depends_on = [helm_release.crossplane]
}

# Install provider-aws-secretsmanager. Upbound's family-aws (above) is a
# meta-package; each AWS service has its own child provider. PlatformSecret
# claims need the secretsmanager child to actually reconcile the underlying
# ASM Secret managed resource.
resource "terraform_data" "crossplane_provider_aws_secretsmanager" {
  triggers_replace = [
    var.crossplane_provider_aws_secretsmanager_version,
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
        name: provider-aws-secretsmanager
      spec:
        package: "xpkg.upbound.io/upbound/provider-aws-secretsmanager:${var.crossplane_provider_aws_secretsmanager_version}"
      MANIFEST
    EOT
  }

  depends_on = [terraform_data.crossplane_aws_provider]
}

# ---- Kyverno (audit-mode policy engine) ----
# Acts as a continuously-running assertion store: policies in policies/audit/
# declare what "well-configured" looks like, and any drift (chart bump, hand
# edit, Argo sync) surfaces in PolicyReport CRs and events without blocking
# anything. See policies/audit/README.md for the full rationale.

resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  version          = var.kyverno_version
  namespace        = "kyverno"
  create_namespace = true
  timeout          = 600
  # Kyverno's admission webhook can race the API server during install on a
  # cold cluster; wait=false lets terraform return as soon as the helm release
  # is registered, and the e2e-verify pod check confirms readiness.
  wait = false

  depends_on = [module.eks]
}

# Apply the audit-mode policy bundle from policies/audit/. Re-runs whenever
# any policy file changes (triggered by a hash over the directory). Uses the
# same local-exec pattern as the Crossplane provider config to avoid pulling
# in the kubernetes terraform provider.
resource "terraform_data" "kyverno_audit_policies" {
  triggers_replace = [
    sha1(join("", [for f in fileset("${path.module}/../../policies/audit", "*.yaml") : filesha1("${path.module}/../../policies/audit/${f}")])),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig
      KUBECONFIG=/tmp/k8-platform-kubeconfig \
        kubectl wait --for=condition=Available --timeout=300s \
          -n kyverno deploy -l app.kubernetes.io/component=admission-controller
      KUBECONFIG=/tmp/k8-platform-kubeconfig \
        kubectl apply -f ${path.module}/../../policies/audit/
    EOT
  }

  depends_on = [helm_release.kyverno]
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
  # argo-cd chart has per-component ServiceAccounts; the server SA is the one
  # that needs the IRSA role-arn annotation for any AWS API calls argo makes.
  set {
    name  = "server.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
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
    name  = "server.ingress.hostname"
    value = "argocd.management.${var.domain}"
  }

  depends_on = [helm_release.ingress_nginx]
}

# ---- ArgoCD bootstrap (app-of-apps) ----
#
# Applies a single Application — `argocd/bootstrap.yaml` — that itself
# manages every other Application and AppProject under argocd/. From this
# point on, the only Argo resource Terraform owns is `bootstrap` itself;
# everything else is GitOps-managed via the bootstrap App.
#
# Why local-exec kubectl (not the kubernetes provider): same reason as
# the other terraform_data resources in this file — keeps Terraform's
# plan-time graph free of the kubernetes provider, which can't be
# initialised until the EKS cluster exists.
#
# triggers_replace hashes bootstrap.yaml — a change in the file content
# causes a re-apply on the next terraform run.
resource "terraform_data" "argocd_bootstrap" {
  triggers_replace = [
    filesha1("${path.module}/../../argocd/bootstrap.yaml"),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl wait --for=condition=Available --timeout=300s -n argocd deploy/argocd-server
      KUBECONFIG=/tmp/k8-platform-kubeconfig kubectl apply -f ${path.module}/../../argocd/bootstrap.yaml
    EOT
  }

  depends_on = [helm_release.argocd]
}
