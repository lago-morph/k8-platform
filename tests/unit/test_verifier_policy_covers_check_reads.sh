#!/usr/bin/env bash
# Every aws CLI read the after-tier live checks make MUST be granted by the
# scoped verifier/reaper policy — the class behind live-verify run
# 28759141867 (2026-07-05): checks called ec2:DescribeVpcs /
# eks:ListTagsForResource under the scoped role, the policy lacked the
# verbs, and the denied reads surfaced as a FALSE placement-bug FAIL and
# two false "not provisioned" skips (promoted to expect-full violations).
# The checks are developed under sandbox/admin creds, so a missing verb is
# exactly the drift this test exists to catch BEFORE a CI dispatch.
#
# Mechanics: extract `aws <service> <operation>` tokens from
# tests/live/checks/after/*.sh, map kebab-case to the IAM action name
# (describe-vpcs → DescribeVpcs), and assert `<service>:<Action>` appears
# in terraform/management/policies/verifier-reaper-policy.json.tftpl.
#
# Scope notes (deliberate):
#   - after tier only: instantiate/negative checks run in mutating mode
#     from the sandbox (admin creds), not under the scoped CI role.
#   - direct calls only: scripts/sandbox-kubeconfig.sh (the SSM relay
#     helper) is sandbox-tooling; on CI the relay checks skip before it.
#   - `aws sts get-caller-identity` maps to sts:GetCallerIdentity like any
#     other verb (it IS in the policy).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

ROOT="$HERE/../.."
POLICY="$ROOT/terraform/management/policies/verifier-reaper-policy.json.tftpl"
CHECKS_DIR="$ROOT/tests/live/checks/after"

[ -f "$POLICY" ] || { fail "policy template present" "$POLICY missing"; summary; }
[ -d "$CHECKS_DIR" ] || { fail "after-tier dir present" "$CHECKS_DIR missing"; summary; }
pass "policy + after-tier checks present"

# kebab → Pascal with AWS's irregular acronym casing: bare `id`/`db`
# segments uppercase fully (get-open-id-connect-provider →
# GetOpenIDConnectProvider, describe-db-instances → DescribeDBInstances)
# while ordinary words title-case (describe-vpcs → DescribeVpcs — the real
# action is Vpcs, not VPCs).
to_action() {
  printf '%s' "$1" | awk -F- '{
    for (i=1; i<=NF; i++) {
      if ($i == "id" || $i == "db") printf "%s", toupper($i)
      else printf "%s%s", toupper(substr($i,1,1)), substr($i,2)
    }
  }'
}

found_any=0
while IFS= read -r line; do
  # line = "<svc> <op>"
  svc="${line%% *}"; op="${line##* }"
  action="${svc}:$(to_action "$op")"
  found_any=1
  if grep -q "\"${action}\"" "$POLICY"; then
    pass "policy grants $action"
  else
    fail "policy grants $action" "an after-tier check calls 'aws $svc $op' but $action is absent from $POLICY — under the scoped verifier role that read is DENIED and the check lies about world state (the 28759141867 class)"
  fi
done < <(grep -rhoE 'aws +[a-z0-9-]+ +[a-z0-9-]+' "$CHECKS_DIR"/*.sh \
          | sed -E 's/^aws +//; s/ +/ /' \
          | grep -E '^(acm|ec2|eks|iam|rds|route53|secretsmanager|sts|tag|cloudtrail|servicequotas|accessanalyzer) ' \
          | sort -u)

[ "$found_any" -eq 1 ] \
  && pass "extractor found aws calls to audit" \
  || fail "extractor found aws calls" "no aws CLI calls extracted from $CHECKS_DIR — extractor broken?"

summary
