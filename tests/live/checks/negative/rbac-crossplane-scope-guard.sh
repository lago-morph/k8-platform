#!/usr/bin/env bash
# LIVE negative check — Crossplane composite SA RBAC scope guard fires.
#
# Guard under test:
#   crossplane/rbac/01-crossplane-externalsecrets.yaml — the ClusterRole
#   "crossplane-composite-externalsecrets" grants the crossplane SA (in
#   crossplane-system) exactly: get/list/watch/create/update/patch/delete
#   on external-secrets.io/externalsecrets and externalsecrets/status.
#   It does NOT grant access to ClusterSecretStore, SecretStore, or any
#   other external-secrets.io resource.
#
# Red-first discipline:
#   (a) DENIED: impersonate the crossplane SA and attempt to `get` a
#       ClusterSecretStore (not in the grant); assert the denial comes
#       back as "no" / Forbidden — confirming the RBAC boundary fires.
#       The specific guard: the ClusterRole
#       "crossplane-composite-externalsecrets" limits the SA to
#       externalsecrets only.
#   (b) POSITIVE CONTROL: the same SA CAN `get` externalsecrets (within
#       the grant) — proves the guard is selective, not always-deny.
#
# Exit-code contract (tests/live/lib/live-lib.sh):
#   0 = pass, 2 = skip (readonly or tools absent), other = FAIL.
# Negatives do NOT emit `covers`.
#
# LIVE_MODE=mutating required — we drive real API calls against the
# cluster (kubectl auth can-i sends a SubjectAccessReview to the API server,
# which is a write to the authorization API).

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
for bin in aws kubectl session-manager-plugin; do
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

# Verify Crossplane is installed.
KUBE get ns crossplane-system >/dev/null 2>&1 \
  || skip "crossplane-system namespace not present — Crossplane not installed"

# Verify the guarding ClusterRole exists — skip if the guard is not deployed.
KUBE get clusterrole crossplane-composite-externalsecrets >/dev/null 2>&1 \
  || skip "ClusterRole crossplane-composite-externalsecrets not found — guard not deployed"

# Verify the ClusterRoleBinding binds the crossplane SA.
KUBE get clusterrolebinding crossplane-composite-externalsecrets >/dev/null 2>&1 \
  || skip "ClusterRoleBinding crossplane-composite-externalsecrets not found — guard not deployed"

CROSSPLANE_SA="system:serviceaccount:crossplane-system:crossplane"

# ── (a) DENIED: crossplane SA must NOT be able to get ClusterSecretStores ────
# ClusterSecretStore is NOT in the crossplane-composite-externalsecrets grant.
log "testing: can crossplane SA get clustersecretstores? (expected: NO)"
DENY_OUT=$(KUBE auth can-i get clustersecretstores \
  --as "$CROSSPLANE_SA" 2>&1 || true)

# `kubectl auth can-i` exits 1 and prints "no" when the verb is forbidden.
if echo "$DENY_OUT" | grep -qE "^no$|^no "; then
  ok "GUARD FIRED: crossplane SA cannot get clustersecretstores (answer: 'no') — RBAC boundary from ClusterRole crossplane-composite-externalsecrets is effective"
  DENIED=1
elif echo "$DENY_OUT" | grep -qiE "forbidden|does not have"; then
  ok "GUARD FIRED: crossplane SA cannot get clustersecretstores (Forbidden) — RBAC boundary effective"
  DENIED=1
else
  DENIED=0
fi

if [ "$DENIED" -eq 0 ]; then
  if echo "$DENY_OUT" | grep -qE "^yes"; then
    ng "GUARD DID NOT FIRE: crossplane SA CAN get clustersecretstores — ClusterRole crossplane-composite-externalsecrets is over-permissive (expected: no ClusterSecretStore access)"
  else
    ng "Unexpected output from auth can-i (expected 'no' or 'yes'); got: $DENY_OUT"
  fi
  exit 1
fi

# Verify the denial is specific to the RBAC guard, not an infrastructure issue.
# A non-existent CRD also returns "no"; confirm the SA itself authenticates fine
# by checking a namespace verb it definitely has (read pods via cluster-admin or
# by virtue of crossplane's own SA having self-check access).
# We validate selectivity via the positive control instead (below).

# ── (b) POSITIVE CONTROL: crossplane SA CAN get externalsecrets ──────────────
# externalsecrets IS in the grant: apiGroups=[external-secrets.io] resources=[externalsecrets]
log "positive control: can crossplane SA get externalsecrets? (expected: YES)"
ALLOW_OUT=$(KUBE auth can-i get externalsecrets \
  --as "$CROSSPLANE_SA" 2>&1 || true)

if echo "$ALLOW_OUT" | grep -qE "^yes$|^yes "; then
  ok "positive control: crossplane SA CAN get externalsecrets (answer: 'yes') — guard is selective, not always-deny"
else
  ng "POSITIVE CONTROL FAILED: crossplane SA cannot get externalsecrets — expected 'yes' (the ClusterRole grants this); got: $ALLOW_OUT  (the guard may be always-deny, or the ClusterRole/binding is broken)"
  exit 1
fi

ok "PASS: rbac-crossplane-scope-guard — ClusterRole crossplane-composite-externalsecrets boundary fires for ClusterSecretStore (not in grant)"
exit "$LIVE_RC_PASS"
