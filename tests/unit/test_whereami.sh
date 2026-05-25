#!/usr/bin/env bash
# Unit tests for scripts/whereami.sh and scripts/_lib/aws-cli-helpers.sh
#
# All tests use fixture shim binaries in tests/unit/fixtures/whereami/ to
# override the PATH — no AWS credentials or live cluster required.
# Runtime: <5 seconds.
#
# Test cases (per SPEC-S4 §6 and adversarial review):
#   1. test_whereami_json_schema         — --json output has all 7 keys
#   2. test_whereami_human_fields        — human output has all 7 field labels
#   3. test_whereami_fixture_match       — --json matches expected.json fixture
#   4. test_whereami_cache_file          — --cache creates sourceable /tmp/session.env
#   5. test_whereami_no_creds_exits_1    — missing AWS creds → exit 1 + stderr "credentials"
#   6. test_whereami_partial_kubectl     — kubectl fail → exit 0, all 7 JSON keys present
#   7. test_whereami_no_null_values      — no JSON value is the literal string "null"
#   8. test_whereami_help_exits_0        — --help exits 0
#   9. test_lib_direct_exec_fails        — aws-cli-helpers.sh exits 2 when executed directly
#  10. test_whereami_cache_var_names     — /tmp/session.env has correct KEY names

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/unit/fixtures/whereami"
SCRIPT="$REPO_ROOT/scripts/whereami.sh"
LIB="$REPO_ROOT/scripts/_lib/aws-cli-helpers.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Helper: run whereami with fixture shims on PATH
run_whereami() {
  # $1 = aws shim name (relative to FIXTURE_DIR), e.g. "aws" or "aws-fail"
  # $2 = kubectl shim name, e.g. "kubectl" or "kubectl-fail"
  # remaining args forwarded to whereami.sh
  local aws_shim="$1"; shift
  local kube_shim="$1"; shift

  # Build a temp dir with symlinks so we can use arbitrary shim names as "aws"/"kubectl"
  local tmpdir
  tmpdir=$(mktemp -d)
  ln -s "$FIXTURE_DIR/$aws_shim"  "$tmpdir/aws"
  ln -s "$FIXTURE_DIR/$kube_shim" "$tmpdir/kubectl"

  # Unset environment variables that might influence region resolution
  PATH="$tmpdir:$PATH" \
    AWS_REGION="us-east-1" \
    AWS_DEFAULT_REGION="" \
    bash "$SCRIPT" "$@"
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

# Same as run_whereami but captures stdout
run_whereami_capture() {
  local aws_shim="$1"; shift
  local kube_shim="$1"; shift

  local tmpdir
  tmpdir=$(mktemp -d)
  ln -s "$FIXTURE_DIR/$aws_shim"  "$tmpdir/aws"
  ln -s "$FIXTURE_DIR/$kube_shim" "$tmpdir/kubectl"

  local output
  output=$(PATH="$tmpdir:$PATH" \
    AWS_REGION="us-east-1" \
    AWS_DEFAULT_REGION="" \
    bash "$SCRIPT" "$@" 2>/dev/null)
  local rc=$?
  rm -rf "$tmpdir"
  echo "$output"
  return $rc
}

# ---------------------------------------------------------------------------
# 1. JSON schema: all 7 keys present
# ---------------------------------------------------------------------------
test_whereami_json_schema() {
  local output
  output=$(run_whereami_capture aws kubectl --json) || {
    fail "test_whereami_json_schema" "script exited non-zero"
    return
  }
  if echo "$output" | jq -e '
    has("account") and
    has("region") and
    has("eksCluster") and
    has("zone") and
    has("kubectlCtx") and
    has("argoCdUrl") and
    has("crossplaneVersion")
  ' >/dev/null 2>&1; then
    pass "test_whereami_json_schema"
  else
    fail "test_whereami_json_schema" "missing one or more required keys; got: $output"
  fi
}

# ---------------------------------------------------------------------------
# 2. Human mode: all 7 field labels present
# ---------------------------------------------------------------------------
test_whereami_human_fields() {
  local output
  output=$(run_whereami_capture aws kubectl) || {
    fail "test_whereami_human_fields" "script exited non-zero"
    return
  }
  local ok=1
  for label in account region eks-cluster zone kubectl-ctx argocd-url crossplane; do
    if ! echo "$output" | grep -qE "^\s+${label}\s"; then
      fail "test_whereami_human_fields" "label '$label' not found in output"
      ok=0
    fi
  done
  [[ $ok -eq 1 ]] && pass "test_whereami_human_fields"
}

# ---------------------------------------------------------------------------
# 3. Fixture match: --json output matches expected.json field-for-field
# ---------------------------------------------------------------------------
test_whereami_fixture_match() {
  local output
  output=$(run_whereami_capture aws kubectl --json) || {
    fail "test_whereami_fixture_match" "script exited non-zero"
    return
  }
  local expected_file="$FIXTURE_DIR/expected.json"
  # Compare field by field using jq
  local all_match=1
  for key in account region eksCluster zone kubectlCtx argoCdUrl crossplaneVersion; do
    local got expected
    got=$(echo "$output" | jq -r ".$key" 2>/dev/null)
    expected=$(jq -r ".$key" "$expected_file" 2>/dev/null)
    if [[ "$got" != "$expected" ]]; then
      fail "test_whereami_fixture_match" "key '$key': got='$got', expected='$expected'"
      all_match=0
    fi
  done
  [[ $all_match -eq 1 ]] && pass "test_whereami_fixture_match"
}

# ---------------------------------------------------------------------------
# 4. --cache mode: writes /tmp/session.env; file is sourceable
# ---------------------------------------------------------------------------
test_whereami_cache_file() {
  rm -f /tmp/session.env
  run_whereami_capture aws kubectl --cache >/dev/null || {
    fail "test_whereami_cache_file" "script exited non-zero"
    return
  }
  if [[ ! -f /tmp/session.env ]]; then
    fail "test_whereami_cache_file" "/tmp/session.env was not created"
    return
  fi
  # File must be sourceable without error
  if ! bash -c ". /tmp/session.env" 2>/dev/null; then
    fail "test_whereami_cache_file" "/tmp/session.env is not sourceable"
    return
  fi
  pass "test_whereami_cache_file"
}

# ---------------------------------------------------------------------------
# 5. Missing creds: script exits 1; stderr contains "credentials"
# ---------------------------------------------------------------------------
test_whereami_no_creds_exits_1() {
  local tmpdir
  tmpdir=$(mktemp -d)
  ln -s "$FIXTURE_DIR/aws-fail"     "$tmpdir/aws"
  ln -s "$FIXTURE_DIR/kubectl"      "$tmpdir/kubectl"

  local stderr_out
  stderr_out=$(PATH="$tmpdir:$PATH" AWS_REGION="us-east-1" AWS_DEFAULT_REGION="" \
    bash "$SCRIPT" --json 2>&1 >/dev/null) || true
  local rc
  PATH="$tmpdir:$PATH" AWS_REGION="us-east-1" AWS_DEFAULT_REGION="" \
    bash "$SCRIPT" --json >/dev/null 2>/dev/null
  rc=$?
  rm -rf "$tmpdir"

  if [[ $rc -ne 1 ]]; then
    fail "test_whereami_no_creds_exits_1" "expected exit 1, got $rc"
    return
  fi
  if ! echo "$stderr_out" | grep -qi "credentials"; then
    fail "test_whereami_no_creds_exits_1" "stderr did not contain 'credentials'; got: $stderr_out"
    return
  fi
  pass "test_whereami_no_creds_exits_1"
}

# ---------------------------------------------------------------------------
# 6. Partial availability: kubectl fails → exit 0, all 7 JSON keys present
# ---------------------------------------------------------------------------
test_whereami_partial_kubectl() {
  local output
  output=$(run_whereami_capture aws kubectl-fail --json) || {
    fail "test_whereami_partial_kubectl" "script exited non-zero (expected 0 when only kubectl fails)"
    return
  }
  if echo "$output" | jq -e '
    has("account") and
    has("region") and
    has("eksCluster") and
    has("zone") and
    has("kubectlCtx") and
    has("argoCdUrl") and
    has("crossplaneVersion")
  ' >/dev/null 2>&1; then
    pass "test_whereami_partial_kubectl"
  else
    fail "test_whereami_partial_kubectl" "missing keys in partial output; got: $output"
  fi
}

# ---------------------------------------------------------------------------
# 7. No null values in JSON: all values must be strings (empty string OK)
# ---------------------------------------------------------------------------
test_whereami_no_null_values() {
  local output
  output=$(run_whereami_capture aws kubectl --json) || {
    fail "test_whereami_no_null_values" "script exited non-zero"
    return
  }
  if echo "$output" | jq -e 'to_entries | map(.value != null) | all' >/dev/null 2>&1; then
    pass "test_whereami_no_null_values"
  else
    fail "test_whereami_no_null_values" "one or more JSON values are null; output: $output"
  fi
}

# ---------------------------------------------------------------------------
# 8. --help exits 0
# ---------------------------------------------------------------------------
test_whereami_help_exits_0() {
  local tmpdir
  tmpdir=$(mktemp -d)
  ln -s "$FIXTURE_DIR/aws"     "$tmpdir/aws"
  ln -s "$FIXTURE_DIR/kubectl" "$tmpdir/kubectl"

  PATH="$tmpdir:$PATH" AWS_REGION="us-east-1" AWS_DEFAULT_REGION="" \
    bash "$SCRIPT" --help >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmpdir"

  if [[ $rc -eq 0 ]]; then
    pass "test_whereami_help_exits_0"
  else
    fail "test_whereami_help_exits_0" "--help exited $rc (expected 0)"
  fi
}

# ---------------------------------------------------------------------------
# 9. aws-cli-helpers.sh exits 2 when executed directly
# ---------------------------------------------------------------------------
test_lib_direct_exec_fails() {
  bash "$LIB" >/dev/null 2>&1
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    pass "test_lib_direct_exec_fails"
  else
    fail "test_lib_direct_exec_fails" "direct execution exited $rc (expected 2)"
  fi
}

# ---------------------------------------------------------------------------
# 10. --cache produces correct KEY names in /tmp/session.env
# ---------------------------------------------------------------------------
test_whereami_cache_var_names() {
  rm -f /tmp/session.env
  run_whereami_capture aws kubectl --cache >/dev/null || {
    fail "test_whereami_cache_var_names" "script exited non-zero"
    return
  }
  if [[ ! -f /tmp/session.env ]]; then
    fail "test_whereami_cache_var_names" "/tmp/session.env not created"
    return
  fi
  local ok=1
  for varname in ACCOUNT REGION EKS_CLUSTER ZONE KUBECTL_CTX ARGOCD_URL CROSSPLANE_VERSION; do
    if ! grep -q "^${varname}=" /tmp/session.env; then
      fail "test_whereami_cache_var_names" "missing variable $varname in /tmp/session.env"
      ok=0
    fi
  done
  [[ $ok -eq 1 ]] && pass "test_whereami_cache_var_names"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_whereami_json_schema
test_whereami_human_fields
test_whereami_fixture_match
test_whereami_cache_file
test_whereami_no_creds_exits_1
test_whereami_partial_kubectl
test_whereami_no_null_values
test_whereami_help_exits_0
test_lib_direct_exec_fails
test_whereami_cache_var_names

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
