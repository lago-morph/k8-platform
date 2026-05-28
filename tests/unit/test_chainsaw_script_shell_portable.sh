#!/usr/bin/env bash
# Chainsaw runs `script.content:` blocks under /bin/sh (POSIX shell, dash
# on Ubuntu). bash-isms like `set -o pipefail`, `set -euo pipefail`,
# `[[ ... ]]`, `((...))`, `<<<`, etc. fail with `sh: Illegal option`.
#
# This test scans every chainsaw scenario YAML for the most common
# bash-only construct (`set -.*pipefail`) and asserts none appear in
# script: content: blocks. It is the regression test for the bug
# surfaced by chainsaw run 26545542710 (3 scenarios failed at the first
# script: step with "sh: 1: set: Illegal option -o pipefail").

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

FILES=$(
  find tests/chainsaw -name 'chainsaw-test.yaml' -type f 2>/dev/null | sort
)

if [ -z "$FILES" ]; then
  _fail "scenarios_discovered" "no chainsaw-test.yaml files found"
  assert_summary; exit 1
fi
_pass "scenarios_discovered ($(echo "$FILES" | wc -l | tr -d ' ') file(s))"

# Pattern: `set -... pipefail` appears anywhere as a non-comment line.
# Comments (`# ... pipefail ...`) are exempt; only assertions on bare
# shell `set` statements are flagged.
while IFS= read -r f; do
  # Strip YAML comments (lines starting with `#`) before scanning. The
  # comments allowed to mention pipefail (e.g. "pipefail is bash-only")
  # without triggering this test.
  bad=$(sed 's/#.*$//' "$f" | grep -nE '^\s*set\s+-[a-z]*o[a-z]*\s+pipefail' || true)
  if [ -n "$bad" ]; then
    _fail "no_pipefail_${f}" "found 'set -o pipefail' (bash-only) in $f — chainsaw runs scripts under /bin/sh. Use 'set -eu' instead. Lines: $(echo "$bad" | tr '\n' '|')"
  else
    _pass "no_pipefail_${f}"
  fi
done <<< "$FILES"

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
