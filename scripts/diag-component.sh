#!/usr/bin/env bash
# All-in-one diagnostic dump for one of our managed components.
# Usage: scripts/diag-component.sh <component> [<claim-namespace> <claim-name>]
# Components: argocd | crossplane | external-dns | eso | ingress-nginx | kyverno | platform-secret

set -uo pipefail

usage() {
  sed -n '2,5p' "$0"
  echo ""
  echo "Components:"
  for c in argocd crossplane external-dns eso ingress-nginx kyverno platform-secret; do
    echo "  - $c"
  done
  echo ""
  echo "Extra args:"
  echo "  platform-secret <namespace> <claim-name>"
  echo "    Dump the full XR / Composition / ExternalSecret / ASM secret"
  echo "    state for one specific PlatformSecret claim."
  exit "${1:-1}"
}

case "${1:-}" in
  -h|--help|"") usage 0 ;;
esac

COMPONENT="$1"

# Map component → namespace, label selector.
case "$COMPONENT" in
  argocd)          NS=argocd            SEL="app.kubernetes.io/part-of=argocd" ;;
  crossplane)      NS=crossplane-system SEL="app=crossplane" ;;
  external-dns)    NS=external-dns      SEL="app.kubernetes.io/name=external-dns" ;;
  eso)             NS=external-secrets  SEL="app.kubernetes.io/name=external-secrets" ;;
  ingress-nginx)   NS=ingress-nginx     SEL="app.kubernetes.io/name=ingress-nginx" ;;
  kyverno)         NS=kyverno           SEL="app.kubernetes.io/part-of=kyverno" ;;
  platform-secret) NS="" SEL="" ;;  # custom handler below
  *)               echo "unknown component: $COMPONENT"; usage 1 ;;
esac

# ---------------------------------------------------------------------
# Cluster-resource-shaped components (argocd, crossplane, …) share the
# same dump shape. PlatformSecret is a Crossplane Claim, so it has a
# different shape (XR + managed AWS resource + ExternalSecret + K8s
# Secret) and gets its own handler below.
# ---------------------------------------------------------------------

if [ "$COMPONENT" = "platform-secret" ]; then
  CLAIM_NS="${2:-}"
  CLAIM_NAME="${3:-}"

  echo "══════════════════════════════════════════════════════════════════"
  echo "  PlatformSecret diagnostics"
  echo "══════════════════════════════════════════════════════════════════"

  echo ""
  echo "── CRDs present? ─────────────────────────────────────────────────"
  # Crossplane v2: no claim CRD (XR is the user-facing object); the AWS
  # secretsmanager group is the namespaced `.m.upbound.io` variant.
  for crd in \
      xplatformsecrets.platform.k8-platform.io \
      compositions.apiextensions.crossplane.io \
      externalsecrets.external-secrets.io \
      clustersecretstores.external-secrets.io \
      secrets.secretsmanager.aws.m.upbound.io
  do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
      echo "  ✓ $crd"
    else
      echo "  ✗ $crd  (missing — phase 2 not synced yet?)"
    fi
  done

  echo ""
  echo "── ClusterSecretStore aws-secrets-manager status ────────────────"
  kubectl get clustersecretstore aws-secrets-manager \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}: {.message}){"\n"}{end}' \
    2>&1 | sed 's/^/  /'

  if [ -z "$CLAIM_NS" ] || [ -z "$CLAIM_NAME" ]; then
    echo ""
    echo "── All XPlatformSecret XRs (every namespace) ────────────────────"
    # Crossplane v2: XR is the user-facing object; no separate claim
    # type. The "claim namespace" the operator types is the namespace
    # the XR lives in.
    kubectl get xplatformsecret -A 2>&1 | sed 's/^/  /'
    echo ""
    echo "(Pass <namespace> <name> as args 2 and 3 for full per-XR dump.)"
    exit 0
  fi

  echo ""
  echo "── XR (composite): $CLAIM_NS/$CLAIM_NAME ───────────────────────"
  # Crossplane v2: no claim → XR walk needed; the XR is the user-facing
  # object and lives in the namespace the caller passed.
  kubectl get xplatformsecret -n "$CLAIM_NS" "$CLAIM_NAME" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}: {.message}){"\n"}{end}' \
    2>&1 | sed 's/^/  /'
  XR_UID=$(kubectl get xplatformsecret -n "$CLAIM_NS" "$CLAIM_NAME" \
           -o jsonpath='{.metadata.uid}' 2>/dev/null)
  if [ -n "$XR_UID" ]; then
    echo ""
    echo "── Underlying AWS-Secret managed resource (k8-platform/$XR_UID) ─"
    kubectl get secrets.secretsmanager.aws.m.upbound.io -A 2>/dev/null \
      | grep "$XR_UID" | sed 's/^/  /' || echo "  (none)"
  fi

  echo ""
  echo "── ExternalSecret $CLAIM_NS/$CLAIM_NAME ──────────────────────────"
  kubectl get externalsecret -n "$CLAIM_NS" "$CLAIM_NAME" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}: {.message}){"\n"}{end}' \
    2>&1 | sed 's/^/  /'

  echo ""
  echo "── K8s Secret $CLAIM_NS/$CLAIM_NAME (materialized by ESO) ────────"
  if kubectl get secret -n "$CLAIM_NS" "$CLAIM_NAME" >/dev/null 2>&1; then
    kubectl get secret -n "$CLAIM_NS" "$CLAIM_NAME" \
      -o jsonpath='{range .data}{"  keys: "}{.}{"\n"}{end}' 2>&1 | sed 's/^/  /'
    kubectl get secret -n "$CLAIM_NS" "$CLAIM_NAME" \
      -o jsonpath='{"  resourceVersion: "}{.metadata.resourceVersion}{"\n  age: "}{.metadata.creationTimestamp}{"\n"}' \
      2>&1
  else
    echo "  (no K8s Secret — ESO hasn't synced yet, or claim is not Ready)"
  fi

  exit 0
fi

# ---------------------------------------------------------------------
# Default cluster-component dump.
# ---------------------------------------------------------------------

echo "══════════════════════════════════════════════════════════════════"
echo "  $COMPONENT  (ns=$NS, sel=$SEL)"
echo "══════════════════════════════════════════════════════════════════"

echo ""
echo "── pods ───────────────────────────────────────────────────────────"
kubectl get pods -n "$NS" -l "$SEL" -o wide 2>&1 | sed 's/^/  /'

echo ""
echo "── services ───────────────────────────────────────────────────────"
kubectl get svc -n "$NS" 2>&1 | sed 's/^/  /'

echo ""
echo "── service accounts (with IRSA annotation if any) ─────────────────"
kubectl get sa -n "$NS" \
  -o custom-columns=NAME:.metadata.name,IRSA_ROLE:'.metadata.annotations.eks\.amazonaws\.com/role-arn' \
  2>&1 | sed 's/^/  /'

echo ""
echo "── recent events ──────────────────────────────────────────────────"
kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>&1 | tail -25 | sed 's/^/  /'

echo ""
echo "── recent logs (--tail=80) ────────────────────────────────────────"
kubectl logs -n "$NS" -l "$SEL" --tail=80 --prefix=true 2>&1 | sed 's/^/  /'
