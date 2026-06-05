#!/usr/bin/env bash
# Unit tests for the Chainsaw harness configuration.
#
# Bug class defended: silent version drift between the chainsaw kind
# cluster and what the management cluster actually runs. If the chainsaw
# Crossplane is one major version ahead of management's, a Composition
# can test green in CI and break on apply. These tests pin the cross-
# file invariants in one place.
#
# Pure static — no kind, no docker, no chainsaw binary required.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

VERSIONS=tests/chainsaw/versions.env
KIND_CONFIG=tests/chainsaw/kind-config.yaml
TF_VARIABLES=terraform/management/variables.tf

if [ ! -f "$VERSIONS" ]; then
  _fail "chainsaw_versions_env_exists" "$VERSIONS not found"
  assert_summary
fi
# shellcheck disable=SC1090
. "$VERSIONS"
_pass "chainsaw_versions_env_loads"

# ---- 1. KINDEST_NODE_IMAGE is digest-pinned ------------------------------
#
# Defends contract: kindest/node references must include a sha256 digest,
# not just a tag. Tags are mutable upstream; without the digest a
# successful CI run is silently non-reproducible.
case "${KINDEST_NODE_IMAGE:-}" in
  *@sha256:*)
    _pass "kindest_node_image_digest_pinned"
    ;;
  *)
    _fail "kindest_node_image_digest_pinned" "no @sha256: in '$KINDEST_NODE_IMAGE'"
    ;;
esac

# ---- 2. KINDEST_NODE_IMAGE major.minor is in an allowlist ----------------
#
# Defends contract: only Kubernetes versions in the Crossplane v2
# support matrix can be used. Bumping outside the allowlist must be a
# deliberate edit to this test.
case "${KINDEST_NODE_IMAGE:-}" in
  *kindest/node:v1.31.*|*kindest/node:v1.32.*|*kindest/node:v1.33.*)
    _pass "kindest_node_image_version_in_allowlist"
    ;;
  *)
    _fail "kindest_node_image_version_in_allowlist" "version not in v1.31/v1.32/v1.33 allowlist: '$KINDEST_NODE_IMAGE'"
    ;;
esac

# ---- 3. CROSSPLANE_CHART_VERSION is a literal, no :latest ----------------
case "${CROSSPLANE_CHART_VERSION:-}" in
  latest|"") _fail "crossplane_chart_version_pinned" "version is empty or 'latest'" ;;
  *)         _pass "crossplane_chart_version_pinned" ;;
esac

# ---- 4. PROVIDER_FAMILY_AWS_VERSION is a literal, no :latest -------------
case "${PROVIDER_FAMILY_AWS_VERSION:-}" in
  latest|"") _fail "provider_family_aws_version_pinned" "version is empty or 'latest'" ;;
  v*)        _pass "provider_family_aws_version_pinned" ;;
  *)         _fail "provider_family_aws_version_pinned" "expected v-prefix, got '$PROVIDER_FAMILY_AWS_VERSION'" ;;
esac

# ---- 5. CHAINSAW_VERSION pinned ------------------------------------------
case "${CHAINSAW_VERSION:-}" in
  latest|"") _fail "chainsaw_version_pinned" "empty or 'latest'" ;;
  v*)        _pass "chainsaw_version_pinned" ;;
  *)         _fail "chainsaw_version_pinned" "expected v-prefix, got '$CHAINSAW_VERSION'" ;;
esac

# ---- 6. KIND_VERSION pinned ----------------------------------------------
case "${KIND_VERSION:-}" in
  latest|"") _fail "kind_version_pinned" "empty or 'latest'" ;;
  v*)        _pass "kind_version_pinned" ;;
  *)         _fail "kind_version_pinned" "expected v-prefix, got '$KIND_VERSION'" ;;
esac

# ---- 7. ASM_PREFIX scoped to the project name ----------------------------
#
# Defends contract: the IRSA policy attached to the CI runner role MUST
# grant secretsmanager actions on arn:...secret:${ASM_PREFIX}*. The
# prefix here MUST be a strict prefix the IRSA wildcard covers — drift
# means scenarios fail with AccessDenied, which looks identical to a
# "credentials broken" failure and wastes diagnosis time.
case "${ASM_PREFIX:-}" in
  k8-platform-chainsaw) _pass "asm_prefix_matches_irsa_scope" ;;
  *) _fail "asm_prefix_matches_irsa_scope" "got '${ASM_PREFIX}', expected 'k8-platform-chainsaw'" ;;
esac

# ---- 8. Crossplane chart version matches management module ---------------
#
# Defends contract: the chainsaw cluster and the management cluster MUST
# install the same Crossplane chart version. Drift means a Composition
# can render and pass chainsaw but fail in management, or vice versa.
MGMT_CROSSPLANE=$(awk '/variable "crossplane_version"/,/^}/' "$TF_VARIABLES" \
  | awk -F'"' '/default/ {print $2}')
if [ -z "$MGMT_CROSSPLANE" ]; then
  _fail "mgmt_crossplane_version_extracted" "could not parse default from $TF_VARIABLES"
elif [ "$MGMT_CROSSPLANE" = "$CROSSPLANE_CHART_VERSION" ]; then
  _pass "chainsaw_crossplane_matches_management"
else
  _fail "chainsaw_crossplane_matches_management" \
    "chainsaw=$CROSSPLANE_CHART_VERSION management=$MGMT_CROSSPLANE — bump both together"
fi

# ---- 9. Provider package version matches management module --------------
MGMT_PROVIDER=$(awk '/variable "crossplane_provider_family_aws_version"/,/^}/' "$TF_VARIABLES" \
  | awk -F'"' '/default/ {print $2}')
if [ -z "$MGMT_PROVIDER" ]; then
  _fail "mgmt_provider_version_extracted" "could not parse default from $TF_VARIABLES"
elif [ "$MGMT_PROVIDER" = "$PROVIDER_FAMILY_AWS_VERSION" ]; then
  _pass "chainsaw_provider_matches_management"
else
  _fail "chainsaw_provider_matches_management" \
    "chainsaw=$PROVIDER_FAMILY_AWS_VERSION management=$MGMT_PROVIDER — bump both together"
fi

# ---- 9b. function-patch-and-transform version matches management module --
#
# Defends contract: chainsaw and management cluster must install the
# same function version. The Composition's input schema
# (`pt.fn.crossplane.io/v1beta1`) is tied to specific function versions;
# drift here means a Composition can render in chainsaw and fail in
# management, exactly the bug class this cross-check exists to catch.
MGMT_FN=$(awk '/variable "crossplane_function_patch_and_transform_version"/,/^}/' "$TF_VARIABLES" \
  | awk -F'"' '/default/ {print $2}')
case "${FUNCTION_PATCH_AND_TRANSFORM_VERSION:-}" in
  latest|"") _fail "function_patch_and_transform_version_pinned" "empty or 'latest'" ;;
  v*)        _pass "function_patch_and_transform_version_pinned" ;;
  *)         _fail "function_patch_and_transform_version_pinned" "expected v-prefix, got '$FUNCTION_PATCH_AND_TRANSFORM_VERSION'" ;;
esac
if [ -z "$MGMT_FN" ]; then
  _fail "mgmt_function_version_extracted" "could not parse default from $TF_VARIABLES"
elif [ "$MGMT_FN" = "$FUNCTION_PATCH_AND_TRANSFORM_VERSION" ]; then
  _pass "chainsaw_function_matches_management"
else
  _fail "chainsaw_function_matches_management" \
    "chainsaw=$FUNCTION_PATCH_AND_TRANSFORM_VERSION management=$MGMT_FN — bump both together"
fi

# ---- 10. kind config has exactly one control-plane node ------------------
ROLES=$(yq -r '.nodes[].role' "$KIND_CONFIG" 2>/dev/null | sort -u | tr '\n' ' ')
case "$ROLES" in
  "control-plane ") _pass "kind_config_single_control_plane_node" ;;
  *) _fail "kind_config_single_control_plane_node" "got roles: $ROLES" ;;
esac

# ---- 11. kind config name matches what run.sh uses ----------------------
KIND_NAME_YAML=$(yq -r '.name' "$KIND_CONFIG" 2>/dev/null)
KIND_NAME_RUNSH=$(grep -E '^CLUSTER_NAME=' tests/chainsaw/run.sh | head -1 | cut -d'"' -f2)
if [ "$KIND_NAME_YAML" = "$KIND_NAME_RUNSH" ]; then
  _pass "kind_config_name_matches_runsh"
else
  _fail "kind_config_name_matches_runsh" "yaml=$KIND_NAME_YAML runsh=$KIND_NAME_RUNSH"
fi

# ---- 12. run.sh has a cleanup trap on EXIT ------------------------------
#
# Defends contract: ASM secrets cost quota; a leaked secret survives 30
# days. run.sh MUST install an EXIT trap that calls the cleanup func.
if grep -qE '^trap [^ ]+ EXIT' tests/chainsaw/run.sh; then
  _pass "runsh_installs_exit_trap"
else
  _fail "runsh_installs_exit_trap" "no 'trap <fn> EXIT' line found"
fi

# ---- 13. chainsaw cleanup uses --force-delete-without-recovery ---------
#
# Defends contract: AWS Secrets Manager normally enforces a 7-day recovery
# window on delete. Chainsaw secrets are ephemeral and a re-run would
# fail with "scheduled for deletion" unless we force-delete.
#
# The ASM cleanup logic was extracted into tests/chainsaw/_lib/asm-cleanup.sh
# (sourced by run.sh's cleanup trap) so it can be unit-tested behaviorally —
# see tests/unit/test_chainsaw_asm_cleanup.sh. Check both the lib and run.sh
# so the contract holds wherever the delete call lives.
if grep -qrs 'force-delete-without-recovery' tests/chainsaw/_lib/asm-cleanup.sh tests/chainsaw/run.sh; then
  _pass "runsh_cleanup_force_deletes_asm_secrets"
else
  _fail "runsh_cleanup_force_deletes_asm_secrets" "cleanup must force-delete to avoid 7-day recovery window"
fi

# ---- 14. run.sh waits for provider Healthy before chainsaw run ----------
#
# Defends contract: race between claim apply and CRD install causes
# "no matches for kind" failures. Per adversarial reviewer B.
if grep -qE 'kubectl wait.*Healthy.*provider' tests/chainsaw/run.sh; then
  _pass "runsh_waits_for_provider_healthy"
else
  _fail "runsh_waits_for_provider_healthy" "must 'kubectl wait --for=condition=Healthy' on provider before scenarios"
fi

assert_summary
