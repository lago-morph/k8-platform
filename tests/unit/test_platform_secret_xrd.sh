#!/usr/bin/env bash
# Unit tests for crossplane/xrds/platform-secret.yaml.
#
# Bug class defended: XRD schema drift (silent 404 on XR apply when
# version not served, type drift on refreshInterval, missing namespaced
# scope, accidental regression to v1 claim/composite split).
#
# v2 contract: apiextensions.crossplane.io/v2 + spec.scope: Namespaced
# + no spec.claimNames. The XR kind (XPlatformSecret) is the user-facing
# kind; there is no separate claim CRD.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

XRD=crossplane/xrds/platform-secret.yaml

if [ ! -f "$XRD" ]; then
  _fail "xrd_file_exists" "$XRD not found"
  assert_summary
fi
_pass "xrd_file_exists"

# ---- 1. Structural basics (v2 XRD shape) ---------------------------------
assert_eq "xrd_apiVersion" "apiextensions.crossplane.io/v2" "$(yq -r '.apiVersion' "$XRD")"
assert_eq "xrd_kind"       "CompositeResourceDefinition"    "$(yq -r '.kind'       "$XRD")"
assert_eq "xrd_group"      "platform.k8-platform.io"        "$(yq -r '.spec.group' "$XRD")"

# ---- 2. v2 namespaced scope (positive) + no v1 claimNames (regression) --
#
# Defends contract: Crossplane v2 replaces the v1 claim/composite split
# with a single namespaced XR kind. Two guards:
#
#   (a) spec.scope MUST be "Namespaced" — without it, the XRD defaults
#       to LegacyCluster scope, the namespace on user-created XRs is
#       silently ignored, and reconciliation fails opaquely.
#   (b) spec.claimNames MUST be absent — a reverted v1 XRD shape would
#       re-introduce a claim CRD. Structural absence is the only honest
#       guard against a partial revert.
SCOPE=$(yq -r '.spec.scope' "$XRD")
assert_eq "xrd_spec_scope_Namespaced" "Namespaced" "$SCOPE"

CLAIM_NAMES=$(yq -r '.spec.claimNames' "$XRD")
assert_eq "xrd_spec_claimNames_absent" "null" "$CLAIM_NAMES"

# ---- 3. Composite kind name + composite-names completeness --------------
#
# Defends contract: even in v2 the XR kind name must be set, and the
# Kubernetes API server requires plural / listKind / singular (missing
# any one silently produces a CRD with an auto-derived plural that then
# collides with another XRD).
COMPOSITE_KIND=$(yq -r '.spec.names.kind' "$XRD")
assert_eq "xrd_composite_kind"      "XPlatformSecret" "$COMPOSITE_KIND"

for f in plural listKind singular; do
  v=$(yq -r ".spec.names.$f" "$XRD")
  if [ -n "$v" ] && [ "$v" != "null" ]; then
    _pass "xrd_composite_names_${f}_present"
  else
    _fail "xrd_composite_names_${f}_present" "spec.names.$f missing"
  fi
done

# ---- 3. Version v1alpha1 is served AND referenceable ---------------------
#
# Defends contract: a version that is not served returns 404 on claim
# apply with no useful error message; one that is not referenceable
# can't be the default. Both are easy to miss in a hand-written XRD.
SERVED=$(yq -r '.spec.versions[] | select(.name == "v1alpha1") | .served' "$XRD")
REFNCBL=$(yq -r '.spec.versions[] | select(.name == "v1alpha1") | .referenceable' "$XRD")
assert_eq "xrd_v1alpha1_served"       "true" "$SERVED"
assert_eq "xrd_v1alpha1_referenceable" "true" "$REFNCBL"

# ---- 4. refreshInterval is a string with Go-duration pattern -------------
#
# Defends contract: ESO's refreshInterval is a Go duration string.
# If the XRD types it as integer, claim apply silently coerces and ESO
# defaults instead. Explicit string + regex catches the typo at
# admission time.
RI_TYPE=$(yq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.refreshInterval.type' "$XRD")
RI_PATTERN=$(yq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.refreshInterval.pattern' "$XRD")
assert_eq "xrd_refreshInterval_type" "string" "$RI_TYPE"
if [ "$RI_PATTERN" = "^[0-9]+(s|m|h)$" ]; then
  _pass "xrd_refreshInterval_pattern"
else
  _fail "xrd_refreshInterval_pattern" "got: $RI_PATTERN"
fi

# ---- 5. region is a string with AWS-region regex ------------------------
REGION_TYPE=$(yq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.region.type' "$XRD")
REGION_PATTERN=$(yq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.region.pattern' "$XRD")
assert_eq "xrd_region_type"    "string"               "$REGION_TYPE"
assert_eq "xrd_region_pattern" "^[a-z]{2}-[a-z]+-[0-9]$" "$REGION_PATTERN"

# ---- 6. defaultCompositionRef points at the AWS Composition --------------
#
# Defends contract: without defaultCompositionRef, a claim with no
# explicit compositionRef gets rejected with a confusing error. Catches
# rename drift between XRD and Composition file.
DEFAULT_COMP=$(yq -r '.spec.defaultCompositionRef.name' "$XRD")
COMP_FILE=crossplane/compositions/platform-secret.yaml
COMP_NAME=$(yq -r '.metadata.name' "$COMP_FILE" 2>/dev/null)
if [ "$DEFAULT_COMP" = "$COMP_NAME" ] && [ -n "$COMP_NAME" ]; then
  _pass "xrd_defaultCompositionRef_matches_composition"
else
  _fail "xrd_defaultCompositionRef_matches_composition" "xrd=$DEFAULT_COMP composition=$COMP_NAME"
fi

# ---- 7. Strict schema — no x-kubernetes-preserve-unknown-fields:true ----
#
# Defends contract: silent passthrough of unknown spec fields means a
# typo'd field is accepted without effect. The XRD MUST NOT enable
# preserve-unknown-fields at any level.
if grep -q 'x-kubernetes-preserve-unknown-fields: true' "$XRD"; then
  _fail "xrd_schema_strict" "found 'x-kubernetes-preserve-unknown-fields: true' — unknown fields would silently pass"
else
  _pass "xrd_schema_strict"
fi

assert_summary
