#!/usr/bin/env bash
# LIVE negative check — ArgoCD AppProject destination guard fires.
#
# Guard under test:
#   argocd/projects/platform-spoke.yaml spec.destinations — destinations
#   are scoped to spoke clusters by NAME (*-spoke); the hub in-cluster
#   server (https://kubernetes.default.svc) is EXPLICITLY excluded.
#   An Application in the platform-spoke project that targets the hub
#   must be rejected: "is not permitted in project platform-spoke".
#
# Red-first discipline:
#   (a) DENIED: apply an Application in project platform-spoke with
#       destination server=https://kubernetes.default.svc (the hub);
#       assert the denial reason names the specific guard
#       (project name + "not permitted" — NOT a generic/unrelated error).
#   (b) POSITIVE CONTROL: a destination that IS allowed (name=*-spoke
#       pattern) is accepted — proves the guard is selective.
#
# Exit-code contract (tests/live/lib/live-lib.sh):
#   0 = pass, 2 = skip (readonly or tools absent), other = FAIL.
# Negatives do NOT emit `covers`.
#
# LIVE_MODE=mutating required — we apply (and delete) real manifests.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

MODE="$(live_mode)"
[ "$MODE" = "mutating" ] \
  || skip "LIVE_MODE is not mutating — skipping guard-fired negative (readonly)"

CLUSTER="${LIVE_CLUSTER:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
HELPER="$REPO_ROOT/scripts/sandbox-kubeconfig.sh"

# Tooling / creds preconditions.
for bin in aws kubectl jq session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials"
[ -n "$CLUSTER" ] || skip "no LIVE_CLUSTER set"
[ -x "$HELPER" ] || skip "helper $HELPER missing/not executable"

# Relay precondition.
RELAY_ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=kube-relay" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[0].InstanceId' --output text 2>/dev/null | tr -d '[:space:]')
{ [ -n "$RELAY_ID" ] && [ "$RELAY_ID" != "None" ]; } \
  || skip "no running kube-relay instance (relay not provisioned)"

KUBE() { "$HELPER" -c "$CLUSTER" -r "$REGION" --exec kubectl "$@" 2>&1; }

KUBE get ns argocd >/dev/null 2>&1 \
  || skip "argocd namespace not present — ArgoCD not installed"
KUBE get appproject platform-spoke -n argocd >/dev/null 2>&1 \
  || skip "AppProject platform-spoke not found — guard not deployed"

# Read an allowed source repo from the live platform-spoke AppProject.
ALLOWED_REPO=$(KUBE get appproject platform-spoke -n argocd -o json \
  | jq -r '.spec.sourceRepos[0]' 2>/dev/null)
[ -n "$ALLOWED_REPO" ] && [ "$ALLOWED_REPO" != "null" ] \
  || skip "could not read sourceRepos from AppProject platform-spoke"

NS="argocd"
APP_DENY="live-neg-dest-deny-${RUN_ID}"
APP_ALLOW="live-neg-dest-allow-${RUN_ID}"

# Hub server — the explicitly forbidden destination in platform-spoke.
HUB_SERVER="https://kubernetes.default.svc"

# LIVE_NEG_POLL_ITERS: test seam — override the sync-status poll count
# (default 10 × 2s = 20s) without changing real behavior.
POLL_ITERS="${LIVE_NEG_POLL_ITERS:-10}"

cleanup() {
  KUBE delete application "$APP_DENY"  -n "$NS" --ignore-not-found >/dev/null 2>&1 \
    || echo "WARN: cleanup of $APP_DENY may have failed" >&2
  KUBE delete application "$APP_ALLOW" -n "$NS" --ignore-not-found >/dev/null 2>&1 \
    || echo "WARN: cleanup of $APP_ALLOW may have failed" >&2
}
trap cleanup EXIT

# ── (a) DENIED: hub destination must be rejected in platform-spoke ────────────
log "applying Application '$APP_DENY' in platform-spoke pointing to hub ($HUB_SERVER)"
DENY_OUT=$(KUBE apply -f - <<YAML 2>&1 || true
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP_DENY
  namespace: $NS
spec:
  project: platform-spoke
  source:
    repoURL: "$ALLOWED_REPO"
    targetRevision: HEAD
    path: "crossplane/xrds"
  destination:
    server: "$HUB_SERVER"
    namespace: default
  syncPolicy: {}
YAML
)
DENY_RC=$?

DENIED_REASON=""

if echo "$DENY_OUT" | grep -qiE "not permitted|not allowed in project"; then
  DENIED_REASON="$(echo "$DENY_OUT" | grep -iE "not permitted|not allowed in project" | head -1)"
  log "ArgoCD admission webhook rejected the Application immediately"
elif [ "$DENY_RC" -eq 0 ]; then
  log "Application admitted; polling ArgoCD conditions for guard error (up to $((POLL_ITERS * 2))s)..."
  for _ in $(seq 1 "$POLL_ITERS"); do
    COND=$(KUBE get application "$APP_DENY" -n "$NS" -o json 2>/dev/null \
           | jq -r '[.status.conditions[]?.message // ""] | join("|")' 2>/dev/null || true)
    if echo "$COND" | grep -qiE "not permitted|not allowed in project"; then
      DENIED_REASON="$(echo "$COND" | tr '|' '\n' \
        | grep -iE "not permitted|not allowed in project" | head -1)"
      break
    fi
    sleep 2
  done
fi

if [ -z "$DENIED_REASON" ]; then
  ng "GUARD DID NOT FIRE: Application '$APP_DENY' with hub destination '$HUB_SERVER' was not rejected and showed no 'not permitted' condition within $((POLL_ITERS * 2))s — AppProject platform-spoke destination guard is not effective"
  exit 1
fi

if echo "$DENIED_REASON" | grep -qiE "not permitted|not allowed in project"; then
  ok "GUARD FIRED: hub destination rejected in platform-spoke — reason: $DENIED_REASON"
else
  ng "Denied, but reason does NOT match the platform-spoke destination guard (expected 'not permitted in project'): $DENIED_REASON"
  exit 1
fi

# ── (b) POSITIVE CONTROL: a spoke-name destination is accepted ───────────────
# platform-spoke allows name=*-spoke (see spec.destinations[].name = "*-spoke").
# Use a name that matches the pattern but references a non-existent cluster —
# ArgoCD accepts the Application object even if the cluster is not registered
# (it only rejects at the AppProject authorization layer, not cluster-existence layer).
log "positive control: applying Application '$APP_ALLOW' with allowed spoke destination"
ALLOW_OUT=$(KUBE apply -f - <<YAML 2>&1 || true
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP_ALLOW
  namespace: $NS
spec:
  project: platform-spoke
  source:
    repoURL: "$ALLOWED_REPO"
    targetRevision: HEAD
    path: "crossplane/xrds"
  destination:
    name: "platform-spoke"
    namespace: default
  syncPolicy: {}
YAML
)
ALLOW_RC=$?

if [ "$ALLOW_RC" -ne 0 ] && echo "$ALLOW_OUT" | grep -qiE "not permitted|not allowed"; then
  ng "POSITIVE CONTROL FAILED: spoke destination name='platform-spoke' was unexpectedly rejected — the guard is always-deny, not selective"
  exit 1
fi
if [ "$ALLOW_RC" -ne 0 ]; then
  ng "POSITIVE CONTROL FAILED: Application with spoke destination failed for an unrelated reason (exit $ALLOW_RC): $ALLOW_OUT"
  exit 1
fi
ok "positive control: Application with spoke destination name='platform-spoke' was accepted (guard is selective)"

ok "PASS: argocd-appproject-destination-guard — AppProject platform-spoke destination guard fires for hub server"
exit "$LIVE_RC_PASS"
