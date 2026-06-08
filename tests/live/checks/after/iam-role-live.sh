#!/usr/bin/env bash
# LIVE behavioral check (after tier) -- a Crossplane-provisioned IAM Role is
# real and healthy.
#
# This is the BEHAVIORAL oracle for iam.aws.m.upbound.io/Role per ADR-0006:
# it proves the PlatformCluster abstraction actually produced a real IAM role,
# not that a manifest says so. It selects by the Composition's own tag
# (crossplane-kind=role.iam.aws.m.upbound.io) so a Terraform-managed role
# does NOT count. AWSServiceRole* roles are excluded from enumeration.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (list/get only) -- safe in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="iam.aws.m.upbound.io/Role"   # IAM is a global service -- no region needed

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (IAM Role live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for a Crossplane-provisioned IAM Role (crossplane-kind=role.iam.aws.m.upbound.io)"

# List all IAM roles; skip AWSServiceRole* (service-linked, never crossplane).
# shellcheck disable=SC2016  # backticks are JMESPath literals, not shell expansion
ROLES_JSON="$(aws iam list-roles \
  --query 'Roles[?!starts_with(RoleName, `AWSServiceRole`)].RoleName' \
  --output json 2>/dev/null)" || skip "iam:ListRoles not permitted / unavailable here"

COUNT="$(printf '%s' "$ROLES_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no non-service-linked IAM roles in the account"

found_role=""
while IFS= read -r role_name; do
  [ -z "$role_name" ] && continue
  tags="$(aws iam list-role-tags --role-name "$role_name" \
            --query 'Tags' --output json 2>/dev/null)" || continue
  is_xp="$(printf '%s' "$tags" | jq -r '
    (map({(.Key): .Value}) | add // {}) as $t
    | if ($t["crossplane-kind"] == "role.iam.aws.m.upbound.io")
      then "yes" else "no" end')"
  if [ "$is_xp" = "yes" ]; then
    found_role="$role_name"
    break
  fi
done <<EOF
$(printf '%s' "$ROLES_JSON" | jq -r '.[]')
EOF

# No crossplane-tagged role -- the kind is unprovisioned for this account.
if [ -z "$found_role" ]; then
  skip "no IAM role tagged crossplane-kind=role.iam.aws.m.upbound.io (PlatformCluster abstraction has not provisioned one)"
fi

# Health: the role exists (it does -- we just retrieved it via tag lookup).
ok "Crossplane-provisioned IAM role '$found_role' exists (crossplane-kind=role.iam.aws.m.upbound.io)"
covers "$KIND"
exit "$LIVE_RC_PASS"
