#!/usr/bin/env bash
# Recent logs for a labelled deployment.
# Usage: scripts/k8s-logs.sh <namespace> [<label-selector>] [<tail-lines>]
# Default selector: app.kubernetes.io/component=controller (matches most
# Helm-chart-installed controllers we run).
# Default tail: 100

set -uo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ -z "${1:-}" ]; then
  sed -n '2,7p' "$0"; exit 0
fi

NS="$1"
SELECTOR="${2:-app.kubernetes.io/component=controller}"
TAIL="${3:-100}"

echo "── pods matching -l '$SELECTOR' in $NS ────────────────────────────"
kubectl get pods -n "$NS" -l "$SELECTOR" -o wide 2>&1 | sed 's/^/  /'

echo ""
echo "── logs (--tail=$TAIL) ─────────────────────────────────────────────"
kubectl logs -n "$NS" -l "$SELECTOR" --tail="$TAIL" 2>&1 | sed 's/^/  /'
