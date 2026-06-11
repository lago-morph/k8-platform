#!/usr/bin/env bash
# Unit tests for crossplane/compositions/xdatabase.yaml (phase 5).
#
# The Composition's metadata.name is `xdatabase-rds` (the XRD's
# defaultCompositionRef.name); only the FILE is named xdatabase.yaml so it
# matches the render-fixtures dir convention crossplane/xrds/xdatabase/.
#
# Bug class defended:
#   - size→instanceClass map NOT total over the XRD size enum (a `size`
#     value with no map entry renders the base default silently, picking
#     the wrong instance class) — set-equality assertion.
#   - an instanceClass outside the AWS-account whitelist (db.t4g.micro /
#     db.t4g.small) — anything t3.medium+ or an m/c/r family violates the
#     account constraints (ai/testing-guidelines §1) and costs real money.
#   - publiclyAccessible accidentally true (DB exposed to the internet).
#   - skipFinalSnapshot not boolean true (delete blocks on a final
#     snapshot the account constraints forbid).
#   - passwordSecretRef carrying a `namespace` field (the v2 CRD's ref is
#     {name,key} only; a namespace makes the ref unresolvable).
#   - connection-secret name NOT patched to the XR name (Keycloak's
#     existingSecret: keycloak-db would point at a Secret that never exists).
#   - region not patched from spec.region (the base us-east-1 literal can't
#     be overridden per-claim).
#   - status patches written the WRONG direction (FromCompositeFieldPath to
#     a status.* toFieldPath writes the composed Instance's status, never
#     reaching the XR — status.endpoint/port/secretRef stay empty).
#   - a 12-digit AWS account-id literal anywhere (AGENTS §8.1 ephemeral).
#   - XRD↔Composition drift (kind / defaultCompositionRef mismatch).
#
# Uses mikefarah yq v4.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

COMP=crossplane/compositions/xdatabase.yaml
XRD=crossplane/xrds/xdatabase.yaml

if [ ! -f "$COMP" ]; then
  _fail "composition_file_exists" "$COMP not found"
  assert_summary
fi
_pass "composition_file_exists"

# Select the patch-and-transform step input by functionRef name (robust to
# pipeline-step ordering). The single RDS Instance base:
PT='.spec.pipeline[] | select(.functionRef.name == "function-patch-and-transform") | .input'
INST="${PT}.resources[] | select(.name == \"rds-instance\")"

# ---- 1. v2 Pipeline mode + function-patch-and-transform ref --------------
assert_eq "composition_mode_pipeline" "Pipeline" "$(yq -r '.spec.mode' "$COMP")"
FN_REF=$(yq -r '.spec.pipeline[] | select(.functionRef.name == "function-patch-and-transform") | .functionRef.name' "$COMP")
assert_eq "composition_function_ref" "function-patch-and-transform" "$FN_REF"

# ---- 2. compositeTypeRef: XDatabase @ <group>/v1alpha1 -------------------
assert_eq "composition_typeRef_kind" "XDatabase" "$(yq -r '.spec.compositeTypeRef.kind' "$COMP")"
assert_eq "composition_typeRef_apiVersion" "platform.k8-platform.io/v1alpha1" \
  "$(yq -r '.spec.compositeTypeRef.apiVersion' "$COMP")"

# ---- 3. Four resources: networking trio + the Instance -------------------
# (db-subnet-group + db-security-group + db-ingress-5432 place the DB in
# the base VPC — the default-VPC unreachability fix, 2026-06-11.)
RES_COUNT=$(yq -r "${PT}.resources | length" "$COMP")
assert_eq "composition_resource_count" "4" "$RES_COUNT"
assert_eq "composition_subnet_group_kind" "SubnetGroup" \
  "$(yq -r "${PT}.resources[] | select(.name==\"db-subnet-group\") | .base.kind" "$COMP")"
assert_eq "composition_subnet_group_subnets_required" "Required" \
  "$(yq -r "${PT}.resources[] | select(.name==\"db-subnet-group\") | .patches[] | select(.toFieldPath==\"spec.forProvider.subnetIds\") | .policy.fromFieldPath" "$COMP")"
assert_eq "composition_sg_vpc_required" "Required" \
  "$(yq -r "${PT}.resources[] | select(.name==\"db-security-group\") | .patches[] | select(.toFieldPath==\"spec.forProvider.vpcId\") | .policy.fromFieldPath" "$COMP")"
# classic SecurityGroupRule (v2.5.0 cannot observe SecurityGroupIngressRule)
assert_eq "composition_ingress_rule_kind" "SecurityGroupRule" \
  "$(yq -r "${PT}.resources[] | select(.name==\"db-ingress-5432\") | .base.kind" "$COMP")"
assert_eq "composition_ingress_port" "5432" \
  "$(yq -r "${PT}.resources[] | select(.name==\"db-ingress-5432\") | .base.spec.forProvider.fromPort" "$COMP")"
# the Instance is pinned into the composed subnet group + SG (both Required
# — never created in the default VPC)
assert_eq "composition_instance_subnet_group_required" "Required" \
  "$(yq -r "${INST} | .patches[] | select(.toFieldPath==\"spec.forProvider.dbSubnetGroupName\") | .policy.fromFieldPath" "$COMP")"
assert_eq "composition_instance_sg_required" "Required" \
  "$(yq -r "${INST} | .patches[] | select(.toFieldPath==\"spec.forProvider.vpcSecurityGroupIds[0]\") | .policy.fromFieldPath" "$COMP")"
assert_eq "composition_instance_api" "rds.aws.m.upbound.io/v1beta1" \
  "$(yq -r "${INST} | .base.apiVersion" "$COMP")"
assert_eq "composition_instance_kind" "Instance" \
  "$(yq -r "${INST} | .base.kind" "$COMP")"

# ---- 4. managementPolicies + providerConfigRef ---------------------------
MGMT=$(yq -r "${INST} | .base.spec.managementPolicies | join(\",\")" "$COMP")
if [ -n "$MGMT" ] && [ "$MGMT" != "null" ]; then
  _pass "composition_managementPolicies_present (${MGMT})"
else
  _fail "composition_managementPolicies_present" "no managementPolicies on the Instance base"
fi
assert_eq "composition_providerConfigRef_kind" "ClusterProviderConfig" \
  "$(yq -r "${INST} | .base.spec.providerConfigRef.kind" "$COMP")"
PCR_NAME=$(yq -r "${INST} | .base.spec.providerConfigRef.name" "$COMP")
if [ -n "$PCR_NAME" ] && [ "$PCR_NAME" != "null" ]; then
  _pass "composition_providerConfigRef_name_present (${PCR_NAME})"
else
  _fail "composition_providerConfigRef_name_present" "no providerConfigRef.name"
fi

# ---- 5. size→instanceClass map is TOTAL over the XRD size enum -----------
# The map transform on the size→instanceClass patch must have EXACTLY the
# keys the XRD's size enum declares — no missing key (silent base default),
# no extra key (dead mapping that masks a typo). Set-equality.
MAP_KEYS=$(yq -r "${INST} | .patches[] | select(.toFieldPath == \"spec.forProvider.instanceClass\") | .transforms[] | select(.type == \"map\") | .map | keys | .[]" "$COMP" | sort | tr '\n' ',')
ENUM_KEYS=$(yq -r '.spec.versions[] | select(.name == "v1alpha1") | .schema.openAPIV3Schema.properties.spec.properties.size.enum | .[]' "$XRD" | sort | tr '\n' ',')
assert_eq "composition_size_map_total_over_enum" "$ENUM_KEYS" "$MAP_KEYS"

# ---- 6. Every instanceClass value is in the whitelist --------------------
# Whitelist = {db.t4g.micro, db.t4g.small}. Collect both the base default
# AND every map value; assert each is whitelisted AND assert NO t3.medium+
# / m|c|r family leaked in.
BASE_CLASS=$(yq -r "${INST} | .base.spec.forProvider.instanceClass" "$COMP")
MAP_VALUES=$(yq -r "${INST} | .patches[] | select(.toFieldPath == \"spec.forProvider.instanceClass\") | .transforms[] | select(.type == \"map\") | .map | to_entries | .[] | .value" "$COMP")
ALL_CLASSES=$(printf '%s\n%s\n' "$BASE_CLASS" "$MAP_VALUES" | grep -v '^$' | sort -u)

bad_class=0
while IFS= read -r c; do
  [ -z "$c" ] && continue
  case "$c" in
    db.t4g.micro|db.t4g.small) ;;
    *) _fail "composition_instanceClass_whitelisted" "non-whitelisted instanceClass: $c"; bad_class=1 ;;
  esac
done <<< "$ALL_CLASSES"
[ "$bad_class" -eq 0 ] && _pass "composition_instanceClass_whitelisted"

# Explicit negative: no forbidden family/size anywhere in the file.
if grep -qE 'db\.t3\.|db\.(m|c|r)[0-9]' "$COMP"; then
  _fail "composition_no_forbidden_instance_family" "found a t3 / m|c|r-family instance class"
else
  _pass "composition_no_forbidden_instance_family"
fi

# ---- 7. engine postgres / publiclyAccessible false -----------------------
assert_eq "composition_engine_postgres" "postgres" \
  "$(yq -r "${INST} | .base.spec.forProvider.engine" "$COMP")"
assert_eq "composition_publiclyAccessible_false" "false" \
  "$(yq -r "${INST} | .base.spec.forProvider.publiclyAccessible" "$COMP")"

# ---- 8. skipFinalSnapshot == true (boolean) / applyImmediately true ------
# yq -o=json prints booleans unquoted; assert the literal boolean true, not
# the string "true".
SKIP_JSON=$(yq -o=json "${INST} | .base.spec.forProvider.skipFinalSnapshot" "$COMP")
assert_eq "composition_skipFinalSnapshot_bool_true" "true" "$SKIP_JSON"
APPLY_JSON=$(yq -o=json "${INST} | .base.spec.forProvider.applyImmediately" "$COMP")
assert_eq "composition_applyImmediately_true" "true" "$APPLY_JSON"

# ---- 9. autoGeneratePassword true ----------------------------------------
AGP_JSON=$(yq -o=json "${INST} | .base.spec.forProvider.autoGeneratePassword" "$COMP")
assert_eq "composition_autoGeneratePassword_true" "true" "$AGP_JSON"

# ---- 10. passwordSecretRef keys EXACTLY [name,key] (reject namespace) ----
PWREF_KEYS=$(yq -r "${INST} | .base.spec.forProvider.passwordSecretRef | keys | sort | join(\",\")" "$COMP")
assert_eq "composition_passwordSecretRef_keys_exact" "key,name" "$PWREF_KEYS"

# ---- 11. writeConnectionSecretToRef.name patched FromComposite metadata.name
WCS_PATCH=$(yq -r "${INST} | .patches[] | select(.toFieldPath == \"spec.writeConnectionSecretToRef.name\") | .type + \"|\" + .fromFieldPath" "$COMP")
assert_eq "composition_connection_secret_name_patched" "FromCompositeFieldPath|metadata.name" "$WCS_PATCH"

# ---- 12. region patch fromFieldPath spec.region → spec.forProvider.region
REGION_PATCH=$(yq -r "${INST} | .patches[] | select(.toFieldPath == \"spec.forProvider.region\") | .type + \"|\" + .fromFieldPath" "$COMP")
assert_eq "composition_region_patched_from_spec" "FromCompositeFieldPath|spec.region" "$REGION_PATCH"

# ---- 13. status patches are ToCompositeFieldPath -------------------------
for sp in status.endpoint status.port status.secretRef.name status.secretRef.namespace; do
  ptype=$(yq -r "${INST} | .patches[] | select(.toFieldPath == \"${sp}\") | .type" "$COMP")
  assert_eq "composition_${sp//./_}_is_ToComposite" "ToCompositeFieldPath" "$ptype"
done

# ---- 13b. NO FromCompositeFieldPath writes to a status.* toFieldPath -----
# A FromCompositeFieldPath whose toFieldPath starts with status. would write
# the COMPOSED Instance's status, never the XR — the classic direction bug.
BAD_STATUS_WRITE=$(yq -r "${INST} | .patches[] | select(.type == \"FromCompositeFieldPath\") | select(.toFieldPath == \"status\" or (.toFieldPath | test(\"^status\\.\"))) | .toFieldPath" "$COMP")
if [ -z "$BAD_STATUS_WRITE" ]; then
  _pass "composition_no_FromComposite_to_status"
else
  _fail "composition_no_FromComposite_to_status" \
    "FromCompositeFieldPath writes to status.*: $(printf '%s' "$BAD_STATUS_WRITE" | tr '\n' ',')"
fi

# ---- 14. XRD↔Composition sync -------------------------------------------
XRD_KIND=$(yq -r '.spec.names.kind' "$XRD")
COMP_TYPE_KIND=$(yq -r '.spec.compositeTypeRef.kind' "$COMP")
assert_eq "sync_xrd_kind_eq_compositeTypeRef_kind" "$XRD_KIND" "$COMP_TYPE_KIND"
XRD_DEFAULT_COMP=$(yq -r '.spec.defaultCompositionRef.name' "$XRD")
COMP_NAME=$(yq -r '.metadata.name' "$COMP")
assert_eq "sync_xrd_defaultCompositionRef_eq_comp_name" "$XRD_DEFAULT_COMP" "$COMP_NAME"

# ---- 15. NO 12-digit AWS account-id literal ------------------------------
if grep -qE '[0-9]{12}' "$COMP"; then
  _fail "composition_no_account_id_literal" "found a 12-digit literal (possible AWS account id, AGENTS §8.1)"
else
  _pass "composition_no_account_id_literal"
fi

assert_summary
