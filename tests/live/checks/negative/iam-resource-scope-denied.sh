#!/usr/bin/env bash
# LIVE negative check (guard-fired) — auto-015-001 / OI-2026-06-08-1.
#
# Proves the narrowed Crossplane provider IAM policy (terraform/management/irsa.tf:
# IAMRoles -> role/k8-platform-*, IAMOIDCProviders -> oidc-provider/*) actually
# DENIES a create on a foreign ARN, against the RENDERED LIVE policy — not a source
# grep. Mechanism: aws iam simulate-principal-policy with the crossplane role as the
# policy source (it evaluates the role's attached crossplane_aws managed policy).
#
# RED-FIRST + wrong-reason-proof (per the decision brief's adversarial review):
#   - a POSITIVE control proves the action IS granted for k8-platform-*/oidc-provider/*
#     (so a denial cannot be blamed on a missing action — it must be the Resource scope);
#   - the NEGATIVE then proves a foreign ARN is denied. If the narrowing were reverted
#     to "*", the negative would read "allowed" and this check goes RED — that is the
#     red-first proof that it actually tests the guard.
#
# Runs under the SCOPED verifier/reaper role in the live suite; needs only
# iam:SimulatePrincipalPolicy (a READ — no mutation, safe in full+readonly). If that
# verb isn't granted yet (the mgmt apply that adds it hasn't run), or the crossplane
# role isn't provisioned, this SKIPs (not "done") — never a false green.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass, 2=skip, other=fail.
# Emits NO `covers` line (a negative does not satisfy a kind's coverage).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

CLUSTER_ROLE="${CROSSPLANE_ROLE_NAME:-k8-platform-mgmt-crossplane}"

for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (IAM scope deny check not exercisable here)"
done
ACCT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || skip "no usable AWS credentials in this environment"
ROLE_ARN="arn:aws:iam::${ACCT}:role/${CLUSTER_ROLE}"

# The crossplane role must exist (else the narrowed policy isn't provisioned here).
aws iam get-role --role-name "$CLUSTER_ROLE" >/dev/null 2>&1 \
  || skip "crossplane role $CLUSTER_ROLE not provisioned in this account (narrowed policy absent)"

# Probe: is iam:SimulatePrincipalPolicy granted to THIS identity? Distinguish a
# caller-AccessDenied (verb not yet applied) from a normal evaluation result.
probe_err="$(aws iam simulate-principal-policy \
  --policy-source-arn "$ROLE_ARN" --action-names iam:GetRole \
  --resource-arns "$ROLE_ARN" 2>&1 >/dev/null)" || true
case "$probe_err" in
  *"not authorized to perform: iam:SimulatePrincipalPolicy"*|*"AccessDenied"*"SimulatePrincipalPolicy"*)
    skip "iam:SimulatePrincipalPolicy not granted to this identity yet (mgmt apply of the +verb pending) — deny check not exercisable" ;;
esac

# simulate <action> <resource-arn> -> echoes "DECISION|matched_source_policy_ids"
simulate() {
  local action="$1" res="$2" out
  out="$(aws iam simulate-principal-policy \
          --policy-source-arn "$ROLE_ARN" \
          --action-names "$action" \
          --resource-arns "$res" \
          --output json 2>/dev/null)" || { echo "ERROR|"; return; }
  printf '%s|%s\n' \
    "$(printf '%s' "$out" | jq -r '.EvaluationResults[0].EvalDecision // "ERROR"')" \
    "$(printf '%s' "$out" | jq -r '[.EvaluationResults[0].MatchedStatements[]?.SourcePolicyId] | join(",")')"
}

decision() { printf '%s' "$1" | cut -d'|' -f1; }
matched()  { printf '%s' "$1" | cut -d'|' -f2; }

log "simulating against the rendered policy on $ROLE_ARN"

POS_ROLE="$(simulate iam:CreateRole                 "arn:aws:iam::${ACCT}:role/k8-platform-live-verify-probe")"
NEG_ROLE="$(simulate iam:CreateRole                 "arn:aws:iam::${ACCT}:role/definitely-not-ours-probe")"
POS_OIDC="$(simulate iam:CreateOpenIDConnectProvider "arn:aws:iam::${ACCT}:oidc-provider/oidc.eks.probe.amazonaws.com/id/SCRATCH")"
NEG_OIDC="$(simulate iam:CreateOpenIDConnectProvider "arn:aws:iam::${ACCT}:role/definitely-not-ours-probe")"

log "  CreateRole  k8-platform-*  => $(decision "$POS_ROLE")  (matched: $(matched "$POS_ROLE"))"
log "  CreateRole  foreign        => $(decision "$NEG_ROLE")"
log "  CreateOIDC  oidc-provider/*=> $(decision "$POS_OIDC")  (matched: $(matched "$POS_OIDC"))"
log "  CreateOIDC  role-arn(cross)=> $(decision "$NEG_OIDC")"

fail=0

# POSITIVE controls: the action IS granted for the in-scope resource, and the allow
# comes from OUR crossplane policy (so a later denial is provably the Resource scope).
if [ "$(decision "$POS_ROLE")" != "allowed" ]; then
  ng "positive control FAILED: CreateRole on role/k8-platform-* is not allowed (decision=$(decision "$POS_ROLE")) — policy misconfigured"; fail=1
elif ! printf '%s' "$(matched "$POS_ROLE")" | grep -qi 'crossplane'; then
  ng "positive control suspicious: CreateRole allow did not match the crossplane policy (matched=$(matched "$POS_ROLE"))"; fail=1
else
  ok "positive: CreateRole on role/k8-platform-* is allowed by the crossplane policy"
fi
if [ "$(decision "$POS_OIDC")" != "allowed" ]; then
  ng "positive control FAILED: CreateOIDC on oidc-provider/* is not allowed (decision=$(decision "$POS_OIDC")) — policy misconfigured"; fail=1
else
  ok "positive: CreateOpenIDConnectProvider on oidc-provider/* is allowed"
fi

# NEGATIVE (the firing proof): a foreign ARN must NOT be allowed. Since the positive
# control proved the action is granted, a non-allowed decision here is the Resource
# scope firing — exactly what reverting to "*" would break.
if [ "$(decision "$NEG_ROLE")" = "allowed" ]; then
  ng "GUARD DID NOT FIRE: CreateRole on a foreign (non k8-platform-*) ARN was ALLOWED — the IAM Resource narrowing is not in effect (reverted to \"*\"?)"; fail=1
else
  ok "guard fired: CreateRole on a foreign role ARN is DENIED ($(decision "$NEG_ROLE"))"
fi
if [ "$(decision "$NEG_OIDC")" = "allowed" ]; then
  ng "GUARD DID NOT FIRE: CreateOpenIDConnectProvider on a role ARN was ALLOWED — the OIDC statement is not resource-typed correctly"; fail=1
else
  ok "guard fired: CreateOpenIDConnectProvider on a non-oidc-provider ARN is DENIED ($(decision "$NEG_OIDC"))"
fi

if [ "$fail" -ne 0 ]; then
  ng "IAM Resource-scope deny check FAILED — see above"
  exit 1
fi
ok "IAM Resource-scope narrowing is in effect and DENIES foreign create (role + OIDC), with positive controls"
exit "$LIVE_RC_PASS"
