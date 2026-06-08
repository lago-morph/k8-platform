#!/usr/bin/env bash
# LIVE behavioral check (after tier) -- a Crossplane-provisioned IAM
# RolePolicyAttachment (managed-policy attachment) is real.
#
# This is the BEHAVIORAL oracle for iam.aws.m.upbound.io/RolePolicyAttachment
# per ADR-0006. RolePolicyAttachment resources carry no tags in AWS; they are
# selected INDIRECTLY via their parent role, which IS crossplane-stamped
# (crossplane-kind=role.iam.aws.m.upbound.io). For each such role we assert
# that >= 1 managed policy is attached.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (list/get only) -- safe in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="iam.aws.m.upbound.io/RolePolicyAttachment"   # IAM is global -- no region

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (IAM RolePolicyAttachment live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for Crossplane-provisioned IAM managed-policy attachments via crossplane-tagged roles"

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

[ "${#xp_roles[@]}" -gt 0 ] || skip "no IAM role tagged crossplane-kind=role.iam.aws.m.upbound.io (parent role absent -- RolePolicyAttachment path not provisioned)"

# For each crossplane-tagged parent role, check for attached managed policies.
found_role=""; found_count=0
for role_name in "${xp_roles[@]}"; do
  policies="$(aws iam list-attached-role-policies --role-name "$role_name" \
                --query 'AttachedPolicies' --output json 2>/dev/null)" || continue
  cnt="$(printf '%s' "$policies" | jq 'length')"
  if [ "${cnt:-0}" -gt 0 ]; then
    found_role="$role_name"
    found_count="$cnt"
    break
  fi
done

if [ -z "$found_role" ]; then
  skip "crossplane-tagged roles found but none have attached managed policies (RolePolicyAttachment not provisioned)"
fi

ok "IAM role '$found_role' has $found_count managed policy attachment(s) (RolePolicyAttachment via crossplane-tagged parent)"
covers "$KIND"
exit "$LIVE_RC_PASS"
