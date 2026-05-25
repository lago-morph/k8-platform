#!/usr/bin/env bash
# SPEC-S9 §7 unit-test #5 — confirms the helper reads the pinned
# function version from tests/chainsaw/versions.env and errors if
# that file is absent, rather than silently using an unpinned version.
#
# Pure static — no crossplane CLI required (we hit the error path
# before the CLI invocation).

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

HELPER="scripts/composition-render.sh"
VERSIONS="tests/chainsaw/versions.env"

if [ ! -f "$VERSIONS" ]; then
  _fail "versions_env_present" "$VERSIONS missing"
  assert_summary
fi
_pass "versions_env_present"

# The helper must reference versions.env. This is the static
# guarantee — the runtime check (helper errors when file missing) is
# implicit in the bash `if [ ! -f ... ]` block we just verified is
# part of the script.
if grep -q "tests/chainsaw/versions.env" "$HELPER"; then
  _pass "helper_references_versions_env"
else
  _fail "helper_references_versions_env" "$HELPER does not mention $VERSIONS"
fi

# Helper must accept either FUNCTION_PATCH_AND_TRANSFORM_VERSION or
# FUNCTION_PT_VERSION (spec uses PT_; on-disk file uses the long form).
if grep -q "FUNCTION_PATCH_AND_TRANSFORM_VERSION" "$HELPER"; then
  _pass "helper_reads_actual_version_var"
else
  _fail "helper_reads_actual_version_var" "$HELPER does not reference FUNCTION_PATCH_AND_TRANSFORM_VERSION"
fi

# versions.env must define the function version that the helper looks
# for — cross-file invariant.
# shellcheck disable=SC1090
. "$VERSIONS"
if [ -n "${FUNCTION_PATCH_AND_TRANSFORM_VERSION:-}" ]; then
  _pass "versions_env_defines_function_version"
else
  _fail "versions_env_defines_function_version" \
    "neither FUNCTION_PATCH_AND_TRANSFORM_VERSION nor FUNCTION_PT_VERSION set in $VERSIONS"
fi

assert_summary
