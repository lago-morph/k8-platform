#!/usr/bin/env bash
# OI-2026-06-07-3 — shared-VPC subnets must be tagged
# kubernetes.io/cluster/<name>=shared for EVERY EKS cluster the VPC hosts,
# not just the management cluster. Without the tag, a hosted cluster's
# in-tree AWS cloud provider EXCLUDES the subnets (they "belong" to another
# cluster) and ELB/NLB provisioning fails with "could not find any suitable
# subnets" (auto-012/auto-016 live fix; durable form = terraform/base).
#
# Bug classes defended:
#   - the per-hosted-cluster tag merge dropped from either subnet resource
#   - a committed XPlatformCluster whose spec.name is missing from the
#     hosted_cluster_names default (the tag would silently not exist on a
#     fresh account and the NLB gap recurs)
set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

VPC=terraform/base/vpc.tf
VARS=terraform/base/variables.tf
for f in "$VPC" "$VARS"; do
  [ -f "$f" ] || { _fail "file_exists:$f" "$f not found"; assert_summary; }
done
_pass "files_exist"

# ── 1. the variable exists ──────────────────────────────────────────────────
grep -qE 'variable "hosted_cluster_names"' "$VARS" \
  && _pass "hosted_cluster_names_variable_declared" \
  || _fail "hosted_cluster_names_variable_declared" "terraform/base/variables.tf must declare hosted_cluster_names"

# ── 2. both subnet resources merge the per-cluster tag map ─────────────────
# Count the for-expression occurrences; one per subnet resource (public +
# private).
MERGES=$(grep -cE 'for c in var\.hosted_cluster_names : "kubernetes\.io/cluster/\$\{c\}" => "shared"' "$VPC")
assert_eq "subnet_tag_merge_on_both_subnet_resources" "2" "$MERGES"

# the management-cluster tag is still present on both
MGMT=$(grep -cE '"kubernetes\.io/cluster/\$\{local\.name_prefix\}-mgmt" *= *"shared"' "$VPC")
assert_eq "mgmt_cluster_tag_still_present" "2" "$MGMT"

# ── 3. every committed XPlatformCluster spec.name is in the default ────────
# The default list must cover every hosted cluster committed under clusters/
# — otherwise a fresh-account bring-up provisions that cluster into untagged
# subnets and the NLB gap recurs.
DEFAULT_BLOCK=$(awk '/variable "hosted_cluster_names"/,/^}/' "$VARS")
shopt -s globstar nullglob
found_any=0
for xr in clusters/**/*.yaml; do
  kind=$(yq -r '.kind // ""' "$xr" 2>/dev/null) || continue
  [ "$kind" = "XPlatformCluster" ] || continue
  found_any=1
  cname=$(yq -r '.spec.name' "$xr")
  if echo "$DEFAULT_BLOCK" | grep -q "\"$cname\""; then
    _pass "hosted_cluster_default_covers:$cname"
  else
    _fail "hosted_cluster_default_covers:$cname" \
      "XPlatformCluster $xr (spec.name=$cname) missing from hosted_cluster_names default"
  fi
done
shopt -u globstar nullglob
[ "$found_any" -eq 1 ] \
  && _pass "xplatformcluster_xrs_discovered" \
  || _fail "xplatformcluster_xrs_discovered" "no XPlatformCluster XRs found under clusters/ — glob broken?"

assert_summary
