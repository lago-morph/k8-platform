#!/usr/bin/env bash
# Shared helpers for unit-test scripts. Pure bash, no AWS, no cluster.
# Source from each test_*.sh:  . "$(dirname "$0")/lib/test-helpers.sh"

set -uo pipefail

# ---- result tracking -----------------------------------------------------
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

# pass <name>
pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "  PASS: $1"
}

# fail <name> [detail]
fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_NAMES+=("$1")
  echo "  FAIL: $1"
  [ $# -ge 2 ] && echo "        $2"
}

# summary — exit 0 if all green
summary() {
  echo ""
  echo "── results: $TESTS_PASSED/$TESTS_RUN passed"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "── failed:"
    for n in "${FAILED_NAMES[@]}"; do echo "     - $n"; done
    exit 1
  fi
  exit 0
}

# ---- assertion primitives ------------------------------------------------

# assert_yq_eq <file> <yq-expr> <expected> <name>
# Runs yq on file with the multi-doc-aware expression and compares output.
assert_yq_eq() {
  local file="$1" expr="$2" expected="$3" name="$4"
  local got
  got=$(yq eval-all "$expr" "$file" 2>&1 || true)
  if [ "$got" = "$expected" ]; then
    pass "$name"
  else
    fail "$name" "expr=$expr  got=$got  want=$expected"
  fi
}

# assert_yq_matches <file> <yq-expr> <regex> <name>
assert_yq_matches() {
  local file="$1" expr="$2" pattern="$3" name="$4"
  local got
  got=$(yq eval-all "$expr" "$file" 2>&1 || true)
  if echo "$got" | grep -qE "$pattern"; then
    pass "$name"
  else
    fail "$name" "expr=$expr  got=$got  want=~$pattern"
  fi
}

# assert_yq_nonempty <file> <yq-expr> <name>
assert_yq_nonempty() {
  local file="$1" expr="$2" name="$3"
  local got
  got=$(yq eval-all "$expr" "$file" 2>&1 || true)
  if [ -n "$got" ] && [ "$got" != "null" ] && [ "$got" != "---" ]; then
    pass "$name"
  else
    fail "$name" "expr=$expr returned empty/null"
  fi
}

# assert_grep <pattern> <file> <name>
assert_grep() {
  local pattern="$1" file="$2" name="$3"
  if grep -qE "$pattern" "$file"; then
    pass "$name"
  else
    fail "$name" "pattern=$pattern not found in $file"
  fi
}

# assert_not_grep <pattern> <file> <name>
assert_not_grep() {
  local pattern="$1" file="$2" name="$3"
  if grep -qE "$pattern" "$file"; then
    fail "$name" "pattern=$pattern unexpectedly found in $file"
  else
    pass "$name"
  fi
}

# ---- helm helpers --------------------------------------------------------

# helm_render <repo> <chart> <version> <output-file> <set-args...>
# Runs `helm template release-name chart --repo repo --version version --set k=v ...`
# Writes rendered multi-doc YAML to <output-file>.
# Returns non-zero if helm itself failed.
helm_render() {
  local repo="$1" chart="$2" version="$3" out="$4"
  shift 4
  local set_args=()
  for kv in "$@"; do
    set_args+=("--set" "$kv")
  done
  helm template "$chart" "$chart" \
    --repo "$repo" \
    --version "$version" \
    --namespace "$chart" \
    "${set_args[@]}" \
    > "$out" 2> "${out}.err"
}

# ---- preflight ----------------------------------------------------------

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "REQUIRED TOOL MISSING: $tool"
    echo "  Install: $tool  (helm: https://helm.sh, yq: https://github.com/mikefarah/yq)"
    exit 2
  fi
}
