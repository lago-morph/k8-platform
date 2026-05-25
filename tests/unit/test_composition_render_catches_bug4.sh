#!/usr/bin/env bash
# SPEC-S9 §6.2 — assert the helper rejects a Composition with a string
# transform missing `string.type`.
#
# This is the Bug-4-class meta-test: if a future refactor accidentally
# disables the function-input validation path, this test goes red.
#
# Mandatory §6.2 test: it must FAIL against a buggy composition (which
# the synthetic fixture is) and PASS after the fix (i.e. the helper
# correctly reports non-zero). The current repo Composition is fixed,
# so testing against the repo Composition would trivially pass and
# provide no signal — we use the synthetic buggy fixture.
#
# Skip-with-warning when `crossplane` CLI is absent (the meta-test
# depends on real function-input validation).

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

HELPER="scripts/composition-render.sh"
BAD_COMP="tests/unit/fixtures/composition-render/composition-missing-string-type.yaml"
INPUT="crossplane/xrds/platform-secret/render-fixtures/input.yaml"
XRD="crossplane/xrds/platform-secret.yaml"

for f in "$HELPER" "$BAD_COMP" "$INPUT" "$XRD"; do
  if [ ! -f "$f" ]; then
    _fail "bug4_meta_test_prereqs" "missing: $f"
    assert_summary
  fi
done
_pass "bug4_meta_test_prereqs"

if ! command -v crossplane >/dev/null 2>&1; then
  echo "  SKIP: bug4_helper_rejects (crossplane CLI absent)"
  assert_summary
  exit 0
fi

# Wire a temporary fixtures dir that uses the bad Composition.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$INPUT" "$tmp/input.yaml"
# Intentionally no expected.yaml — we want the render path to fire,
# not a diff path. Helper returns 0 in bootstrap mode IF render succeeds,
# so a successful render here would trivially pass.

out=$("$HELPER" --xrd "$XRD" --comp "$BAD_COMP" --fixtures "$tmp" 2>&1)
rc=$?

# Helper MUST exit non-zero (render rejection -> rc=1).
if [ "$rc" -ne 0 ]; then
  _pass "bug4_helper_exits_nonzero"
else
  _fail "bug4_helper_exits_nonzero" "helper returned 0 on a buggy Composition; output:
$out"
fi

# Stderr should mention a function-input rejection — common phrases
# from function-patch-and-transform's validation include "Required
# value", "string transform type", "fatal result", "invalid Function
# input". Accept any of them so the test does not over-fit a phrase.
if echo "$out" | grep -qiE 'Required value|string transform type|fatal result|invalid Function input'; then
  _pass "bug4_helper_stderr_mentions_function_rejection"
else
  _fail "bug4_helper_stderr_mentions_function_rejection" "expected one of the function-rejection phrases; got:
$out"
fi

assert_summary
