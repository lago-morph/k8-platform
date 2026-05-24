#!/usr/bin/env bash
# Lint: no script under our tree assigns to the bash readonly variable $UID.
#
# Bug-of-record: tests/integration/11_platform_secret_e2e.sh line 78 did
#   UID=$(kubectl get xplatformsecret "$XR" -o jsonpath='{.metadata.uid}')
# Bash refuses the assignment because $UID is a readonly builtin (set to
# the process's real user id). Under `set -u` this prints
#   line 78: UID: readonly variable
# to stderr, the assignment silently fails, and $UID retains its prior
# value (1001 on Actions runners under cloud_user). The downstream code
# then constructed ASM_KEY="k8-platform/1001" instead of the actual XR
# UID, every claim collided on the same ASM key, and the test's
# wait_for/put-value/expect-value steps all failed silently because the
# script lacks set -e (separately defended by test_set_e_required.sh).
#
# Bug-of-record run: 26347839740 (lago-morph/k8-platform).
#
# Other readonly bash specials are documented at
# https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
# — we only defend UID here because it's the one we actually misused.
# Add EUID, BASHPID, etc. if we ever hit them.

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

# Scan every script we own that could plausibly assign vars.
mapfile -t scripts < <(find tests scripts -type f \( -name '*.sh' -o -name 'run.sh' \) | sort)

bad=0
for script in "${scripts[@]}"; do
  # Skip this test file itself (mentions the pattern in comments).
  base=$(basename "$script")
  [ "$base" = "test_shell_readonly_var_assignment.sh" ] && continue

  # Match a real assignment `UID=...` at the start of a line (or after
  # whitespace), excluding comment lines. Use grep -P-style with grep -E.
  if grep -nE '^[[:space:]]*UID=' "$script" | grep -vE '^[^:]+:[[:space:]]*#'; then
    _fail "no_uid_assignment:$script" "assignment to readonly bash variable UID — rename"
    bad=$((bad+1))
  fi
done

if [ "$bad" -eq 0 ]; then
  _pass "no_readonly_bash_var_assignment"
fi

assert_summary
