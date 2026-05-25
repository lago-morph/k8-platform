#!/usr/bin/env bash
# Unit tests for scripts/phase-status.sh
#
# All tests use fixture shim binaries in tests/unit/fixtures/phase-status/
# to override PATH — no AWS credentials or live cluster required.
#
# Test cases (SPEC-S5 §6 + adversarial review):
#   1. test_table_has_seven_rows         — default mode prints 7 phase rows
#   2. test_table_has_headers            — table header row contains all 4 column names
#   3. test_json_keys_present            — --json has phases.0..phases.6
#   4. test_json_account_redacted        — .account is a string, not literal "null"
#   5. test_json_is_valid                — jq . parses --json output successfully
#   6. test_assert_phase_match           — --assert-phase 1 verified exits 0
#   7. test_assert_phase_no_match        — --assert-phase 1 applied exits 1
#   8. test_assert_phase_unknown_state   — --assert-phase 1 banana exits 2
#   9. test_assert_phase_unknown_number  — --assert-phase 99 verified exits 2
#  10. test_fail_soft_on_kubectl_error   — phase 2 broken: script exits 0, all rows present
#  11. test_no_color_when_piped          — stdout pipe: no ANSI escapes
#  12. test_help_exits_0                 — --help exits 0
#  13. test_unknown_flag_nonzero         — bogus flag exits non-zero
#  14. test_all_not_coded_when_empty     — empty AWS/k8s → all phases not-coded or code-only
#  15. test_snapshot_file_written        — /tmp/phase-status-*.json written after --json

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/unit/fixtures/phase-status"
SCRIPT="$REPO_ROOT/scripts/phase-status.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Run phase-status.sh with the named aws/kubectl shims on PATH.
# $1 = aws shim filename, $2 = kubectl shim filename, remainder = args.
# Captures stdout; returns the script's exit code.
run_ps() {
  local aws_shim="$1"; shift
  local kube_shim="$1"; shift
  local tmpdir
  tmpdir=$(mktemp -d)
  ln -s "$FIXTURE_DIR/$aws_shim"  "$tmpdir/aws"
  ln -s "$FIXTURE_DIR/$kube_shim" "$tmpdir/kubectl"
  PATH="$tmpdir:$PATH" \
    AWS_REGION="us-east-1" \
    AWS_DEFAULT_REGION="" \
    bash "$SCRIPT" "$@"
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

run_ps_capture() {
  local aws_shim="$1"; shift
  local kube_shim="$1"; shift
  local tmpdir
  tmpdir=$(mktemp -d)
  ln -s "$FIXTURE_DIR/$aws_shim"  "$tmpdir/aws"
  ln -s "$FIXTURE_DIR/$kube_shim" "$tmpdir/kubectl"
  local out
  out=$(PATH="$tmpdir:$PATH" \
    AWS_REGION="us-east-1" \
    AWS_DEFAULT_REGION="" \
    bash "$SCRIPT" "$@" 2>/dev/null)
  local rc=$?
  rm -rf "$tmpdir"
  echo "$out"
  return $rc
}

# 1. default table mode: 7 phase rows numbered 0–6
test_table_has_seven_rows() {
  local out
  out=$(run_ps_capture aws-verified kubectl-verified)
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "test_table_has_seven_rows" "script exited $rc"
    return
  fi
  local count
  count=$(echo "$out" | grep -cE '^[0-6][[:space:]]')
  if [[ $count -eq 7 ]]; then
    pass "test_table_has_seven_rows"
  else
    fail "test_table_has_seven_rows" "expected 7 phase rows, found $count; output: $out"
  fi
}

# 2. headers present
test_table_has_headers() {
  local out
  out=$(run_ps_capture aws-verified kubectl-verified)
  local ok=1
  for h in Phase State Sentinel Functional; do
    if ! echo "$out" | grep -q "$h"; then
      fail "test_table_has_headers" "header '$h' missing"
      ok=0
    fi
  done
  [[ $ok -eq 1 ]] && pass "test_table_has_headers"
}

# 3. JSON has phases.0..phases.6
test_json_keys_present() {
  local out
  out=$(run_ps_capture aws-verified kubectl-verified --json)
  local keys
  keys=$(echo "$out" | jq -r '.phases | keys | join(",")' 2>/dev/null)
  if [[ "$keys" == "0,1,2,3,4,5,6" ]]; then
    pass "test_json_keys_present"
  else
    fail "test_json_keys_present" "expected '0,1,2,3,4,5,6'; got '$keys'; out: $out"
  fi
}

# 4. .account is a non-null string equal to shim's value
test_json_account_redacted() {
  local out
  out=$(run_ps_capture aws-verified kubectl-verified --json)
  local acct
  acct=$(echo "$out" | jq -r '.account' 2>/dev/null)
  if [[ "$acct" == "111122223333" ]]; then
    pass "test_json_account_redacted"
  else
    fail "test_json_account_redacted" "expected '111122223333' (from shim), got '$acct'"
  fi
}

# 5. JSON validates
test_json_is_valid() {
  local out
  out=$(run_ps_capture aws-verified kubectl-verified --json)
  if echo "$out" | jq -e . >/dev/null 2>&1; then
    pass "test_json_is_valid"
  else
    fail "test_json_is_valid" "jq could not parse output: $out"
  fi
}

# 6. --assert-phase 1 verified exits 0
test_assert_phase_match() {
  run_ps aws-verified kubectl-verified --assert-phase 1 verified >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "test_assert_phase_match"
  else
    fail "test_assert_phase_match" "expected exit 0, got $rc"
  fi
}

# 7. --assert-phase 1 applied (state doesn't match) exits 1
test_assert_phase_no_match() {
  run_ps aws-verified kubectl-verified --assert-phase 1 applied >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq 1 ]]; then
    pass "test_assert_phase_no_match"
  else
    fail "test_assert_phase_no_match" "expected exit 1, got $rc"
  fi
}

# 8. --assert-phase 1 <unknown-state> exits 2
test_assert_phase_unknown_state() {
  run_ps aws-verified kubectl-verified --assert-phase 1 banana >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    pass "test_assert_phase_unknown_state"
  else
    fail "test_assert_phase_unknown_state" "expected exit 2, got $rc"
  fi
}

# 9. --assert-phase 99 verified exits 2
test_assert_phase_unknown_number() {
  run_ps aws-verified kubectl-verified --assert-phase 99 verified >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    pass "test_assert_phase_unknown_number"
  else
    fail "test_assert_phase_unknown_number" "expected exit 2, got $rc"
  fi
}

# 10. fail-soft: phase 2 has broken probe; script still exits 0 with all rows
test_fail_soft_on_kubectl_error() {
  local out
  out=$(run_ps_capture aws-verified kubectl-phase2-broken --json)
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "test_fail_soft_on_kubectl_error" "expected exit 0 (fail-soft), got $rc"
    return
  fi
  local state2
  state2=$(echo "$out" | jq -r '.phases."2".state' 2>/dev/null)
  if [[ "$state2" == "applied" ]]; then
    pass "test_fail_soft_on_kubectl_error"
  else
    fail "test_fail_soft_on_kubectl_error" "expected phase 2 state 'applied', got '$state2'"
  fi
}

# 11. no ANSI codes when stdout is a pipe (no TTY)
test_no_color_when_piped() {
  local out
  out=$(run_ps_capture aws-verified kubectl-verified)
  # ANSI escape: \x1b[
  if echo "$out" | grep -q $'\x1b\['; then
    fail "test_no_color_when_piped" "found ANSI escape in piped output"
  else
    pass "test_no_color_when_piped"
  fi
}

# 12. --help exits 0
test_help_exits_0() {
  run_ps aws-verified kubectl-verified --help >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    pass "test_help_exits_0"
  else
    fail "test_help_exits_0" "expected exit 0, got $rc"
  fi
}

# 13. unknown flag exits non-zero
test_unknown_flag_nonzero() {
  run_ps aws-verified kubectl-verified --does-not-exist >/dev/null 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    pass "test_unknown_flag_nonzero"
  else
    fail "test_unknown_flag_nonzero" "expected non-zero exit, got 0"
  fi
}

# 14. empty environment: all phases not-coded or code-only (never verified)
test_all_not_coded_when_empty() {
  local out
  out=$(run_ps_capture aws-empty kubectl-empty --json)
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "test_all_not_coded_when_empty" "expected exit 0, got $rc"
    return
  fi
  local verified_count
  verified_count=$(echo "$out" | jq -r '[.phases[] | select(.state=="verified")] | length' 2>/dev/null)
  if [[ "$verified_count" == "0" ]]; then
    pass "test_all_not_coded_when_empty"
  else
    fail "test_all_not_coded_when_empty" "expected 0 verified phases, got $verified_count; out: $out"
  fi
}

# 15. /tmp/phase-status-*.json snapshot written after --json
test_snapshot_file_written() {
  rm -f /tmp/phase-status-*.json
  run_ps_capture aws-verified kubectl-verified --json >/dev/null
  local count
  count=$(ls /tmp/phase-status-*.json 2>/dev/null | wc -l)
  if [[ "$count" -ge 1 ]]; then
    pass "test_snapshot_file_written"
    rm -f /tmp/phase-status-*.json
  else
    fail "test_snapshot_file_written" "no /tmp/phase-status-*.json created"
  fi
}

test_table_has_seven_rows
test_table_has_headers
test_json_keys_present
test_json_account_redacted
test_json_is_valid
test_assert_phase_match
test_assert_phase_no_match
test_assert_phase_unknown_state
test_assert_phase_unknown_number
test_fail_soft_on_kubectl_error
test_no_color_when_piped
test_help_exits_0
test_unknown_flag_nonzero
test_all_not_coded_when_empty
test_snapshot_file_written

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
