#!/usr/bin/env bash
# Unit tests for .github/scripts/parse-trigger.sh.
#
# Each test invokes the script against a fixture in tests/unit/fixtures/
# and asserts on either (a) the stdout key=value output for the happy
# paths, or (b) the non-zero exit code + stderr error message for the
# failure paths.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

SCRIPT=.github/scripts/parse-trigger.sh

echo "── parse-trigger: happy paths ────────────────────────────────"

happy_case() {
  local name="$1" fixture="$2" want_phase="$3" want_action="$4"
  local out
  out=$("$SCRIPT" "$fixture" 2>/dev/null)
  assert_contains "$name (phase)"  "phase=$want_phase"   "$out"
  assert_contains "$name (action)" "action=$want_action" "$out"
}

happy_case "base/plan"             tests/unit/fixtures/valid-base-plan.json             base plan
happy_case "base/apply"            tests/unit/fixtures/valid-base-apply.json            base apply
happy_case "base/verify"           tests/unit/fixtures/valid-base-verify.json           base verify
happy_case "base/apply-and-verify" tests/unit/fixtures/valid-base-apply-and-verify.json base apply-and-verify
happy_case "base/destroy"          tests/unit/fixtures/valid-base-destroy.json          base destroy
happy_case "mgmt/apply-and-verify" tests/unit/fixtures/valid-mgmt-apply-and-verify.json management apply-and-verify
happy_case "mgmt/destroy"          tests/unit/fixtures/valid-mgmt-destroy.json          management destroy
happy_case "test/test-unit"        tests/unit/fixtures/valid-test-unit.json             test test-unit
happy_case "test/test-e2e"         tests/unit/fixtures/valid-test-e2e.json              test test-e2e

echo ""
echo "── parse-trigger: failure paths ──────────────────────────────"

fail_case() {
  local name="$1" fixture="$2" want_msg="$3"
  local stderr exit_code
  set +e
  stderr=$("$SCRIPT" "$fixture" 2>&1 >/dev/null)
  exit_code=$?
  set -e
  if [ "$exit_code" -eq 0 ]; then
    _fail "$name (exit)" "expected non-zero exit, got 0"
  else
    _pass "$name (exit non-zero)"
  fi
  assert_contains "$name (msg)" "$want_msg" "$stderr"
}

fail_case "invalid phase"             tests/unit/fixtures/invalid-phase.json             "invalid phase"
fail_case "invalid action for base"   tests/unit/fixtures/invalid-action-for-base.json   "invalid action"
fail_case "invalid action for test"   tests/unit/fixtures/invalid-action-for-test.json   "invalid action"
fail_case "missing phase"             tests/unit/fixtures/missing-phase.json             "missing required field: phase"
fail_case "missing action"            tests/unit/fixtures/missing-action.json            "missing required field: action"
fail_case "malformed JSON"            tests/unit/fixtures/malformed.json                 "not valid JSON"

# File-not-found is a separate failure mode.
fail_case "missing file"              tests/unit/fixtures/does-not-exist.json            "trigger file not present"

assert_summary
