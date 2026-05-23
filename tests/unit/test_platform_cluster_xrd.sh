#!/usr/bin/env bash
# Unit tests for crossplane/xrds/platform-cluster.yaml.
#
# Bug class defended: XRD schema drift on the second XRD — same shape
# of mistakes that bit PlatformSecret (unserved version, missing claim
# name disambiguation, x-kubernetes-preserve-unknown-fields silently
# true). Mirrors test_platform_secret_xrd.sh structurally on purpose.

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

XRD=crossplane/xrds/platform-cluster.yaml

if [ ! -f "$XRD" ]; then
  _fail "xrd_file_exists" "$XRD not found"
  assert_summary
fi
_pass "xrd_file_exists"

assert_eq "xrd_apiVersion" "apiextensions.crossplane.io/v1" "$(yq -r '.apiVersion' "$XRD")"
assert_eq "xrd_kind"       "CompositeResourceDefinition"    "$(yq -r '.kind'       "$XRD")"
assert_eq "xrd_group"      "platform.k8-platform.io"        "$(yq -r '.spec.group' "$XRD")"

COMPOSITE_KIND=$(yq -r '.spec.names.kind' "$XRD")
CLAIM_KIND=$(yq -r '.spec.claimNames.kind' "$XRD")
assert_eq "xrd_composite_kind" "XPlatformCluster" "$COMPOSITE_KIND"
assert_eq "xrd_claim_kind"     "PlatformCluster"  "$CLAIM_KIND"

for f in plural listKind singular; do
  v=$(yq -r ".spec.names.$f" "$XRD")
  [ -n "$v" ] && [ "$v" != "null" ] \
    && _pass "xrd_composite_names_${f}_present" \
    || _fail "xrd_composite_names_${f}_present" "spec.names.$f missing"
  vc=$(yq -r ".spec.claimNames.$f" "$XRD")
  [ -n "$vc" ] && [ "$vc" != "null" ] \
    && _pass "xrd_claim_names_${f}_present" \
    || _fail "xrd_claim_names_${f}_present" "spec.claimNames.$f missing"
done

SERVED=$(yq -r '.spec.versions[] | select(.name == "v1alpha1") | .served' "$XRD")
REFER=$(yq -r '.spec.versions[] | select(.name == "v1alpha1") | .referenceable' "$XRD")
assert_eq "xrd_v1alpha1_served"        "true" "$SERVED"
assert_eq "xrd_v1alpha1_referenceable" "true" "$REFER"

# defaultCompositionRef must match the Composition's metadata.name —
# missing this means a claim resolves no Composition and stays stuck.
DEFAULT_COMP=$(yq -r '.spec.defaultCompositionRef.name' "$XRD")
assert_eq "xrd_default_composition" "platform-cluster-aws" "$DEFAULT_COMP"

COMP=crossplane/compositions/platform-cluster.yaml
if [ -f "$COMP" ]; then
  COMP_NAME=$(yq -r '.metadata.name' "$COMP")
  assert_eq "xrd_default_composition_matches_composition_file" "$DEFAULT_COMP" "$COMP_NAME"
fi

# Required-fields contract: name and vpc must both be required at the
# top level. Without name, two claims collide on resource-naming
# patches; without vpc, the EKS Cluster has no place to put its ENIs
# and only fails at apply time.
REQUIRED=$(yq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.required[]' "$XRD")
echo "$REQUIRED" | grep -qx 'name' \
  && _pass "xrd_spec_name_required" \
  || _fail "xrd_spec_name_required" "spec.name not in required"
echo "$REQUIRED" | grep -qx 'vpc' \
  && _pass "xrd_spec_vpc_required" \
  || _fail "xrd_spec_vpc_required" "spec.vpc not in required"

# Subnets must require at least 2 (EKS HA requirement). Without this,
# the EKS provider returns a confusing "at least two subnets in two
# different AZs" error well after admission.
MIN_SUBNETS=$(yq -r \
  '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.vpc.properties.subnetIds.minItems' \
  "$XRD")
assert_eq "xrd_subnets_minItems_2" "2" "$MIN_SUBNETS"

# Strict schema: no x-kubernetes-preserve-unknown-fields: true anywhere.
# (per adversarial-reviewer A finding 14 — preserve-unknown-fields
# silently allows typos in claims and is the wrong default for a
# platform abstraction.)
if grep -q "x-kubernetes-preserve-unknown-fields:[[:space:]]*true" "$XRD"; then
  _fail "xrd_strict_schema" "x-kubernetes-preserve-unknown-fields: true found"
else
  _pass "xrd_strict_schema"
fi

assert_summary
