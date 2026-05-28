#!/usr/bin/env bash
# SPEC-C4 §7.1.4 unit-test.
#
# Each chainsaw-test.yaml under tests/chainsaw/platform-secret/ MUST
# contain at least one `file: expected/` reference inside its `assert:`
# steps. Catches "author added the golden file but forgot to wire it
# into the scenario."

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

SCENARIOS=$(find tests/chainsaw/platform-secret -name 'chainsaw-test.yaml' -type f | sort)

if [ -z "$SCENARIOS" ]; then
  _fail "scenarios_discovered" "no platform-secret chainsaw-test.yaml files"
  assert_summary; exit 1
fi
_pass "scenarios_discovered ($(echo "$SCENARIOS" | wc -l | tr -d ' ') file(s))"

while IFS= read -r f; do
  # Match `file: expected/...` — chainsaw's `assert: { file: <path> }`
  # form (spec §5 "use the first form per-step for readability").
  matches=$(grep -cE 'file:[[:space:]]+expected/' "$f" || true)
  if [ "$matches" -ge 1 ] 2>/dev/null; then
    _pass "assert_references_golden_${f} (${matches} reference(s))"
  else
    _fail "assert_references_golden_${f}" \
      "no 'file: expected/...' assert reference in $f (SPEC-C4 §7.1.4)"
  fi
done <<< "$SCENARIOS"

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
