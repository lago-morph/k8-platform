#!/usr/bin/env bash
# SPEC-C4 §7.1.5 unit-test.
#
# Golden files for region-bearing MRs (ASM Secret) MUST reference a
# chainsaw binding for the `spec.forProvider.region` value rather than a
# hardcoded region literal. Hardcoded regions are brittle across AWS
# accounts (see AGENTS.md §8.1: "the test account is ephemeral").
#
# The binding form is `($expected_region)` per SPEC-C4 §5.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

GOLDENS=$(find tests/chainsaw/platform-secret -path '*/expected/asm-secret.yaml' -type f | sort)

if [ -z "$GOLDENS" ]; then
  _fail "goldens_discovered" "no asm-secret.yaml goldens found"
  assert_summary; exit 1
fi
_pass "goldens_discovered ($(echo "$GOLDENS" | wc -l | tr -d ' ') file(s))"

# Identify the `region:` line under `forProvider:` (one or two indent
# levels under `spec:`) and assert it uses the binding form.
while IFS= read -r f; do
  region_line=$(grep -E '^[[:space:]]+region:[[:space:]]+' "$f" | head -1)
  if [ -z "$region_line" ]; then
    _fail "region_line_present_${f}" "no 'region:' line in $f"
    continue
  fi
  # Acceptable: `region: ($expected_region)` or any `($<name>)` binding.
  if echo "$region_line" | grep -qE '\(\$[a-zA-Z_][a-zA-Z0-9_]*\)'; then
    _pass "region_uses_binding_${f}"
  else
    _fail "region_uses_binding_${f}" \
      "hardcoded region in $f (line: ${region_line}); use a chainsaw binding"
  fi
done <<< "$GOLDENS"

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
