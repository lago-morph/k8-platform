#!/usr/bin/env bash
# Snapshot of ArgoCD applications and their sync/health status.
# Usage:
#   scripts/argocd-apps.sh                     — list Projects + Apps
#   scripts/argocd-apps.sh <app-name>          — full status of one App
#   scripts/argocd-apps.sh --platform-secrets  — claim status across namespaces
#
# The --platform-secrets mode dumps every PlatformSecret claim in the
# cluster alongside its composite XR and the ExternalSecret it should
# have rendered. Mirrors scripts/diag-component.sh platform-secret but
# scoped cluster-wide for ArgoCD operators eyeballing tenant claims.

set -uo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,10p' "$0"; exit 0
fi

if [ "${1:-}" = "--platform-secrets" ]; then
  if ! kubectl get crd platformsecrets.platform.k8-platform.io >/dev/null 2>&1; then
    echo "PlatformSecret CRD not present on this cluster — phase 2a not yet applied"
    exit 0
  fi
  echo "── PlatformSecret claims (cluster-wide) ──────────────────────────"
  kubectl get platformsecret -A \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SYNCED:.status.conditions[?(@.type=="Synced")].status,READY:.status.conditions[?(@.type=="Ready")].status,ASM_ARN:.status.asmSecretArn' \
    2>&1 | sed 's/^/  /'

  echo ""
  echo "── Composite XPlatformSecret resources ────────────────────────────"
  kubectl get xplatformsecret \
    -o custom-columns='NAME:.metadata.name,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,SYNCED:.status.conditions[?(@.type=="Synced")].status,READY:.status.conditions[?(@.type=="Ready")].status' \
    2>&1 | sed 's/^/  /'

  echo ""
  echo "── ExternalSecrets rendered by claims ─────────────────────────────"
  # Filter to ESes labelled by Crossplane composite ownership. Without
  # a label selector this would show every ESO secret in the cluster
  # (including ESes hand-authored outside the platform abstraction).
  kubectl get externalsecret -A -l crossplane.io/composite \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,REASON:.status.conditions[?(@.type=="Ready")].reason,REFRESH:.spec.refreshInterval' \
    2>&1 | sed 's/^/  /'
  exit 0
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
