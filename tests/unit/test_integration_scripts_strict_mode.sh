#!/usr/bin/env bash
# Lint: every tests/integration/NN_*.sh must enable strict-mode `set -e`
# so that a failing wait_for/ng/command aborts the script.
#
# Bug-of-record: tests/integration/11_platform_secret_e2e.sh used
#   set -uo pipefail
# without -e. wait_for returns 1 on timeout (and prints "✗ ... gave
# up after Ns") but the very next line in the script — typically
#   ok "<thing>"
# runs unconditionally and prints "PASS:". The whole script then walks
# to the end and exits 0, masking real assertion failures. Bug-of-record
# run: 26347839740 reported PASS on the final summary line even though
# 4 earlier `wait_for` calls timed out and the K8s Secret never
# materialized.
#
# Strict mode (`set -e`) makes wait_for failures abort, which is what
# every assert-shaped integration scenario must do.

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

bad=0
for script in tests/integration/[0-9][0-9]_*.sh; do
  [ -f "$script" ] || continue
  base=$(basename "$script")

  # The strict-mode line is one of:
  #   set -e
  #   set -eu
  #   set -euo pipefail
  #   set -e -u -o pipefail
  # i.e. an unconditional `set` invocation containing `-e` (possibly
  # combined with other letters). Reject the lazy variant `set -uo
  # pipefail` because that's exactly the bug pattern.
  if grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$script"; then
    _pass "integration_strict_mode:$base"
  else
    _fail "integration_strict_mode:$base" \
      "missing 'set -e' — wait_for/ng failures will not abort the script"
    bad=$((bad+1))
  fi
done

if [ "$bad" -eq 0 ]; then
  _pass "all_integration_scripts_strict"
fi

assert_summary
