#!/usr/bin/env bash
# LIVE behavioral check (after tier) -- a Crossplane-provisioned IAM
# RolePolicy (inline policy) is real.
#
# This is the BEHAVIORAL oracle for iam.aws.m.upbound.io/RolePolicy per
# ADR-0006. Inline RolePolicy resources carry no tags in AWS; they are
# selected INDIRECTLY via their parent role, which IS crossplane-stamped
# (crossplane-kind=role.iam.aws.m.upbound.io). For each such role we assert
# >= 1 inline policy name is present. Policy documents are NOT retrieved
# (read-only, no secret/policy-content exfiltration per ADR-0006 NON-GOAL).
#
# NOTE: inline policies (RolePolicy) may NOT be provisioned in this account
# -- a clean SKIP is the correct expected result. The crossplane cluster/node
# roles use managed-policy attachments (RolePolicyAttachment), not inlines.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (list only) -- safe in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="iam.aws.m.upbound.io/RolePolicy"   # IAM is global -- no region

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (IAM RolePolicy live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for Crossplane-provisioned IAM inline policies via crossplane-tagged roles"

# List all IAM roles; skip AWSServiceRole* (service-linked, never crossplane).
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell expansion
ROLES_JSON="$(aws iam list-roles \
  --query 'Roles[?!starts_with(RoleName, `AWSServiceRole`)].RoleName' \
  --output json 2>/dev/null)" || skip "iam:ListRoles not permitted / unavailable here"

COUNT="$(printf '%s' "$ROLES_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no non-service-linked IAM roles in the account"

# Collect crossplane-tagged roles.
xp_roles=()
while IFS= read -r role_name; do
  [ -z "$role_name" ] && continue
  tags="$(aws iam list-role-tags --role-name "$role_name" \
            --query 'Tags' --output json 2>/dev/null)" || continue
  is_xp="$(printf '%s' "$tags" | jq -r '
    (map({(.Key): .Value}) | add // {}) as $t
    | if ($t["crossplane-kind"] == "role.iam.aws.m.upbound.io")
      then "yes" else "no" end')"
  if [ "$is_xp" = "yes" ]; then
    xp_roles+=("$role_name")
  fi
done <<EOF
$(printf '%s' "$ROLES_JSON" | jq -r '.[]')
EOF

[ "${#xp_roles[@]}" -gt 0 ] || skip "no IAM role tagged crossplane-kind=role.iam.aws.m.upbound.io (parent role absent -- RolePolicy path not provisioned)"

# For each crossplane-tagged parent role, check for inline policies.
# Do NOT retrieve policy documents -- existence check only.
found_role=""; found_count=0
for role_name in "${xp_roles[@]}"; do
  policy_names="$(aws iam list-role-policies --role-name "$role_name" \
                    --query 'PolicyNames' --output json 2>/dev/null)" || continue
  cnt="$(printf '%s' "$policy_names" | jq 'length')"
  if [ "${cnt:-0}" -gt 0 ]; then
    found_role="$role_name"
    found_count="$cnt"
    break
  fi
done

if [ -z "$found_role" ]; then
  skip "crossplane-tagged roles found but none have inline policies (RolePolicy kind is not provisioned in this account -- this is the expected state; cluster/node roles use managed-policy attachments instead)"
fi

ok "IAM role '$found_role' has $found_count inline policy name(s) (RolePolicy via crossplane-tagged parent)"
covers "$KIND"
exit "$LIVE_RC_PASS"
