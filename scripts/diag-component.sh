#!/usr/bin/env bash
# All-in-one diagnostic dump for one of our managed components.
# Usage: scripts/diag-component.sh <component>
# Components: argocd | crossplane | external-dns | eso | ingress-nginx | kyverno

set -uo pipefail

usage() {
  sed -n '2,5p' "$0"
  echo ""
  echo "Components:"
  for c in argocd crossplane external-dns eso ingress-nginx kyverno; do
    echo "  - $c"
  done
  exit "${1:-1}"
}

case "${1:-}" in
  -h|--help|"") usage 0 ;;
esac

COMPONENT="$1"

# Map component → namespace, label selector.
case "$COMPONENT" in
  argocd)         NS=argocd            SEL="app.kubernetes.io/part-of=argocd" ;;
  crossplane)     NS=crossplane-system SEL="app=crossplane" ;;
  external-dns)   NS=external-dns      SEL="app.kubernetes.io/name=external-dns" ;;
  eso)            NS=external-secrets  SEL="app.kubernetes.io/name=external-secrets" ;;
  ingress-nginx)  NS=ingress-nginx     SEL="app.kubernetes.io/name=ingress-nginx" ;;
  kyverno)        NS=kyverno           SEL="app.kubernetes.io/part-of=kyverno" ;;
  *)              echo "unknown component: $COMPONENT"; usage 1 ;;
esac

echo "══════════════════════════════════════════════════════════════════"
echo "  $COMPONENT  (ns=$NS, sel=$SEL)"
echo "══════════════════════════════════════════════════════════════════"

echo ""
echo "── pods ───────────────────────────────────────────────────────────"
kubectl get pods -n "$NS" -l "$SELECTOR" -o wide 2>&1 | sed 's/^/  /'

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
