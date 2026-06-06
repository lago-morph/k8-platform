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

# --- maxPods / prefix-delegation pod-density guards -------------------------
# The node group must allow ~110 pods, not t3.medium's default ~17. This needs
# TWO independent settings; losing either silently caps pod density and breaks
# the management stack (ingress-nginx certgen hook couldn't get an IP — see the
# eks.tf comment and AGENTS §6.26). These guard against a regression that drops
# either half.

# 1. AL2023 ami_type is what makes the module emit nodeadm user-data (vs AL2
#    bootstrap.sh, which omits maxPods and would fail boot).
if grep -qE "^[[:space:]]*ami_type[[:space:]]*=[[:space:]]*\"AL2023_x86_64_STANDARD\"" "$EKS_TF"; then
  pass "eks.tf pins ami_type = AL2023_x86_64_STANDARD (nodeadm user-data)"
else
  fail "eks.tf node group must pin ami_type = AL2023_x86_64_STANDARD" \
       "without it the module emits AL2 bootstrap.sh, which omits maxPods and fails node bootstrap."
fi

# 2. The kubelet maxPods bump itself (carried in cloudinit_pre_nodeadm NodeConfig).
if grep -qE "^[[:space:]]*maxPods:[[:space:]]*110([[:space:]]|$)" "$EKS_TF"; then
  pass "eks.tf node group sets kubelet maxPods: 110"
else
  fail "eks.tf node group must set kubelet maxPods: 110 in cloudinit_pre_nodeadm" \
       "the vpc-cni prefix-delegation addon raises the IP ceiling but kubelet still advertises ~17 without this."
fi

# 3. The prefix-delegation addon env (the IP-ceiling half) must stay present.
if grep -qE "ENABLE_PREFIX_DELEGATION" "$EKS_TF"; then
  pass "eks.tf vpc-cni addon enables prefix delegation"
else
  fail "eks.tf vpc-cni addon must set ENABLE_PREFIX_DELEGATION" \
       "maxPods: 110 without prefix delegation exhausts the single-IP-per-pod ceiling at ~17."
fi

summary
