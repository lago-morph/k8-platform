#!/usr/bin/env bash
# Render every helm_release in terraform/management/helm.tf and assert that
# the produced manifests carry the contracts we depend on.
#
# Catches the bug class "wrong chart key, silently ignored" (bugs #3, #5, #7
# from the 2026-05-23 phase-1 bring-up). Runs in <30s with no AWS / no cluster.
#
# Each chart block defines the same set blocks helm.tf uses (mirrored, with
# IRSA/domain placeholders) and asserts the rendered output meets the
# contract we expect. If helm.tf drifts, test_helm_drift.sh below catches it.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

require_tool helm
require_tool yq

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stub values used in place of terraform interpolations.
STUB_DOMAIN="example.com"
STUB_REGION="us-east-1"
STUB_ARGOCD_IRSA="arn:aws:iam::000000000000:role/test-argocd"
STUB_ESO_IRSA="arn:aws:iam::000000000000:role/test-eso"
STUB_EDNS_IRSA="arn:aws:iam::000000000000:role/test-external-dns"
STUB_ACM_ARN="arn:aws:acm:us-east-1:000000000000:certificate/stub"

# Versions match terraform/management/variables.tf defaults.
ARGOCD_VERSION="6.7.3"
CROSSPLANE_VERSION="2.0.1"   # not rendered here; crossplane has no values
ESO_VERSION="0.9.13"
INGRESS_NGINX_VERSION="4.10.0"
EXTERNAL_DNS_VERSION="1.15.0"

echo "── helm-render: argocd ────────────────────────────────────────────"
OUT="$TMP/argocd.yaml"
if helm_render \
  "https://argoproj.github.io/argo-helm" \
  "argo-cd" \
  "$ARGOCD_VERSION" \
  "$OUT" \
  "server.service.type=ClusterIP" \
  "server.extraArgs[0]=--insecure" \
  "server.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$STUB_ARGOCD_IRSA" \
  "server.ingress.enabled=true" \
  "server.ingress.ingressClassName=nginx" \
  "server.ingress.annotations.external-dns\.alpha\.kubernetes\.io/hostname=argocd.management.$STUB_DOMAIN" \
  "server.ingress.hostname=argocd.management.$STUB_DOMAIN"; then
  # The argocd-server ServiceAccount must carry the IRSA annotation.
  assert_yq_eq "$OUT" \
    'select(.kind=="ServiceAccount" and .metadata.name=="argocd-server") | .metadata.annotations["eks.amazonaws.com/role-arn"]' \
    "$STUB_ARGOCD_IRSA" \
    "argocd: argocd-server SA has IRSA annotation"

  # No annotation should land on the *application-controller* SA — different IRSA scope.
  assert_yq_eq "$OUT" \
    'select(.kind=="ServiceAccount" and .metadata.name=="argocd-application-controller") | .metadata.annotations["eks.amazonaws.com/role-arn"] // ""' \
    "" \
    "argocd: application-controller SA does NOT get the server IRSA arn"

  # Ingress is enabled and host points at our subdomain. Select by
  # app.kubernetes.io/name=argocd-server because the chart prefixes Ingress
  # metadata.name with the release-name ("argo-cd-argocd-server") while the
  # label stays stable across release-name choices.
  assert_yq_matches "$OUT" \
    'select(.kind=="Ingress" and .metadata.labels["app.kubernetes.io/name"]=="argocd-server") | .spec.rules[0].host' \
    "^argocd\.management\.$STUB_DOMAIN$" \
    "argocd: Ingress host == argocd.management.$STUB_DOMAIN"

  # external-dns annotation on the Ingress matches hostname (so ExternalDNS picks it up).
  assert_yq_eq "$OUT" \
    'select(.kind=="Ingress" and .metadata.labels["app.kubernetes.io/name"]=="argocd-server") | .metadata.annotations["external-dns.alpha.kubernetes.io/hostname"]' \
    "argocd.management.$STUB_DOMAIN" \
    "argocd: Ingress external-dns hostname annotation == subdomain"

  # Ingress class is nginx.
  assert_yq_eq "$OUT" \
    'select(.kind=="Ingress" and .metadata.labels["app.kubernetes.io/name"]=="argocd-server") | .spec.ingressClassName' \
    "nginx" \
    "argocd: Ingress ingressClassName == nginx"

  # argocd-server runs with --insecure (TLS terminates at NLB). Use
  # `// []` fallbacks because Mike Farah yq's `null + [...]` collapses
  # to null (the chart sets args but not command on this container).
  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.labels["app.kubernetes.io/name"]=="argocd-server") | ((.spec.template.spec.containers[0].command // []) + (.spec.template.spec.containers[0].args // [])) | .[]' \
    "(^|=)--insecure" \
    "argocd: argocd-server runs with --insecure"
else
  fail "argocd: helm template failed" "$(cat "$OUT.err" 2>/dev/null | tail -10)"
fi

echo "── helm-render: external-dns ─────────────────────────────────────"
OUT="$TMP/external-dns.yaml"
if helm_render \
  "https://kubernetes-sigs.github.io/external-dns/" \
  "external-dns" \
  "$EXTERNAL_DNS_VERSION" \
  "$OUT" \
  "provider.name=aws" \
  "policy=upsert-only" \
  "domainFilters[0]=$STUB_DOMAIN" \
  "txtOwnerId=k8-platform-mgmt" \
  "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$STUB_EDNS_IRSA" \
  "sources[0]=ingress" \
  "sources[1]=service" \
  "env[0].name=AWS_REGION" \
  "env[0].value=$STUB_REGION"; then

  assert_yq_eq "$OUT" \
    'select(.kind=="ServiceAccount" and .metadata.name=="external-dns") | .metadata.annotations["eks.amazonaws.com/role-arn"]' \
    "$STUB_EDNS_IRSA" \
    "external-dns: SA has IRSA annotation"

  # Pod args must include the AWS provider.
  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].args | .[]' \
    "^--provider=aws$" \
    "external-dns: pod arg --provider=aws"

  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].args | .[]' \
    "^--domain-filter=$STUB_DOMAIN$" \
    "external-dns: pod arg --domain-filter=$STUB_DOMAIN"

  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].args | .[]' \
    "^--policy=upsert-only$" \
    "external-dns: pod arg --policy=upsert-only"

  assert_yq_matches "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].args | .[]' \
    "^--source=ingress$" \
    "external-dns: pod arg --source=ingress"

  assert_yq_eq "$OUT" \
    'select(.kind=="Deployment" and .metadata.name=="external-dns") | .spec.template.spec.containers[0].env[] | select(.name=="AWS_REGION") | .value' \
    "$STUB_REGION" \
    "external-dns: AWS_REGION env set"
else
  fail "external-dns: helm template failed" "$(cat "$OUT.err" 2>/dev/null | tail -10)"
fi

echo "── helm-render: external-secrets ─────────────────────────────────"
OUT="$TMP/eso.yaml"
if helm_render \
  "https://charts.external-secrets.io" \
  "external-secrets" \
  "$ESO_VERSION" \
  "$OUT" \
  "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$STUB_ESO_IRSA"; then

  assert_yq_eq "$OUT" \
    'select(.kind=="ServiceAccount" and .metadata.name=="external-secrets") | .metadata.annotations["eks.amazonaws.com/role-arn"]' \
    "$STUB_ESO_IRSA" \
    "eso: SA external-secrets has IRSA annotation"
else
  fail "eso: helm template failed" "$(cat "$OUT.err" 2>/dev/null | tail -10)"
fi

echo "── helm-render: kyverno ──────────────────────────────────────────"
# OI-2026-06-11-2: chart 3.2.6 defaults the report-cleanup CronJobs (and
# webhooksCleanup) to docker.io/bitnami/kubectl:1.28.5 — unpullable since
# the Bitnami catalog pullback, so reports never get cleaned and the
# accumulation OOM-kills the fail-closed admission controller. helm.tf
# overrides every such image to the relocated bitnamilegacy archive; this
# render pins that NO non-legacy bitnami/kubectl image survives, and the
# OOM headroom override is present.
KYVERNO_VERSION="3.2.6"
OUT="$TMP/kyverno.yaml"
if helm_render   "https://kyverno.github.io/kyverno/"   "kyverno"   "$KYVERNO_VERSION"   "$OUT"   "admissionController.container.resources.limits.memory=768Mi"   "admissionController.container.resources.limits.cpu=100m"   "webhooksCleanup.image.repository=bitnamilegacy/kubectl"   "cleanupJobs.admissionReports.image.repository=bitnamilegacy/kubectl"   "cleanupJobs.clusterAdmissionReports.image.repository=bitnamilegacy/kubectl"   "cleanupJobs.ephemeralReports.image.repository=bitnamilegacy/kubectl"   "cleanupJobs.clusterEphemeralReports.image.repository=bitnamilegacy/kubectl"   "cleanupJobs.updateRequests.image.repository=bitnamilegacy/kubectl" \
  "policyReportsCleanup.image.repository=bitnamilegacy/kubectl"; then

  # No rendered workload may reference the unpullable non-legacy image.
  BAD_IMAGES="$(grep -oE 'image: "?[^"]*bitnami/kubectl[^"]*' "$OUT" | grep -v bitnamilegacy || true)"
  if [ -z "$BAD_IMAGES" ]; then
    pass "kyverno: no unpullable bitnami/kubectl image in render (all legacy)"
  else
    fail "kyverno: unpullable bitnami/kubectl image rendered" "$BAD_IMAGES"
  fi

  # Every cleanup CronJob rides the legacy archive.
  CRON_IMGS="$(yq -r 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].image' "$OUT" | grep -v '^---$' | grep -v '^null$' | sort -u)"
  if [ -n "$CRON_IMGS" ] && ! grep -qv "bitnamilegacy/kubectl" <<<"$CRON_IMGS"; then
    pass "kyverno: all cleanup CronJobs use bitnamilegacy/kubectl ($(wc -l <<<"$CRON_IMGS") image variant(s))"
  else
    fail "kyverno: cleanup CronJob image drift" "$CRON_IMGS"
  fi

  # The admission controller carries the OOM-headroom limit.
  assert_yq_eq "$OUT"     'select(.kind=="Deployment" and .metadata.name=="kyverno-admission-controller") | .spec.template.spec.containers[0].resources.limits.memory'     "768Mi"     "kyverno: admission controller memory limit 768Mi (OI-2026-06-11-2 OOM headroom)"
else
  fail "kyverno: helm template failed" "$(cat "$OUT.err" 2>/dev/null | tail -10)"
fi

echo "── helm-render: ingress-nginx ────────────────────────────────────"
OUT="$TMP/ingress-nginx.yaml"
if helm_render \
  "https://kubernetes.github.io/ingress-nginx" \
  "ingress-nginx" \
  "$INGRESS_NGINX_VERSION" \
  "$OUT" \
  "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb" \
  "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-ssl-cert=$STUB_ACM_ARN" \
  "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-ssl-ports=443" \
  "controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-backend-protocol=http" \
  "controller.service.targetPorts.https=http"; then

  # Service has the NLB annotation set.
  assert_yq_eq "$OUT" \
    'select(.kind=="Service" and .metadata.name=="ingress-nginx-controller") | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-type"]' \
    "nlb" \
    "ingress-nginx: Service has aws-load-balancer-type=nlb"

  assert_yq_eq "$OUT" \
    'select(.kind=="Service" and .metadata.name=="ingress-nginx-controller") | .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-ssl-cert"]' \
    "$STUB_ACM_ARN" \
    "ingress-nginx: Service has the ACM cert annotation"

  # Port 443 targets the http port (NLB terminates TLS, nginx serves plain HTTP).
  assert_yq_eq "$OUT" \
    'select(.kind=="Service" and .metadata.name=="ingress-nginx-controller") | .spec.ports[] | select(.name=="https") | .targetPort' \
    "http" \
    "ingress-nginx: port 443 (https) → targetPort http (TLS-termination at NLB)"
else
  fail "ingress-nginx: helm template failed" "$(cat "$OUT.err" 2>/dev/null | tail -10)"
fi

summary
