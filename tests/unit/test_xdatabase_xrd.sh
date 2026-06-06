#!/usr/bin/env bash
# Unit tests for crossplane/xrds/xdatabase.yaml (phase 5, REQ-AUTH DB).
#
# Bug class defended: XRD schema drift on the platform's database
# abstraction. A wrong apiVersion silently reintroduces a v1 claim CRD; a
# missing `scope: Namespaced` makes user-applied XDatabase namespaces a
# no-op; a stray `connectionSecretKeys` is ACCEPTED by the v2 CRD schema
# but REJECTED by the v2 admission webhook (ADR-0001 / AGENTS §6.8) — a
# kubeconform-invisible bug; an `x-kubernetes-preserve-unknown-fields: true`
# turns the strict schema into a silent passthrough; wrong enum/default/
# pattern/required values let an invalid claim through or block a valid one.
#
# v2 contract: apiextensions.crossplane.io/v2 + spec.scope: Namespaced +
# no claimNames + no connectionSecretKeys (the XDatabase Composition writes
# its connection Secret via the MR's writeConnectionSecretToRef, NOT via
# the XRD-level connection-secret machinery removed in v2).
#
# Uses mikefarah yq v4 (the repo's only supported yq; see versions.env).

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

XRD=crossplane/xrds/xdatabase.yaml

if [ ! -f "$XRD" ]; then
  _fail "xrd_file_exists" "$XRD not found"
  assert_summary
fi
_pass "xrd_file_exists"

# Schema path to the v1alpha1 version's spec/status property trees.
V='.spec.versions[] | select(.name == "v1alpha1") | .schema.openAPIV3Schema'
SPEC="${V}.properties.spec"
STATUS="${V}.properties.status"

# ---- 1. Structural basics (v2 XRD shape) ---------------------------------
assert_eq "xrd_apiVersion" "apiextensions.crossplane.io/v2" "$(yq -r '.apiVersion' "$XRD")"
assert_eq "xrd_kind"       "CompositeResourceDefinition"    "$(yq -r '.kind'       "$XRD")"
assert_eq "xrd_group"      "platform.k8-platform.io"        "$(yq -r '.spec.group' "$XRD")"
assert_eq "xrd_scope_Namespaced" "Namespaced" "$(yq -r '.spec.scope' "$XRD")"
assert_eq "xrd_names_kind" "XDatabase" "$(yq -r '.spec.names.kind' "$XRD")"

# ---- 2. defaultCompositionRef binds the RDS Composition ------------------
# The Composition's metadata.name STAYS xdatabase-rds (only the FILE is
# named xdatabase.yaml). The XRD must reference that name or claims render
# with no Composition.
assert_eq "xrd_default_composition_ref" "xdatabase-rds" \
  "$(yq -r '.spec.defaultCompositionRef.name' "$XRD")"

# ---- 3. NO v1 claimNames + NO v2-rejected connectionSecretKeys -----------
# claimNames: a v1 leftover (a reverted v1 XRD shape) — structural absence.
assert_eq "xrd_no_claimNames" "null" "$(yq -r '.spec.claimNames' "$XRD")"
# connectionSecretKeys: the v2 CRD schema ACCEPTS this field (back-compat)
# but the v2 admission webhook REJECTS it ("XR connection secrets aren't
# supported in apiextensions.crossplane.io/v2", ADR-0001). kubeconform
# cannot catch it; this static guard can.
assert_eq "xrd_no_connectionSecretKeys" "null" "$(yq -r '.spec.connectionSecretKeys' "$XRD")"

# ---- 4. Strict schema (no preserve-unknown-fields anywhere) --------------
# A `true` value anywhere turns the schema into a silent passthrough,
# defeating the "new field requires an XRD edit" contract. Scan the whole
# document for the field set to true.
PRESERVE=$(yq -r '.. | select(has("x-kubernetes-preserve-unknown-fields")) | .["x-kubernetes-preserve-unknown-fields"]' "$XRD" 2>/dev/null | grep -c '^true$' || true)
if [ "$PRESERVE" -eq 0 ]; then
  _pass "xrd_no_preserve_unknown_fields_true"
else
  _fail "xrd_no_preserve_unknown_fields_true" \
    "found x-kubernetes-preserve-unknown-fields: true (${PRESERVE} occurrence(s)) — schema is not strict"
fi

# ---- 5. engine enum [postgres] default postgres --------------------------
assert_eq "xrd_engine_default" "postgres" "$(yq -r "${SPEC}.properties.engine.default" "$XRD")"
ENGINE_ENUM=$(yq -r "${SPEC}.properties.engine.enum | join(\",\")" "$XRD")
assert_eq "xrd_engine_enum_postgres_only" "postgres" "$ENGINE_ENUM"

# ---- 6. size enum [small,medium] default small ---------------------------
assert_eq "xrd_size_default" "small" "$(yq -r "${SPEC}.properties.size.default" "$XRD")"
SIZE_ENUM=$(yq -r "${SPEC}.properties.size.enum | join(\",\")" "$XRD")
assert_eq "xrd_size_enum_small_medium" "small,medium" "$SIZE_ENUM"

# ---- 7. storageGB default 20 min 20 max 100 ------------------------------
assert_eq "xrd_storageGB_default" "20"  "$(yq -r "${SPEC}.properties.storageGB.default" "$XRD")"
assert_eq "xrd_storageGB_minimum" "20"  "$(yq -r "${SPEC}.properties.storageGB.minimum" "$XRD")"
assert_eq "xrd_storageGB_maximum" "100" "$(yq -r "${SPEC}.properties.storageGB.maximum" "$XRD")"

# ---- 8. region pattern + default us-east-1 -------------------------------
assert_eq "xrd_region_default" "us-east-1" "$(yq -r "${SPEC}.properties.region.default" "$XRD")"
REGION_PATTERN=$(yq -r "${SPEC}.properties.region.pattern" "$XRD")
if [ -n "$REGION_PATTERN" ] && [ "$REGION_PATTERN" != "null" ]; then
  _pass "xrd_region_has_pattern"
else
  _fail "xrd_region_has_pattern" "spec.region has no pattern"
fi

# ---- 9. databaseName required + has a pattern ----------------------------
REQ=$(yq -r "${SPEC}.required | join(\",\")" "$XRD")
assert_contains "xrd_databaseName_required" "databaseName" "$REQ"
DBNAME_PATTERN=$(yq -r "${SPEC}.properties.databaseName.pattern" "$XRD")
if [ -n "$DBNAME_PATTERN" ] && [ "$DBNAME_PATTERN" != "null" ]; then
  _pass "xrd_databaseName_has_pattern"
else
  _fail "xrd_databaseName_has_pattern" "spec.databaseName has no pattern"
fi

# ---- 10. status surfaces endpoint/port/secretRef.{name,namespace}/ready --
for f in endpoint port ready; do
  t=$(yq -r "${STATUS}.properties.${f}.type" "$XRD")
  if [ -n "$t" ] && [ "$t" != "null" ]; then
    _pass "xrd_status_${f}_present"
  else
    _fail "xrd_status_${f}_present" "status.${f} missing"
  fi
done
for f in name namespace; do
  t=$(yq -r "${STATUS}.properties.secretRef.properties.${f}.type" "$XRD")
  if [ -n "$t" ] && [ "$t" != "null" ]; then
    _pass "xrd_status_secretRef_${f}_present"
  else
    _fail "xrd_status_secretRef_${f}_present" "status.secretRef.${f} missing"
  fi
done

assert_summary
