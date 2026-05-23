#!/usr/bin/env bash
# Assert that terraform/management/eks.tf explicitly sets every
# "trip-wire" attribute on the EKS module — settings whose default
# changed in a major version and which silently broke us when missing
# (bug #1 from 2026-05-23 phase-1 bring-up: in v20 the default of
# enable_cluster_creator_admin_permissions flipped from true to false,
# producing an opaque "server has asked for credentials" 10 minutes into
# the first apply).
#
# The rule: anything load-bearing that has a sensible-but-changed default
# upstream must be explicit in our code, so reviewers (and this test) see
# what we depend on.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

EKS_TF="$HERE/../../terraform/management/eks.tf"
[ -f "$EKS_TF" ] || { echo "missing $EKS_TF"; exit 2; }

# attribute|required-value-regex
declare -a TRIPWIRES=(
  "enable_cluster_creator_admin_permissions|true"
  "enable_irsa|true"
  "cluster_endpoint_public_access|true"
)

for row in "${TRIPWIRES[@]}"; do
  attr="${row%%|*}"
  want="${row##*|}"
  # Match the assignment regardless of whitespace.
  if grep -qE "^[[:space:]]*${attr}[[:space:]]*=[[:space:]]*${want}([[:space:]]|$)" "$EKS_TF"; then
    pass "eks.tf sets $attr = $want explicitly"
  else
    fail "eks.tf must explicitly set $attr = $want" \
         "this attribute's upstream default has changed or is risky; pin it."
  fi
done

summary
