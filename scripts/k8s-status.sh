#!/usr/bin/env bash
# Overall cluster snapshot: nodes, namespaces we care about, pod-state counts.
# Read-only. Usage: scripts/k8s-status.sh

set -uo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,3p' "$0"; exit 0
fi

echo "── nodes ──────────────────────────────────────────────────────────"
kubectl get nodes -o wide 2>&1 | sed 's/^/  /'

echo ""
echo "── namespaces ─────────────────────────────────────────────────────"
kubectl get ns 2>&1 \
  | awk 'NR==1 || /^(argocd|crossplane-system|external-dns|external-secrets|ingress-nginx|kyverno)/' \
  | sed 's/^/  /'

echo ""
echo "── pod-state summary ──────────────────────────────────────────────"
for ns in argocd crossplane-system external-dns external-secrets ingress-nginx kyverno; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null)
    if [ -z "$pods" ]; then
      printf "  %-20s  (no pods)\n" "$ns"
      continue
    fi
    running=$(echo "$pods" | grep -c " Running ")
    pending=$(echo "$pods" | grep -c " Pending ")
    failed=$(echo "$pods" | grep -cE " (Error|CrashLoopBackOff|ImagePullBackOff|Failed) ")
    total=$(echo "$pods" | wc -l)
    printf "  %-20s  total=%d  running=%d  pending=%d  failed=%d\n" \
      "$ns" "$total" "$running" "$pending" "$failed"
  fi
done

echo ""
echo "── helm releases (across our namespaces) ──────────────────────────"
helm list -A 2>&1 \
  | awk 'NR==1 || $2 ~ /^(argocd|crossplane-system|external-dns|external-secrets|ingress-nginx|kyverno)$/' \
  | sed 's/^/  /'

echo ""
echo "── recent warning events (last 50) ────────────────────────────────"
kubectl get events --all-namespaces --field-selector type=Warning \
  --sort-by=.lastTimestamp 2>&1 | tail -50 | sed 's/^/  /'
