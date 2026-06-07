#!/usr/bin/env bash
# Unit tests for the XSpokeAccess XRD + Composition + XR (auto-008
# Round 2 §3 / C1–C6, S1–S4).
#
# Bug classes defended:
#   - XRD v2 contract drift (scope, claimNames, served/referenceable,
#     defaultCompositionRef mismatch) — mirrors test_platform_cluster_xrd.sh.
#   - Composition renders the wrong spoke-access shape: missing OIDC
#     thumbprint constant (C1), external-dns trust policy NOT StringEquals
#     on BOTH sub AND aud (S2), wrong AccessEntry/AccessPolicyAssociation
#     policyArn (the EKS cluster-admin access policy), managed Policy MR
#     instead of an inline RolePolicy (C4), or committed account-ephemeral
#     literals in the XR/claim (S4).

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

XRD=crossplane/xrds/xspokeaccess.yaml
COMP=crossplane/compositions/xspokeaccess.yaml
XR=clusters/platform/spoke-access/spoke-access.yaml

# ---- 0. files exist -----------------------------------------------------
for f in "$XRD" "$COMP" "$XR"; do
  if [ -f "$f" ]; then _pass "file_exists:$f"; else _fail "file_exists:$f" "$f not found"; assert_summary; fi
done

# ---- 1. XRD v2 contract -------------------------------------------------
assert_eq "xrd_apiVersion" "apiextensions.crossplane.io/v2" "$(yq -r '.apiVersion' "$XRD")"
assert_eq "xrd_kind"       "CompositeResourceDefinition"    "$(yq -r '.kind'       "$XRD")"
assert_eq "xrd_group"      "platform.k8-platform.io"        "$(yq -r '.spec.group' "$XRD")"
assert_eq "xrd_scope_Namespaced" "Namespaced" "$(yq -r '.spec.scope' "$XRD")"
assert_eq "xrd_claimNames_absent" "null" "$(yq -r '.spec.claimNames' "$XRD")"
assert_eq "xrd_kind_name"  "XSpokeAccess"   "$(yq -r '.spec.names.kind' "$XRD")"
assert_eq "xrd_plural"     "xspokeaccesses" "$(yq -r '.spec.names.plural' "$XRD")"
assert_eq "xrd_default_composition" "xspokeaccess-aws" "$(yq -r '.spec.defaultCompositionRef.name' "$XRD")"
assert_eq "xrd_default_composition_matches_file" "xspokeaccess-aws" "$(yq -r '.metadata.name' "$COMP")"
assert_eq "xrd_v1alpha1_served"        "true" "$(yq -r '.spec.versions[] | select(.name=="v1alpha1") | .served' "$XRD")"
assert_eq "xrd_v1alpha1_referenceable" "true" "$(yq -r '.spec.versions[] | select(.name=="v1alpha1") | .referenceable' "$XRD")"
assert_eq "xrd_wave_minus_one" "-1" "$(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$XRD")"

# required spec fields: clusterName, subdomain, oidcIssuer (all operator/
# claim-provided; the account-ephemeral values come from the EnvironmentConfig)
REQUIRED=$(yq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.required[]' "$XRD")
for r in clusterName subdomain oidcIssuer; do
  echo "$REQUIRED" | grep -qx "$r" \
    && _pass "xrd_spec_required:$r" \
    || _fail "xrd_spec_required:$r" "spec.$r not in required"
done

# status echoes the three ARNs
for s in oidcProviderArn externalDnsRoleArn accessEntryArn; do
  t=$(yq -r ".spec.versions[0].schema.openAPIV3Schema.properties.status.properties.${s}.type" "$XRD")
  assert_eq "xrd_status:$s" "string" "$t"
done

# strict schema — no preserve-unknown-fields: true
if grep -q "x-kubernetes-preserve-unknown-fields:[[:space:]]*true" "$XRD"; then
  _fail "xrd_strict_schema" "x-kubernetes-preserve-unknown-fields: true found"
else
  _pass "xrd_strict_schema"
fi

# ---- 2. Composition shape ----------------------------------------------
assert_eq "comp_apiVersion" "apiextensions.crossplane.io/v1" "$(yq -r '.apiVersion' "$COMP")"
assert_eq "comp_mode_pipeline" "Pipeline" "$(yq -r '.spec.mode' "$COMP")"

XRD_GROUP=$(yq -r '.spec.group' "$XRD")
XRD_VERSION=$(yq -r '.spec.versions[0].name' "$XRD")
XRD_KIND=$(yq -r '.spec.names.kind' "$XRD")
assert_eq "comp_typeRef_apiVersion" "${XRD_GROUP}/${XRD_VERSION}" "$(yq -r '.spec.compositeTypeRef.apiVersion' "$COMP")"
assert_eq "comp_typeRef_kind"       "$XRD_KIND"                    "$(yq -r '.spec.compositeTypeRef.kind' "$COMP")"

# pipeline: function-environment-configs (cluster-network) THEN function-patch-and-transform
assert_eq "comp_env_step" "function-environment-configs" \
  "$(yq -r '.spec.pipeline[] | select(.functionRef.name=="function-environment-configs") | .functionRef.name' "$COMP")"
assert_eq "comp_env_ref_cluster_network" "cluster-network" \
  "$(yq -r '.spec.pipeline[] | select(.functionRef.name=="function-environment-configs") | .input.spec.environmentConfigs[0].ref.name' "$COMP")"

PT='.spec.pipeline[] | select(.functionRef.name == "function-patch-and-transform") | .input'
assert_eq "comp_pt_step" "function-patch-and-transform" \
  "$(yq -r '.spec.pipeline[] | select(.functionRef.name=="function-patch-and-transform") | .functionRef.name' "$COMP")"

# five resources rendered
assert_eq "comp_resource_count" "5" "$(yq -r "${PT}.resources | length" "$COMP")"

# 2a. OpenIDConnectProvider — kind, thumbprint constant (C1), clientId
OIDC='.resources[] | select(.name=="oidc-provider") | .base'
assert_eq "comp_oidc_kind" "OpenIDConnectProvider" "$(yq -r "${PT} | ${OIDC}.kind" "$COMP")"
assert_eq "comp_oidc_apiVersion" "iam.aws.m.upbound.io/v1beta1" "$(yq -r "${PT} | ${OIDC}.apiVersion" "$COMP")"
assert_eq "comp_oidc_thumbprint" "9e99a48a9960b14926bb7f3b02e22da2b0ab7280" \
  "$(yq -r "${PT} | ${OIDC}.spec.forProvider.thumbprintList[0]" "$COMP")"
assert_eq "comp_oidc_clientId" "sts.amazonaws.com" \
  "$(yq -r "${PT} | ${OIDC}.spec.forProvider.clientIdList[0]" "$COMP")"

# 2b. external-dns Role — inline RolePolicy (C4), NOT a managed Policy MR
ROLE_KIND=$(yq -r "${PT}.resources[] | select(.name==\"external-dns-role\") | .base.kind" "$COMP")
assert_eq "comp_external_dns_role_kind" "Role" "$ROLE_KIND"
POLICY_KIND=$(yq -r "${PT}.resources[] | select(.name==\"external-dns-policy\") | .base.kind" "$COMP")
assert_eq "comp_external_dns_policy_is_inline_RolePolicy" "RolePolicy" "$POLICY_KIND"
# Defense against regression to a managed Policy MR (C4 — the IRSA lacks iam:CreatePolicy)
if yq -r "${PT}.resources[].base.kind" "$COMP" | grep -qx 'Policy'; then
  _fail "comp_no_managed_policy_mr" "a managed iam Policy MR is present; C4 requires an inline RolePolicy"
else
  _pass "comp_no_managed_policy_mr"
fi

# 2c. trust policy: StringEquals on BOTH :sub AND :aud (S2 — never StringLike)
TRUST=$(yq -r "${PT}.resources[] | select(.name==\"external-dns-role\") | .patches[] | select(.toFieldPath==\"spec.forProvider.assumeRolePolicy\") | .combine.string.fmt" "$COMP")
echo "$TRUST" | grep -q 'StringEquals' \
  && _pass "comp_trust_StringEquals" \
  || _fail "comp_trust_StringEquals" "trust policy is not StringEquals"
echo "$TRUST" | grep -q 'StringLike' \
  && _fail "comp_trust_no_StringLike" "trust policy uses StringLike (S2 forbids it)" \
  || _pass "comp_trust_no_StringLike"
echo "$TRUST" | grep -q ':sub' \
  && _pass "comp_trust_has_sub" \
  || _fail "comp_trust_has_sub" "trust policy missing :sub condition"
echo "$TRUST" | grep -q ':aud' \
  && _pass "comp_trust_has_aud" \
  || _fail "comp_trust_has_aud" "trust policy missing :aud condition (S2 requires sub AND aud)"
echo "$TRUST" | grep -q 'system:serviceaccount:external-dns:external-dns' \
  && _pass "comp_trust_sa_subject" \
  || _fail "comp_trust_sa_subject" "trust policy subject is not external-dns:external-dns"

# 2d. AccessEntry + AccessPolicyAssociation (C3) — kinds, policyArn, scope
AE='.resources[] | select(.name=="access-entry") | .base'
assert_eq "comp_access_entry_kind" "AccessEntry" "$(yq -r "${PT} | ${AE}.kind" "$COMP")"
assert_eq "comp_access_entry_apiVersion" "eks.aws.m.upbound.io/v1beta1" "$(yq -r "${PT} | ${AE}.apiVersion" "$COMP")"
APA='.resources[] | select(.name=="access-policy-association") | .base'
assert_eq "comp_apa_kind" "AccessPolicyAssociation" "$(yq -r "${PT} | ${APA}.kind" "$COMP")"
assert_eq "comp_apa_policyArn" "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" \
  "$(yq -r "${PT} | ${APA}.spec.forProvider.policyArn" "$COMP")"
assert_eq "comp_apa_scope_cluster" "cluster" "$(yq -r "${PT} | ${APA}.spec.forProvider.accessScope.type" "$COMP")"

# principalArn for both comes from the EnvironmentConfig (argocdRoleArn), not a literal
for r in access-entry access-policy-association; do
  src=$(yq -r "${PT}.resources[] | select(.name==\"${r}\") | .patches[] | select(.toFieldPath==\"spec.forProvider.principalArn\") | .fromFieldPath" "$COMP")
  assert_eq "comp_principalArn_from_env:$r" "argocdRoleArn" "$src"
done

# ---- 3. XR (claim) gating + no committed ephemerals (S4) ----------------
assert_eq "xr_kind" "XSpokeAccess" "$(yq -r '.kind' "$XR")"
assert_eq "xr_namespace" "platform" "$(yq -r '.metadata.namespace' "$XR")"
assert_eq "xr_clusterName" "k8-platform-services" "$(yq -r '.spec.clusterName' "$XR")"
# sync-wave AFTER the cluster XR (wave 10)
XR_WAVE=$(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$XR")
[ "$XR_WAVE" -gt 10 ] 2>/dev/null \
  && _pass "xr_wave_after_cluster" \
  || _fail "xr_wave_after_cluster" "XR sync-wave ($XR_WAVE) must be > 10 (cluster XR wave)"
# oidcIssuer is a clearly-marked placeholder, not a real issuer
ISS=$(yq -r '.spec.oidcIssuer' "$XR")
echo "$ISS" | grep -qi 'PLACEHOLDER' \
  && _pass "xr_oidcIssuer_placeholder" \
  || _fail "xr_oidcIssuer_placeholder" "spec.oidcIssuer ($ISS) is not a marked placeholder (it is account-ephemeral, AGENTS §8.1)"

# S4: no committed account id / role ARN / zone id literals in the XR or claim app
EPHEM_SCAN_FILES=("$XR" argocd/apps/spoke-access.yaml)
ephem_fail=0
for f in "${EPHEM_SCAN_FILES[@]}"; do
  [ -f "$f" ] || continue
  # real 12-digit account id inside an ARN (stub 000000000000 allowed)
  if grep -rEn 'arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:' "$f" | grep -vE ':000000000000:' | grep -vi 'placeholder'; then
    _fail "xr_no_real_arn:$f" "real AWS ARN with non-stub account id committed"
    ephem_fail=1
  fi
  # real Route53 zone id literal (Z + 13-32 alnum) other than the stub
  if grep -rEn '\bZ[A-Z0-9]{13,}\b' "$f" | grep -v 'Z00000000000000000000Q'; then
    _fail "xr_no_real_zoneid:$f" "real-looking Route53 zone id committed"
    ephem_fail=1
  fi
done
[ "$ephem_fail" -eq 0 ] && _pass "xr_no_committed_ephemerals_S4"

# ---- 4. ArgoCD Application — manual-sync, gated, correct project --------
APP=argocd/apps/spoke-access.yaml
assert_eq "app_kind" "Application" "$(yq -r '.kind' "$APP")"
assert_eq "app_project" "k8-platform" "$(yq -r '.spec.project' "$APP")"
assert_eq "app_path_exists" "clusters/platform/spoke-access" "$(yq -r '.spec.source.path' "$APP")"
[ -d "$(yq -r '.spec.source.path' "$APP")" ] \
  && _pass "app_source_path_is_dir" \
  || _fail "app_source_path_is_dir" "Application source.path is not a real directory"
# manual sync only (no automated block) + documented
assert_eq "app_no_automated" "null" "$(yq -r '.spec.syncPolicy.automated' "$APP")"
grep -q "manual sync only" "$APP" \
  && _pass "app_manual_sync_documented" \
  || _fail "app_manual_sync_documented" "manual-sync choice not documented in the Application header"

assert_summary
