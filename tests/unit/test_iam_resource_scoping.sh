#!/usr/bin/env bash
# auto-015-001 (OI-2026-06-08-1) — Sid-anchored SOURCE regression guard for the
# Crossplane provider IAM Resource scoping in terraform/management/irsa.tf.
#
# This is a LINT (a static source invariant on the file a human edits), not a
# behavioral proof — the firing proof is the live simulate-principal-policy deny
# check (tests/live/checks/negative/iam-resource-scope-denied.sh) + the spoke
# CREATE-path validation. Its job: catch a future human edit that (1) silently
# RE-WIDENS the narrowed role/OIDC statements back to "*", OR (2) prematurely
# OVER-NARROWS EKS/EC2/RDS/ACM (which are deliberately "*" — non-derivable ARNs).
#
# It is Sid-ANCHORED (per the harness-architect reviewer): test_iam_required_actions.sh
# flattens all statements and never reads Resource, so it cannot do this. We extract
# each statement's Resource by its Sid so we never false-match Route53/SecretsManager.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
# shellcheck disable=SC1091
. tests/lib/assert.sh

TF="terraform/management/irsa.tf"

# resource_for_sid <Sid> — print the `Resource = ...` line belonging to that Sid
# block (the first Resource line at/after the Sid line, before any other Sid).
resource_for_sid() {
  awk -v want="$1" '
    /Sid[[:space:]]*=[[:space:]]*"/ { if (match($0,/"[^"]+"/)) cur=substr($0,RSTART+1,RLENGTH-2) }
    /Resource[[:space:]]*=/ { if (cur==want) { print; exit } }
  ' "$TF"
}

# block_for_sid <Sid> — print every line of that Sid's statement block (from the
# Sid line until the next Sid line). Used to assert Condition-key narrowing,
# which resource_for_sid (Resource line only) cannot see — auto-016-001.
block_for_sid() {
  awk -v want="$1" '
    /Sid[[:space:]]*=[[:space:]]*"/ {
      if (match($0,/"[^"]+"/)) {
        cur=substr($0,RSTART+1,RLENGTH-2)
        if (cur==want) { grab=1; print; next } else { grab=0 }
      }
    }
    grab==1 { print }
  ' "$TF"
}

echo "── irsa.tf IAM Resource scoping (Sid-anchored) ──────────────"

ROLE_RES="$(resource_for_sid IAMRoles)"
OIDC_RES="$(resource_for_sid IAMOIDCProviders)"

# (1) the narrowed statements must stay prefix-scoped (catches a silent re-widen).
assert_contains "IAMRoles scoped to role/k8-platform-*" 'role/k8-platform-*' "$ROLE_RES"
assert_eq "IAMRoles is NOT a bare wildcard" "false" \
  "$(printf '%s' "$ROLE_RES" | grep -Eq 'Resource[[:space:]]*=[[:space:]]*"\*"' && echo true || echo false)"
assert_contains "IAMOIDCProviders scoped to oidc-provider/*" 'oidc-provider/*' "$OIDC_RES"
assert_eq "IAMOIDCProviders is NOT a bare wildcard" "false" \
  "$(printf '%s' "$OIDC_RES" | grep -Eq 'Resource[[:space:]]*=[[:space:]]*"\*"' && echo true || echo false)"

# (2) the deliberately-broad statements must STAY "*" (catches a premature
# over-narrow that would silently break the next bring-up). EKS/ACM are opaque
# ARNs; EC2Networking is still "*" until the EC2 narrowing lands; RDSDescribe is
# list-shaped (no resource-level ARN) so it is INTENTIONALLY "*".
for sid in EKS EC2Networking ACM RDSDescribe; do
  res="$(resource_for_sid "$sid")"
  assert_eq "$sid Resource stays \"*\" (non-derivable/list-shaped; intentional wildcard)" "true" \
    "$(printf '%s' "$res" | grep -Eq 'Resource[[:space:]]*=[[:space:]]*"\*"' && echo true || echo false)"
done

# (2b) auto-016-001 — the narrowed RDS write/modify statements must NOT be bare
# wildcards, must be ARN-type-scoped to db:*/subgrp:*, and the destructive
# instance ops must carry the rds:db-tag/ManagedBy=crossplane condition.
RDSWRITE_RES="$(resource_for_sid RDSWrite)"
RDSMOD_BLOCK="$(block_for_sid RDSModifyInstance)"
RDSMOD_RES="$(resource_for_sid RDSModifyInstance)"
assert_eq "RDSWrite is NOT a bare wildcard" "false" \
  "$(printf '%s' "$RDSWRITE_RES" | grep -Eq 'Resource[[:space:]]*=[[:space:]]*"\*"' && echo true || echo false)"
assert_contains "RDSWrite scoped to rds db ARN" ':db:*' "$(block_for_sid RDSWrite)"
assert_contains "RDSWrite scoped to rds subgrp ARN" ':subgrp:*' "$(block_for_sid RDSWrite)"
assert_eq "RDSModifyInstance is NOT a bare wildcard" "false" \
  "$(printf '%s' "$RDSMOD_RES" | grep -Eq 'Resource[[:space:]]*=[[:space:]]*"\*"' && echo true || echo false)"
assert_contains "RDSModifyInstance scoped to rds db ARN" ':db:*' "$RDSMOD_RES"
assert_contains "RDSModifyInstance carries the db-tag ManagedBy condition" \
  'rds:db-tag/ManagedBy' "$RDSMOD_BLOCK"
assert_eq "RDSWrite statement present" "true" "$([ -n "$RDSWRITE_RES" ] && echo true || echo false)"
assert_eq "RDSModifyInstance statement present" "true" "$([ -n "$RDSMOD_RES" ] && echo true || echo false)"

# Sanity: the two narrowed statements actually exist (the split happened).
assert_eq "IAMRoles statement present" "true"          "$([ -n "$ROLE_RES" ] && echo true || echo false)"
assert_eq "IAMOIDCProviders statement present" "true"  "$([ -n "$OIDC_RES" ] && echo true || echo false)"

assert_summary
