#!/usr/bin/env bash
# Unit tests for .github/scripts/compute-gates.sh.
#
# Asserts that (event, phase, action) tuples produce the exact set of
# gate booleans the workflow expects. One test per documented row in
# ai/testing-guidelines.md §6 and §8.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

SCRIPT=.github/scripts/compute-gates.sh

# Helper: run the script and check that exactly the listed gates are 'true'
# (all others must be 'false').  Pass gate names as remaining args.
check_gates() {
  local name="$1" event="$2" phase="$3" action="$4"; shift 4
  local expected_true="$*"
  local out
  set +e
  out=$("$SCRIPT" "$event" "$phase" "$action" 2>/dev/null)
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    _fail "$name" "compute-gates exited $rc unexpectedly"
    return
  fi
  local all_gates="base_init base_plan base_apply base_verify base_destroy mgmt_init mgmt_plan mgmt_apply mgmt_verify mgmt_destroy test_unit test_e2e"
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

echo "── compute-gates: push events ────────────────────────────────"
# Push always runs plan-both regardless of (phase, action) values.
check_gates "push (ignores phase/action)" push "" "" base_init base_plan mgmt_init mgmt_plan
check_gates "push with garbage phase"     push junk junk base_init base_plan mgmt_init mgmt_plan

echo ""
echo "── compute-gates: phase=base ─────────────────────────────────"
check_gates "base/plan"             workflow_dispatch base plan             base_init base_plan
check_gates "base/apply"            workflow_dispatch base apply            base_init base_plan base_apply
check_gates "base/verify"           workflow_dispatch base verify           base_init base_verify
check_gates "base/apply-and-verify" workflow_dispatch base apply-and-verify base_init base_plan base_apply base_verify
check_gates "base/destroy"          workflow_dispatch base destroy          base_init base_destroy

echo ""
echo "── compute-gates: phase=management ───────────────────────────"
check_gates "mgmt/plan"             workflow_dispatch management plan             mgmt_init mgmt_plan
check_gates "mgmt/apply"            workflow_dispatch management apply            mgmt_init mgmt_plan mgmt_apply
check_gates "mgmt/verify"           workflow_dispatch management verify           mgmt_init mgmt_verify
check_gates "mgmt/apply-and-verify" workflow_dispatch management apply-and-verify mgmt_init mgmt_plan mgmt_apply mgmt_verify
check_gates "mgmt/destroy"          workflow_dispatch management destroy          mgmt_init mgmt_destroy

echo ""
echo "── compute-gates: phase=test ─────────────────────────────────"
check_gates "test/test-unit" workflow_dispatch test test-unit test_unit
check_gates "test/test-e2e"  workflow_dispatch test test-e2e  test_e2e

echo ""
echo "── compute-gates: error paths ────────────────────────────────"
assert_exit_code "missing phase on non-push"   2 "$SCRIPT" workflow_dispatch "" plan
assert_exit_code "invalid phase"               2 "$SCRIPT" workflow_dispatch bogus plan
assert_exit_code "invalid action for base"     2 "$SCRIPT" workflow_dispatch base nuke
assert_exit_code "invalid action for mgmt"     2 "$SCRIPT" workflow_dispatch management nuke
assert_exit_code "invalid action for test"     2 "$SCRIPT" workflow_dispatch test apply
assert_exit_code "base action for test phase"  2 "$SCRIPT" workflow_dispatch test plan

assert_summary
