#!/usr/bin/env bash
# Snapshot of ArgoCD applications and their sync/health status.
# Usage: scripts/argocd-apps.sh [<app-name>]
# Without args, lists all Applications. With one arg, dumps full status
# (conditions, syncResult, resources) for that Application.

set -uo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,6p' "$0"; exit 0
fi

if [ $# -eq 0 ]; then
  echo "── AppProjects ────────────────────────────────────────────────────"
  kubectl get appproject -n argocd 2>&1 | sed 's/^/  /'

  echo ""
  echo "── Applications ───────────────────────────────────────────────────"
  kubectl get applications.argoproj.io -n argocd \
    -o custom-columns='NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' \
    2>&1 | sed 's/^/  /'
  exit 0
fi

APP="$1"
echo "── Application: $APP ──────────────────────────────────────────────"
kubectl get application.argoproj.io "$APP" -n argocd -o json 2>&1 \
  | jq '{
      project: .spec.project,
      source: .spec.source,
      destination: .spec.destination,
      sync: .status.sync,
      health: .status.health,
      operationState: .status.operationState | {phase, message, finishedAt},
      conditions: .status.conditions,
      resources: (.status.resources // [] | map({kind, name, namespace, status, health}))
    }'
