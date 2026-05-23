#!/usr/bin/env bash
# List installed Kyverno ClusterPolicies with their action mode and a
# 1-line description.

set -uo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,4p' "$0"; exit 0
fi

echo "── ClusterPolicies ────────────────────────────────────────────────"
kubectl get clusterpolicies.kyverno.io \
  -o custom-columns='NAME:.metadata.name,ACTION:.spec.validationFailureAction,READY:.status.ready,BACKGROUND:.spec.background' \
  2>&1 | sed 's/^/  /'

echo ""
echo "── titles (from annotations) ──────────────────────────────────────"
kubectl get clusterpolicies.kyverno.io -o json 2>/dev/null \
  | jq -r '.items[] | "  \(.metadata.name): \(.metadata.annotations["policies.kyverno.io/title"] // "(no title)")"' \
  2>&1
