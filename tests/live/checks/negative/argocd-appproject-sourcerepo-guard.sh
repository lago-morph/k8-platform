#!/usr/bin/env bash
# LIVE negative check — ArgoCD AppProject sourceRepos guard fires.
#
# Guard under test:
#   argocd/projects/k8-platform.yaml spec.sourceRepos — only
#   "https://github.com/lago-morph/k8-platform.git" is allowed.
#   ArgoCD rejects an Application referencing any other repo with
#   "application repo <url> is not permitted in project k8-platform".
#
# Red-first discipline:
#   (a) DENIED: apply an Application whose spec.source.repoURL is NOT in
#       the allowlist; assert the denial reason names the specific guard
#       (project name + "not permitted" — NOT a generic/unrelated error).
#   (b) POSITIVE CONTROL: a closely matched Application using the allowed
#       repo is accepted — proves the guard is selective, not always-deny.
#
# Exit-code contract (tests/live/lib/live-lib.sh):
#   0 = pass, 2 = skip (readonly or tools absent), other = FAIL.
# Negatives do NOT emit `covers` (they do not satisfy kind-coverage).
#
# LIVE_MODE=mutating required — we apply (and delete) real manifests.
# In readonly we skip: ArgoCD enforcement only fires on apply/sync.

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

# Relay precondition — skip (not fail) if the kube-relay is unprovisioned.
RELAY_ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=kube-relay" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[0].InstanceId' --output text 2>/dev/null | tr -d '[:space:]')
{ [ -n "$RELAY_ID" ] && [ "$RELAY_ID" != "None" ]; } \
  || skip "no running kube-relay instance (relay not provisioned)"

# kubectl relay wrapper.
KUBE() { "$HELPER" -c "$CLUSTER" -r "$REGION" --exec kubectl "$@" 2>&1; }

# ArgoCD namespace and AppProject must exist; skip if unprovisioned.
KUBE get ns argocd >/dev/null 2>&1 \
  || skip "argocd namespace not present — ArgoCD not installed"
KUBE get appproject k8-platform -n argocd >/dev/null 2>&1 \
  || skip "AppProject k8-platform not found — guard not deployed"

# Read the first allowed repo from the live AppProject spec.
ALLOWED_REPO=$(KUBE get appproject k8-platform -n argocd -o json \
  | jq -r '.spec.sourceRepos[0]' 2>/dev/null)
[ -n "$ALLOWED_REPO" ] && [ "$ALLOWED_REPO" != "null" ] \
  || skip "could not read sourceRepos from AppProject k8-platform"

UNAUTHORIZED_REPO="https://github.com/attacker/evil-charts.git"
NS="argocd"
APP_DENY="live-neg-appproj-deny-${RUN_ID}"
APP_ALLOW="live-neg-appproj-allow-${RUN_ID}"
# LIVE_NEG_POLL_ITERS: test seam — override the sync-status poll count
# (default 10 × 2s = 20s) without changing real behavior.
POLL_ITERS="${LIVE_NEG_POLL_ITERS:-10}"

# Cleanup on any exit — best-effort but must surface if it errors beyond ignoring.
cleanup() {
  KUBE delete application "$APP_DENY"  -n "$NS" --ignore-not-found >/dev/null 2>&1 \
    || echo "WARN: cleanup of $APP_DENY may have failed" >&2
  KUBE delete application "$APP_ALLOW" -n "$NS" --ignore-not-found >/dev/null 2>&1 \
    || echo "WARN: cleanup of $APP_ALLOW may have failed" >&2
}
trap cleanup EXIT

# ── (a) DENIED: unauthorized source repo must be rejected ────────────────────
log "applying Application '$APP_DENY' with unauthorized repo: $UNAUTHORIZED_REPO"
DENY_OUT=$(KUBE apply -f - <<YAML 2>&1 || true
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP_DENY
  namespace: $NS
spec:
  project: k8-platform
  source:
    repoURL: "$UNAUTHORIZED_REPO"
    targetRevision: HEAD
    path: "."
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy: {}
YAML
)
DENY_RC=$?

DENIED_REASON=""

if echo "$DENY_OUT" | grep -qiE "not permitted|not allowed in project"; then
  # Webhook rejected at apply time.
  DENIED_REASON="$(echo "$DENY_OUT" | grep -iE "not permitted|not allowed in project" | head -1)"
  log "ArgoCD admission webhook rejected the Application immediately"
elif [ "$DENY_RC" -eq 0 ]; then
  # Application was admitted; poll ArgoCD sync status for up to 20s.
  log "Application admitted; polling ArgoCD conditions for guard error (up to 20s)..."
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
  ng "GUARD DID NOT FIRE: Application '$APP_DENY' with unauthorized repo '$UNAUTHORIZED_REPO' was not rejected at admission and showed no 'not permitted' condition within $((POLL_ITERS * 2))s — AppProject k8-platform sourceRepos guard is not effective"
  exit 1
fi

# Verify the reason is the specific guard — not a generic/unrelated error.
if echo "$DENIED_REASON" | grep -qiE "not permitted|not allowed in project"; then
  ok "GUARD FIRED: unauthorized repo denied — reason: $DENIED_REASON"
else
  ng "Denied, but reason does NOT match the k8-platform sourceRepos guard (expected 'not permitted in project'): $DENIED_REASON"
  exit 1
fi

# ── (b) POSITIVE CONTROL: allowed repo is accepted ───────────────────────────
log "positive control: applying Application '$APP_ALLOW' with allowed repo: $ALLOWED_REPO"
ALLOW_OUT=$(KUBE apply -f - <<YAML 2>&1 || true
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP_ALLOW
  namespace: $NS
spec:
  project: k8-platform
  source:
    repoURL: "$ALLOWED_REPO"
    targetRevision: HEAD
    path: "crossplane/xrds"
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy: {}
YAML
)
ALLOW_RC=$?

if [ "$ALLOW_RC" -ne 0 ] && echo "$ALLOW_OUT" | grep -qiE "not permitted|not allowed"; then
  ng "POSITIVE CONTROL FAILED: allowed repo '$ALLOWED_REPO' was unexpectedly rejected — the guard is always-deny, not selective"
  exit 1
fi
if [ "$ALLOW_RC" -ne 0 ]; then
  ng "POSITIVE CONTROL FAILED: Application with allowed repo failed for an unrelated reason (exit $ALLOW_RC): $ALLOW_OUT"
  exit 1
fi
ok "positive control: Application with allowed repo '$ALLOWED_REPO' was accepted (guard is selective)"

ok "PASS: argocd-appproject-sourcerepo-guard — AppProject k8-platform sourceRepos guard fires for unauthorized repos"
exit "$LIVE_RC_PASS"
