#!/usr/bin/env bash
# Unit tests for crossplane/compositions/platform-secret.yaml.
#
# Bug class defended: Composition silently renders the wrong managed
# resource shape — wrong ASM name prefix (breaks IRSA scope), wrong
# ExternalSecret namespace (lands in crossplane-system instead of
# claim ns), ClusterSecretStore name drift (ExternalSecret unable to
# fetch). Per adversarial-reviewer A.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

COMP=crossplane/compositions/platform-secret.yaml
XRD=crossplane/xrds/platform-secret.yaml
ESO_STORE=clusters/management/eso/cluster-secret-store.yaml

# ---- 1. compositeTypeRef matches the XRD ---------------------------------
COMP_TYPE_API=$(yq -r '.spec.compositeTypeRef.apiVersion' "$COMP")
COMP_TYPE_KIND=$(yq -r '.spec.compositeTypeRef.kind' "$COMP")
XRD_GROUP=$(yq -r '.spec.group' "$XRD")
XRD_VERSION=$(yq -r '.spec.versions[0].name' "$XRD")
XRD_KIND=$(yq -r '.spec.names.kind' "$XRD")

assert_eq "composition_typeRef_apiVersion" "${XRD_GROUP}/${XRD_VERSION}" "$COMP_TYPE_API"
assert_eq "composition_typeRef_kind"       "$XRD_KIND"                   "$COMP_TYPE_KIND"

# ---- 2. Exactly two resources (asm-secret + external-secret) -------------
RES_COUNT=$(yq -r '.spec.pipeline[0].input.resources | length' "$COMP")
assert_eq "composition_resource_count" "2" "$RES_COUNT"

ASM_BASE_API=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "asm-secret") | .base.apiVersion' "$COMP")
ASM_BASE_KIND=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "asm-secret") | .base.kind' "$COMP")
ES_BASE_API=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "external-secret") | .base.apiVersion' "$COMP")
ES_BASE_KIND=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "external-secret") | .base.kind' "$COMP")

# ASM secret must be the Upbound provider-family-aws Secret, not the
# crossplane-contrib equivalent — IRSA scope is for upbound.io ARN.
assert_eq "composition_asm_apiVersion" "secretsmanager.aws.upbound.io/v1beta1" "$ASM_BASE_API"
assert_eq "composition_asm_kind"       "Secret"                                 "$ASM_BASE_KIND"
assert_eq "composition_es_apiVersion"  "external-secrets.io/v1beta1"            "$ES_BASE_API"
assert_eq "composition_es_kind"        "ExternalSecret"                          "$ES_BASE_KIND"

# ---- 3. ASM secret name prefix is exactly "k8-platform/" -----------------
#
# Defends contract: the ESO IRSA policy attached in
# terraform/management/irsa.tf grants secretsmanager actions on
# arn:aws:secretsmanager:*:*:secret:k8-platform/*. If the Composition
# renders a different prefix, every claim fails with AccessDenied.
ASM_NAME_FMT=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "asm-secret") | .patches[] | select(.toFieldPath == "spec.forProvider.name") | .transforms[0].string.fmt' "$COMP")
case "$ASM_NAME_FMT" in
  "k8-platform/%s") _pass "composition_asm_name_prefix_matches_irsa" ;;
  *)                _fail "composition_asm_name_prefix_matches_irsa" "fmt='$ASM_NAME_FMT' — must be 'k8-platform/%s'" ;;
esac

# Cross-check with management module IRSA scope.
IRSA_RESOURCE=$(awk '/aws_iam_policy.*eso/,/^}/' terraform/management/irsa.tf \
  | grep -oE 'arn:aws:secretsmanager:[^"]*' | head -1)
case "$IRSA_RESOURCE" in
  *":secret:k8-platform/*")
    _pass "composition_asm_prefix_in_irsa_scope"
    ;;
  *)
    _fail "composition_asm_prefix_in_irsa_scope" "IRSA Resource='$IRSA_RESOURCE' does not end ':secret:k8-platform/*'"
    ;;
esac

# ---- 4. ASM secret recoveryWindowInDays is 0 -----------------------------
#
# Defends contract: tests and dev workflows create-delete-recreate
# claims with the same name. AWS Secrets Manager's default 7-day
# recovery window blocks re-create with "scheduled for deletion".
# Setting recoveryWindowInDays=0 disables the window.
ASM_RECOVERY=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "asm-secret") | .base.spec.forProvider.recoveryWindowInDays' "$COMP")
assert_eq "composition_asm_recovery_window_zero" "0" "$ASM_RECOVERY"

# ---- 5. ASM secret deletionPolicy is Delete (not Orphan) -----------------
ASM_DELETION=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "asm-secret") | .base.spec.deletionPolicy' "$COMP")
assert_eq "composition_asm_deletionPolicy_Delete" "Delete" "$ASM_DELETION"

# ---- 6. ExternalSecret targets claim's namespace, not composite's -------
#
# Defends contract: composites are cluster-scoped — using
# composite.metadata.namespace patches to nothing. The ExternalSecret
# must derive namespace from claimRef.namespace.
ES_NS_FROM=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "external-secret") | .patches[] | select(.toFieldPath == "metadata.namespace") | .fromFieldPath' "$COMP")
assert_eq "composition_es_namespace_from_claim" "spec.claimRef.namespace" "$ES_NS_FROM"

# ---- 7. ExternalSecret.secretStoreRef matches the ClusterSecretStore ----
#
# Defends contract: cross-file invariant. If clusters/management/eso/
# cluster-secret-store.yaml is renamed but the Composition isn't
# updated, every ExternalSecret stays Ready=False forever with a
# "no such ClusterSecretStore" message that's only visible on the ES
# itself.
ES_STORE_NAME=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "external-secret") | .base.spec.secretStoreRef.name' "$COMP")
ES_STORE_KIND=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "external-secret") | .base.spec.secretStoreRef.kind' "$COMP")
STORE_NAME=$(yq -r '.metadata.name' "$ESO_STORE")
STORE_KIND=$(yq -r '.kind' "$ESO_STORE")

assert_eq "composition_es_storeRef_name_matches_file" "$STORE_NAME" "$ES_STORE_NAME"
assert_eq "composition_es_storeRef_kind"              "$STORE_KIND" "$ES_STORE_KIND"

# ---- 8. ExternalSecret refreshInterval is patched from XR -----------------
#
# Defends contract: claim's refreshInterval must reach the
# ExternalSecret. A missing patch silently uses the base default (1h)
# regardless of what the claim says.
ES_RI_FROM=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "external-secret") | .patches[] | select(.toFieldPath == "spec.refreshInterval") | .fromFieldPath' "$COMP")
assert_eq "composition_es_refreshInterval_patched_from_xr" "spec.refreshInterval" "$ES_RI_FROM"

# ---- 9. Both resources have readinessChecks ------------------------------
#
# Defends contract: XR Ready should mean both ASM AND ES are healthy.
# A Composition that doesn't declare readinessChecks marks the resource
# Ready=True as soon as Synced, before the underlying AWS Get returns.
ASM_RC=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "asm-secret") | .readinessChecks | length' "$COMP")
ES_RC=$(yq -r '.spec.pipeline[0].input.resources[] | select(.name == "external-secret") | .readinessChecks | length' "$COMP")

if [ "$ASM_RC" -gt 0 ] 2>/dev/null; then _pass "composition_asm_has_readinessChecks"; else _fail "composition_asm_has_readinessChecks" "got $ASM_RC"; fi
if [ "$ES_RC"  -gt 0 ] 2>/dev/null; then _pass "composition_es_has_readinessChecks";  else _fail "composition_es_has_readinessChecks"  "got $ES_RC";  fi

# ---- 10. v2 Pipeline mode + function-patch-and-transform -----------------
#
# Defends contract: Crossplane v2 removed `spec.resources` from the v1
# Composition schema; only Pipeline mode is accepted. The Composition
# MUST set spec.mode=Pipeline and reference the
# function-patch-and-transform function.
COMP_MODE=$(yq -r '.spec.mode' "$COMP")
assert_eq "composition_mode_Pipeline" "Pipeline" "$COMP_MODE"

PIPE_LEN=$(yq -r '.spec.pipeline | length' "$COMP")
assert_eq "composition_pipeline_single_step" "1" "$PIPE_LEN"

PIPE_FN_NAME=$(yq -r '.spec.pipeline[0].functionRef.name' "$COMP")
assert_eq "composition_pipeline_functionRef" "function-patch-and-transform" "$PIPE_FN_NAME"

PIPE_INPUT_API=$(yq -r '.spec.pipeline[0].input.apiVersion' "$COMP")
PIPE_INPUT_KIND=$(yq -r '.spec.pipeline[0].input.kind' "$COMP")
assert_eq "composition_pipeline_input_apiVersion" "pt.fn.crossplane.io/v1beta1" "$PIPE_INPUT_API"
assert_eq "composition_pipeline_input_kind"       "Resources"                  "$PIPE_INPUT_KIND"

assert_summary
