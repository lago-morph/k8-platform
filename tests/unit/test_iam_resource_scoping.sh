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
# over-narrow that would silently break the next bring-up — non-derivable ARNs).
for sid in EKS EC2Networking ACM RDS; do
  res="$(resource_for_sid "$sid")"
  assert_eq "$sid Resource stays \"*\" (non-derivable; narrowing it is a separate, validated change)" "true" \
    "$(printf '%s' "$res" | grep -Eq 'Resource[[:space:]]*=[[:space:]]*"\*"' && echo true || echo false)"
done

# Sanity: the two narrowed statements actually exist (the split happened).
assert_eq "IAMRoles statement present" "true"          "$([ -n "$ROLE_RES" ] && echo true || echo false)"
assert_eq "IAMOIDCProviders statement present" "true"  "$([ -n "$OIDC_RES" ] && echo true || echo false)"

assert_summary
