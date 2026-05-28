#!/usr/bin/env bash
# Crossplane v2 XRs emit 3 status conditions in this order:
#
#   - Synced     (status=True when reconciliation succeeds)
#   - Ready      (status=True when all composed resources are ready)
#   - Responsive (status=True when the watch circuit is closed)
#
# Chainsaw's assert tree matches arrays element-wise at the same index
# (kyverno-json semantics) — NOT partial. A chainsaw scenario that
# asserts only `[Ready]` or `[Synced, Ready]` will fail against a v2
# XR with `lengths of slices don't match` even though the underlying
# XR has reached Ready=True. The scenario chainsaw-test.yaml MUST
# list all 3 conditions to match v2 reality.
#
# This test scans every chainsaw scenario under platform-secret/ and
# platform-cluster/ for `status.conditions:` blocks and asserts each
# carries all 3 condition types. It is the regression test for the bug
# surfaced by chainsaw run 26544796570 (3 platform-secret scenarios
# timed out at 245s on chainsaw assert error).

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

FILES=$(
  find tests/chainsaw/platform-secret \
       tests/chainsaw/platform-cluster \
       tests/chainsaw/_meta \
       -name 'chainsaw-test.yaml' -type f 2>/dev/null | sort
)

if [ -z "$FILES" ]; then
  _fail "scenarios_discovered" "no chainsaw-test.yaml files found"
  assert_summary; exit 1
fi
_pass "scenarios_discovered ($(echo "$FILES" | wc -l | tr -d ' ') file(s))"

# For each scenario that has a `status.conditions:` assert block,
# the block MUST contain all 3 condition `type:` lines.
while IFS= read -r f; do
  # Skip scenarios that don't assert XR conditions at all (e.g.
  # xrd-establishes which checks XRD CRD status, not XR status).
  if ! grep -q '^[[:space:]]*status:' "$f"; then
    _pass "skipped_${f} (no XR status assert)"
    continue
  fi

  # Inspect the conditions block. We look for the three type names
  # appearing in the file.
  has_synced=$(grep -c '^[[:space:]]*- type: Synced$' "$f" || true)
  has_ready=$(grep -c '^[[:space:]]*- type: Ready$' "$f" || true)
  has_responsive=$(grep -c '^[[:space:]]*- type: Responsive$' "$f" || true)

  # Check only when the file is asserting status.conditions on an XR.
  if ! grep -q '^[[:space:]]*conditions:' "$f"; then
    _pass "skipped_${f} (no conditions assert)"
    continue
  fi

  if [ "$has_synced" -ge 1 ] && [ "$has_ready" -ge 1 ] && [ "$has_responsive" -ge 1 ]; then
    _pass "all_three_conditions_${f}"
  else
    _fail "all_three_conditions_${f}" \
      "missing condition type(s): Synced=$has_synced Ready=$has_ready Responsive=$has_responsive — v2 XR carries all 3"
  fi
done <<< "$FILES"

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
