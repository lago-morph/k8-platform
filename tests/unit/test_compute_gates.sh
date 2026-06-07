#!/usr/bin/env bash
# Unit tests for .github/scripts/compute-gates.sh.
#
# Asserts that (phase, action) tuples produce the exact set of
# gate booleans the workflow expects. One test per documented row in
# ai/testing-guidelines.md §6.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

SCRIPT=.github/scripts/compute-gates.sh

# Helper: run the script and check that exactly the listed gates are 'true'
# (all others must be 'false').  Pass gate names as remaining args.
check_gates() {
  local name="$1" phase="$2" action="$3"; shift 3
  local expected_true="$*"
  local out
  set +e
  out=$("$SCRIPT" "$phase" "$action" 2>/dev/null)
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    _fail "$name" "compute-gates exited $rc unexpectedly"
    return
  fi
  local all_gates="base_init base_plan base_apply base_verify base_destroy mgmt_init mgmt_plan mgmt_apply mgmt_verify mgmt_destroy mgmt_live_verify test_unit test_e2e"
  local fail=0
  local detail=""
  for gate in $all_gates; do
    local expected=false
    for t in $expected_true; do
      [ "$t" = "$gate" ] && expected=true
    done
    local actual
    actual=$(printf '%s\n' "$out" | grep "^${gate}=" | cut -d= -f2)
    if [ "$actual" != "$expected" ]; then
      fail=1
      detail="${detail}${gate}: expected=$expected actual=$actual; "
    fi
  done
  if [ "$fail" -eq 0 ]; then
    _pass "$name"
  else
    _fail "$name" "$detail"
  fi
}

echo "── compute-gates: phase=base ─────────────────────────────────"
check_gates "base/plan"             base plan             base_init base_plan
check_gates "base/apply"            base apply            base_init base_plan base_apply
check_gates "base/verify"           base verify           base_init base_verify
check_gates "base/apply-and-verify" base apply-and-verify base_init base_plan base_apply base_verify
check_gates "base/destroy"          base destroy          base_init base_destroy

echo ""
echo "── compute-gates: phase=management ───────────────────────────"
check_gates "mgmt/plan"             management plan             mgmt_init mgmt_plan
check_gates "mgmt/apply"            management apply            mgmt_init mgmt_plan mgmt_apply mgmt_live_verify
check_gates "mgmt/verify"           management verify           mgmt_init mgmt_verify mgmt_live_verify
check_gates "mgmt/apply-and-verify" management apply-and-verify mgmt_init mgmt_plan mgmt_apply mgmt_verify mgmt_live_verify
check_gates "mgmt/destroy"          management destroy          mgmt_init mgmt_destroy

echo ""
echo "── compute-gates: mgmt_live_verify invariant (FINAL-PLAN §4.1) ─"
# The load-bearing assertion: ANY management apply must turn the live-verify
# gate true, so a bare action=apply cannot bring the cluster up unverified.
# These are redundant with the rows above but are stated explicitly so the
# invariant is greppable and a regression names the right contract.
mlv() { "$SCRIPT" management "$1" 2>/dev/null | grep '^mgmt_live_verify=' | cut -d= -f2; }
assert_eq "apply => live-verify on"            true  "$(mlv apply)"
assert_eq "verify => live-verify on"           true  "$(mlv verify)"
assert_eq "apply-and-verify => live-verify on" true  "$(mlv apply-and-verify)"
assert_eq "plan => live-verify off"            false "$(mlv plan)"
assert_eq "destroy => live-verify off"         false "$(mlv destroy)"

echo ""
echo "── compute-gates: phase=test ─────────────────────────────────"
check_gates "test/test-unit" test test-unit test_unit
check_gates "test/test-e2e"  test test-e2e  test_e2e

echo ""
echo "── compute-gates: error paths ────────────────────────────────"
assert_exit_code "missing phase"               2 "$SCRIPT" "" plan
assert_exit_code "invalid phase"               2 "$SCRIPT" bogus plan
assert_exit_code "invalid action for base"     2 "$SCRIPT" base nuke
assert_exit_code "invalid action for mgmt"     2 "$SCRIPT" management nuke
assert_exit_code "invalid action for test"     2 "$SCRIPT" test apply
assert_exit_code "base action for test phase"  2 "$SCRIPT" test plan

assert_summary
