#!/usr/bin/env bash
# Unit tests for the coverage deriver (FINAL-PLAN §4.5).
#
# Guards the extractor<->oracle contract so the generated coverage set and the
# committed oracle can never silently drift (the round-2 draft shipped an oracle
# written version-stripped while the command emitted versions, which would have
# stuck the gate WARN-ONLY forever — round-3 k8s-expert C2). Also asserts:
#   - byte-identical: derive-coverage.sh output == expected-coverage.txt
#   - version-independence: a v1beta1->v1beta2 bump yields the SAME keys
#   - registry completeness (ENFORCE): every derived kind is registered, and no
#     registry entry is stale
#   - the WARN->enforce flip lint: once the byte-identical fixture passes, the
#     deriver's mode flag MUST be `enforce` (a green fixture with mode still
#     `warn` is itself a red diff — round-3 devx M4)
#   - defended_by coverage (WARN-ONLY until P2/P4): a `pending:*` marker prints a
#     WARN but does not fail.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

DERIVE=tests/coverage/derive-coverage.sh
ORACLE=tests/coverage/expected-coverage.txt
REGISTRY=tests/coverage/registry.yaml
MODE_FILE=tests/coverage/mode
FIXDIR=tests/coverage/fixtures/version-bump

echo "── coverage: byte-identical extractor <-> oracle ─────────────"
derived="$("$DERIVE" 2>/dev/null)"
oracle="$(sort -u "$ORACLE")"
assert_eq "derived set == committed oracle (byte-identical)" "$oracle" "$derived"

# Record whether the byte-identical contract holds — it gates the flip lint.
fixture_green=false
[ "$derived" = "$oracle" ] && fixture_green=true

echo ""
echo "── coverage: version-independence (v1beta1 == v1beta2) ───────"
v1="$(COVERAGE_COMPOSITIONS_DIR="$FIXDIR" bash -c '
  yq ".spec.pipeline[]?.input.resources[]? | select(.base) | (.base.apiVersion | sub(\"/.*\";\"\")) + \"/\" + .base.kind" '"$FIXDIR"'/comp-v1beta1.yaml | sort -u')"
v2="$(yq '.spec.pipeline[]?.input.resources[]? | select(.base) | (.base.apiVersion | sub("/.*";"")) + "/" + .base.kind' "$FIXDIR/comp-v1beta2.yaml" | sort -u)"
assert_eq "v1beta1 keys == v1beta2 keys (version-stripped)" "$v1" "$v2"
assert_contains "fixture yields group/kind, no version" "iam.aws.m.upbound.io/Role" "$v1"
assert_eq "no version segment leaked into the key" "" "$(printf '%s\n' "$v1" | grep -E '/v[0-9]' || true)"

echo ""
echo "── coverage: registry completeness (ENFORCE) ─────────────────"
# Every derived kind must be a key under registry.yaml `kinds:`.
registered="$(yq -r '.kinds | keys | .[]' "$REGISTRY" | sort -u)"
missing="$(comm -23 <(printf '%s\n' "$derived") <(printf '%s\n' "$registered"))"
assert_eq "every derived kind is registered" "" "$missing"
# No stale registry entry (a key with no backing composition).
stale="$(comm -13 <(printf '%s\n' "$derived") <(printf '%s\n' "$registered"))"
assert_eq "no stale registry entry" "" "$stale"

echo ""
echo "── coverage: WARN->enforce flip lint (round-3 devx M4) ───────"
mode="$(tr -d '[:space:]' < "$MODE_FILE")"
if [ "$fixture_green" = "true" ]; then
  assert_eq "byte-identical fixture passes => mode must be 'enforce'" "enforce" "$mode"
else
  _pass "fixture not yet green => WARN-ONLY tolerated (mode=$mode)"
fi
# The drift gate itself must agree with the mode (exit 0 here since sets match).
"$DERIVE" --check >/dev/null 2>&1
assert_exit_code "derive --check passes on the committed tree" 0 "$DERIVE" --check

echo ""
echo "── coverage: defended_by coverage (WARN-ONLY until P2/P4) ────"
pending_count=0
while IFS= read -r k; do
  d="$(yq -r ".kinds.\"$k\".defended_by" "$REGISTRY")"
  case "$d" in
    pending:*) pending_count=$((pending_count+1)); echo "  WARN: $k defended_by=$d (behavioral test pending)" ;;
    null|"")   _fail "defended_by present for $k" "missing defended_by field" ;;
  esac
done <<< "$derived"
# Not a failure while behavioral phases are open; just report the count.
echo "  ($pending_count kind(s) awaiting a behavioral test — WARN, not FAIL)"
_pass "defended_by field present for every registered kind"

assert_summary
