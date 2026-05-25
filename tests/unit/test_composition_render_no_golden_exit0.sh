#!/usr/bin/env bash
# SPEC-S9 §7 unit-test #4 — bootstrap mode: helper exits 0 when
# expected.yaml is absent. Proves the bootstrap path (used to generate
# the initial golden file) doesn't surprise the author with a
# non-zero exit.
#
# Skip-with-warning when `crossplane` CLI is absent.

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

HELPER="scripts/composition-render.sh"
XRD="crossplane/xrds/platform-secret.yaml"
COMP="crossplane/compositions/platform-secret.yaml"
INPUT="crossplane/xrds/platform-secret/render-fixtures/input.yaml"

for f in "$HELPER" "$XRD" "$COMP" "$INPUT"; do
  if [ ! -f "$f" ]; then
    _fail "no_golden_prereqs" "missing: $f"
    assert_summary
  fi
done
_pass "no_golden_prereqs"

if ! command -v crossplane >/dev/null 2>&1; then
  echo "  SKIP: no_golden_exit0 (crossplane CLI absent)"
  assert_summary
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$INPUT" "$tmp/input.yaml"
# No expected.yaml in $tmp — that's the point.

out=$("$HELPER" --xrd "$XRD" --comp "$COMP" --fixtures "$tmp" 2>&1)
rc=$?

if [ "$rc" -eq 0 ]; then
  _pass "no_golden_helper_exit0"
else
  _fail "no_golden_helper_exit0" "helper returned $rc on missing expected.yaml; output:
$out"
fi

# Should mention the bootstrap hint in stderr.
if echo "$out" | grep -q "expected.yaml"; then
  _pass "no_golden_bootstrap_hint"
else
  _fail "no_golden_bootstrap_hint" "expected 'expected.yaml' string in helper output; got:
$out"
fi

assert_summary
