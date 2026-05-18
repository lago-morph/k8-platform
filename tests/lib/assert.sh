# Shared assertion helpers for tests/unit and tests/e2e.
#
# Source this file at the top of test scripts:
#   . "$(dirname "$0")/../lib/assert.sh"
#
# Helpers maintain three globals:
#   TESTS_PASSED, TESTS_FAILED — counters
#   FAILED_NAMES               — newline-separated names of failed tests
#
# Call `assert_summary` at end of suite; it exits non-zero if any failed.

: "${TESTS_PASSED:=0}"
: "${TESTS_FAILED:=0}"
: "${FAILED_NAMES:=}"

_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "  ✓ $1"
}

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_NAMES="${FAILED_NAMES}${1}
"
  echo "  ✗ $1"
  [ -n "${2:-}" ] && echo "    $2"
}

# assert_eq <name> <expected> <actual>
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$name"
  else
    _fail "$name" "expected: $(printf '%q' "$expected") | actual: $(printf '%q' "$actual")"
  fi
}

# assert_contains <name> <needle> <haystack>
assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    _pass "$name"
  else
    _fail "$name" "expected to contain: $(printf '%q' "$needle") | got: $(printf '%q' "$haystack")"
  fi
}

# assert_exit_code <name> <expected-code> <cmd...>
assert_exit_code() {
  local name="$1" expected="$2"; shift 2
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [ "$actual" = "$expected" ]; then
    _pass "$name"
  else
    _fail "$name" "expected exit $expected | got $actual from: $*"
  fi
}

assert_summary() {
  echo ""
  echo "──────────────────────────────────────────"
  echo "Passed: $TESTS_PASSED   Failed: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    echo ""
    echo "Failures:"
    printf '%s' "$FAILED_NAMES" | sed 's/^/  - /'
    return 1
  fi
}
