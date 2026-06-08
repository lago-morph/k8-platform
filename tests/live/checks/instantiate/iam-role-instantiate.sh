#!/usr/bin/env bash
# LIVE behavioral check (instantiate tier) — CREATE a real IAM Role through the
# Crossplane controller, prove it converged + the real AWS role exists, then
# ALWAYS delete it (FINAL-PLAN §P4; ADR-0006).
#
# iam.aws.m.upbound.io/Role is ONE of the two reviewer-approved hermetic
# standalone roots (planning/test-overhaul/decisions/
# auto-014-001-cost-tier-assignments.md): a Role needs only a trust policy — no
# foreign key to a singleton — so it can be created and torn down in isolation.
# (RolePolicy / RolePolicyAttachment are singleton-coupled and are NOT
# instantiated here.)
#
# Drives the REAL controller under its scoped IRSA — NOT an admin-AWS write. The
# role's external-name is k8-platform-live-verify-<RUN_ID> so the controller's
# iam:CreateRole (scoped to role/k8-platform-* after the OI-1 narrowing;
# terraform/management/irsa.tf) succeeds rather than failing closed.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full, other=fail. Create-path => runs ONLY in LIVE_MODE=mutating;
# readonly SKIPs without applying anything.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/instantiate-lib.sh"

KIND="iam.aws.m.upbound.io/Role"          # IAM is global — no region needed
ROLE_EXTERNAL_NAME="k8-platform-live-verify-${RUN_ID:?RUN_ID must be set}"
# The kubectl object name (the MR metadata.name) is run-scoped + DNS-1123 safe.
MR_NAME="live-verify-role-${RUN_ID}"
MR_KIND="role.iam.aws.m.upbound.io"

# render_role <run_id> <epoch> — print the namespaced IAM Role MR manifest.
# Carries BOTH reaper tags (live-verify + live-verify-created) and a minimal,
# inert trust policy (a self-account principal that grants no usable access —
# this role is created to be verified+deleted, never assumed).
render_role() {
  local run_id="$1" epoch="$2"
  cat <<YAML
apiVersion: iam.aws.m.upbound.io/v1beta1
kind: Role
metadata:
  name: ${MR_NAME}
  annotations:
    crossplane.io/external-name: ${ROLE_EXTERNAL_NAME}
  labels:
    test.k8-platform/live-verify: "true"
spec:
  forProvider:
    assumeRolePolicy: |
      {
        "Version": "2012-10-17",
        "Statement": [{
          "Effect": "Deny",
          "Principal": {"Service": "ec2.amazonaws.com"},
          "Action": "sts:AssumeRole"
        }]
      }
    tags:
      ManagedBy: crossplane
      PlatformAbstraction: LiveVerify
      ${IV_TAG_RUNID_KEY}: "${run_id}"
      ${IV_TAG_CREATED_KEY}: "${epoch}"
  managementPolicies: [Observe, Create, Update, Delete]
  providerConfigRef:
    kind: ClusterProviderConfig
    name: default
YAML
}

# verify_role <run_id> — prove the REAL IAM role this run created exists and is
# crossplane-provisioned. REUSES the after-tier oracle's selection logic
# (tests/live/checks/after/iam-role-live.sh): pick the role by its tags, require
# the Composition/provider crossplane-kind tag AND this run's live-verify tag.
# Read-only (list/get) — no role is mutated here.
verify_role() {
  local run_id="$1"
  for bin in aws jq; do
    command -v "$bin" >/dev/null 2>&1 || { ng "$bin not on PATH (cannot verify the created IAM role)"; return 1; }
  done
  aws sts get-caller-identity >/dev/null 2>&1 || { ng "no usable AWS credentials to verify the created IAM role"; return 1; }

  # The external-name IS the AWS RoleName, so fetch its tags directly.
  local tags
  tags="$(aws iam list-role-tags --role-name "$ROLE_EXTERNAL_NAME" \
            --query 'Tags' --output json 2>/dev/null)" \
    || { ng "created role $ROLE_EXTERNAL_NAME not found via iam:ListRoleTags"; return 1; }

  # Same selector shape as the after-tier check: crossplane-kind must mark it as
  # the provider's Role, AND it must carry THIS run's live-verify tag (so a
  # leftover/other role can never satisfy this run's verify).
  local verdict
  verdict="$(printf '%s' "$tags" | jq -r --arg rid "$run_id" '
    (map({(.Key): .Value}) | add // {}) as $t
    | if ($t["crossplane-kind"] == "role.iam.aws.m.upbound.io")
         and ($t["live-verify"] == $rid)
      then "yes" else "no" end')"
  if [ "$verdict" != "yes" ]; then
    ng "role $ROLE_EXTERNAL_NAME exists but is not tagged crossplane-kind=role.iam.aws.m.upbound.io + live-verify=$run_id"
    return 1
  fi
  ok "real IAM role '$ROLE_EXTERNAL_NAME' exists, crossplane-provisioned, tagged live-verify=$run_id"
  return 0
}

instantiate_and_verify "$KIND" render_role verify_role "$MR_KIND" "$MR_NAME"
