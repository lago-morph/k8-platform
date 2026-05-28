#!/usr/bin/env bash
# SPEC-C4 §7.1.3 unit-test.
#
# Each golden file under tests/chainsaw/platform-secret/**/expected/
# whose kind is an Upbound ASM Secret (apiVersion under
# `secretsmanager.aws.m.upbound.io`) MUST contain a `spec.forProvider`
# block — the actual contract the golden defends.
#
# A golden that asserts only `metadata.*` is a tautology against the
# live MR and wouldn't have caught Bug 4. This test prevents that.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

if ! command -v yq >/dev/null 2>&1; then
  _fail "yq_available" "yq not on PATH"
  assert_summary; exit 1
fi
_pass "yq_available"

YQ_VARIANT=python
if yq --version 2>&1 | grep -q mikefarah; then
  YQ_VARIANT=mikefarah
fi
_pass "yq_variant_detected (${YQ_VARIANT})"

get_apiversion() {
  local f="$1"
  if [ "$YQ_VARIANT" = "mikefarah" ]; then
    yq '.apiVersion // ""' "$f" 2>/dev/null
  else
    yq -r '.apiVersion // ""' "$f" 2>/dev/null
  fi
}

has_forProvider_map() {
  local f="$1"
  local t
  if [ "$YQ_VARIANT" = "mikefarah" ]; then
    t=$(yq '.spec.forProvider | tag' "$f" 2>/dev/null)
    # Mike Farah emits e.g. !!map / !!null
    [ "$t" = "!!map" ]
  else
    t=$(yq -r '.spec.forProvider | type' "$f" 2>/dev/null)
    [ "$t" = "object" ]
  fi
}

GOLDENS=$(find tests/chainsaw -path '*/expected/*.yaml' -type f | sort)

if [ -z "$GOLDENS" ]; then
  _fail "goldens_discovered" "no goldens found"
  assert_summary; exit 1
fi
_pass "goldens_discovered ($(echo "$GOLDENS" | wc -l | tr -d ' ') file(s))"

while IFS= read -r f; do
  api=$(get_apiversion "$f")
  case "$api" in
    *secretsmanager.aws.m.upbound.io*)
      if has_forProvider_map "$f"; then
        _pass "spec_forProvider_present_${f}"
      else
        _fail "spec_forProvider_present_${f}" \
          "ASM Secret golden $f lacks a spec.forProvider map (SPEC-C4 §7.1.3)"
      fi
      ;;
    *)
      _pass "spec_forProvider_not_required_${f} (kind: ${api})"
      ;;
  esac
done <<< "$GOLDENS"

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
