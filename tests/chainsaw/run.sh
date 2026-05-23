#!/usr/bin/env bash
# Chainsaw harness orchestrator.
#
# Lifecycle:
#   1. Create a fresh kind cluster (pinned node image + digest).
#   2. Install Crossplane v2 (pinned chart version) + provider-family-aws
#      (pinned package version). Wait for provider Healthy=True.
#   3. Run every scenario under tests/chainsaw/* via `chainsaw test`.
#   4. Cleanup trap: best-effort delete any chainsaw-scoped ASM secrets
#      from this run, then `kind delete cluster`. Trap runs on any exit.
#
# Per AGENTS.md §6.6, the harness is designed to run end-to-end without
# user attention. Failures exit non-zero; the cluster is destroyed
# either way so successive runs start clean.
#
# Required tools on PATH:
#   - kind     (version pinned in versions.env)
#   - kubectl
#   - helm
#   - chainsaw (version pinned in versions.env)
#   - aws      (only for the ASM cleanup trap)
#
# Required env:
#   - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION — only when
#     running scenarios that hit real AWS. Smoke-only runs work without.
#
# Optional env:
#   - CHAINSAW_RUN_ID — overrides the auto-generated suffix. CI passes
#     $GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT to avoid parallel collisions.
#   - CHAINSAW_SCENARIOS — filter to a single subdir, e.g.
#     "platform-secret/00-claim-creates-secret".

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

# shellcheck disable=SC1091
. ./versions.env

CLUSTER_NAME="k8-platform-chainsaw"
KUBECONFIG_TMP="${RUNNER_TEMP:-/tmp}/chainsaw-kubeconfig"
export KUBECONFIG="$KUBECONFIG_TMP"

# Per-run suffix prevents parallel CI runs from colliding on shared AWS
# resources (ASM secret names within a single account). Stable across the
# script's lifetime so the cleanup trap sees the same prefix.
CHAINSAW_RUN_ID="${CHAINSAW_RUN_ID:-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8 || echo "$$")}"
export CHAINSAW_RUN_ID
export ASM_RUN_PREFIX="${ASM_PREFIX}-${CHAINSAW_RUN_ID}"

echo "── chainsaw harness ───────────────────────────────────────────"
echo "  cluster:       $CLUSTER_NAME"
echo "  node image:    $KINDEST_NODE_IMAGE"
echo "  crossplane:    $CROSSPLANE_CHART_VERSION"
echo "  provider AWS:  $PROVIDER_FAMILY_AWS_VERSION"
echo "  chainsaw:      $CHAINSAW_VERSION"
echo "  run id:        $CHAINSAW_RUN_ID"
echo "  asm prefix:    $ASM_RUN_PREFIX"
echo ""

# ---------- cleanup trap (runs on ANY exit) ---------------------------------
cleanup() {
  local rc=$?
  echo ""
  echo "── cleanup (rc=$rc) ───────────────────────────────────────────"

  # Best-effort: nuke any ASM secrets created under this run's prefix.
  # --force-delete-without-recovery skips the 7-30 day recovery window;
  # the chainsaw harness intentionally treats these as ephemeral.
  if command -v aws >/dev/null 2>&1 && [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    echo "  aws secretsmanager: deleting any leftover ${ASM_RUN_PREFIX}/* secrets"
    local leftover
    leftover=$(aws secretsmanager list-secrets \
      --filters "Key=name,Values=${ASM_RUN_PREFIX}/" \
      --query 'SecretList[].Name' --output text 2>/dev/null || true)
    if [ -n "$leftover" ]; then
      for s in $leftover; do
        aws secretsmanager delete-secret \
          --secret-id "$s" \
          --force-delete-without-recovery \
          --output text >/dev/null 2>&1 || \
          echo "    WARN: could not delete $s"
        echo "    deleted: $s"
      done
    else
      echo "    (none)"
    fi
  fi

  # Best-effort kind destroy.
  if command -v kind >/dev/null 2>&1; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    echo "  kind:           cluster destroyed"
  fi

  rm -f "$KUBECONFIG_TMP" || true
  echo "── done (rc=$rc) ─────────────────────────────────────────────"
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------- create cluster --------------------------------------------------
echo "── creating kind cluster ──────────────────────────────────────"
# Render kind config with the pinned node image substituted in.
RENDERED_CONFIG="${RUNNER_TEMP:-/tmp}/chainsaw-kind-rendered.yaml"
awk -v img="$KINDEST_NODE_IMAGE" '
  /^nodes:/ { print; in_nodes=1; next }
  in_nodes && /^  - role: control-plane/ {
    print
    print "    image: " img
    next
  }
  { print }
' kind-config.yaml > "$RENDERED_CONFIG"

kind create cluster \
  --name "$CLUSTER_NAME" \
  --config "$RENDERED_CONFIG" \
  --wait 120s

kubectl wait --for=condition=Ready node --all --timeout=120s

# ---------- install Crossplane ----------------------------------------------
echo ""
echo "── installing Crossplane ──────────────────────────────────────"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null
helm repo update crossplane-stable >/dev/null

helm install crossplane crossplane-stable/crossplane \
  --version "$CROSSPLANE_CHART_VERSION" \
  --namespace crossplane-system \
  --create-namespace \
  --wait \
  --timeout 5m

kubectl wait --for=condition=Available --timeout=300s \
  -n crossplane-system deploy/crossplane

# ---------- install AWS provider --------------------------------------------
echo ""
echo "── installing provider-family-aws ─────────────────────────────"
kubectl apply -f - <<MANIFEST
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-family-aws
spec:
  package: "xpkg.upbound.io/upbound/provider-family-aws:${PROVIDER_FAMILY_AWS_VERSION}"
MANIFEST

# Per adversarial-reviewer B: gate claim apply on Provider Healthy AND
# ProviderRevision Healthy. Without this, scenarios race the CRD install
# and fail with "no matches for kind". Single-line so the unit test's
# grep can verify the gate exists.
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/provider-family-aws --timeout=300s

# ---------- run chainsaw scenarios ------------------------------------------
echo ""
echo "── running chainsaw ───────────────────────────────────────────"
SCENARIO_ARG="${CHAINSAW_SCENARIOS:-.}"
chainsaw test "$SCENARIO_ARG" \
  --config chainsaw-config.yaml

echo ""
echo "── all scenarios passed ──────────────────────────────────────"
# trap handles cleanup
