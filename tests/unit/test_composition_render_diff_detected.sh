#!/usr/bin/env bash
# SPEC-S9 §6.3 — assert the helper exits non-zero when the rendered
# output diverges from the committed expected.yaml.
#
# Mutates the real PlatformSecret Composition in a temp copy (changes
# `fmt: "k8-platform/%s/%s"` to `fmt: "wrong/%s/%s"`), runs the helper
# against the unchanged golden, asserts exit non-zero. Proves the
# golden-file diff path actually fires — without this test a future
# regression that disabled the diff entirely would silently pass.
#
# Skip-with-warning when `crossplane` CLI is absent OR when
# expected.yaml has not been bootstrapped yet (we need both to test
# the diff path).

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

HELPER="scripts/composition-render.sh"
XRD="crossplane/xrds/platform-secret.yaml"
COMP="crossplane/compositions/platform-secret.yaml"
FIXTURES="crossplane/xrds/platform-secret/render-fixtures"

for f in "$HELPER" "$XRD" "$COMP" "$FIXTURES/input.yaml"; do
  if [ ! -e "$f" ]; then
    _fail "diff_detected_prereqs" "missing: $f"
    assert_summary
  fi
done
_pass "diff_detected_prereqs"

if ! command -v crossplane >/dev/null 2>&1; then
  echo "  SKIP: diff_helper_exits_nonzero (crossplane CLI absent)"
  assert_summary
  exit 0
fi

if [ ! -s "$FIXTURES/expected.yaml" ]; then
  echo "  SKIP: diff_helper_exits_nonzero (expected.yaml not yet bootstrapped)"
  assert_summary
  exit 0
fi

# Mutate Composition in a temp copy.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed 's|fmt: "k8-platform/%s/%s"|fmt: "wrong/%s/%s"|g' "$COMP" >"$tmp/composition.yaml"

# Sanity-check the mutation actually changed something.
if cmp -s "$COMP" "$tmp/composition.yaml"; then
  _fail "diff_test_mutation_applied" "sed produced an identical file — fmt pattern not present?"
  assert_summary
fi
_pass "diff_test_mutation_applied"

out=$("$HELPER" --xrd "$XRD" --comp "$tmp/composition.yaml" --fixtures "$FIXTURES/" 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then
  _pass "diff_helper_exits_nonzero"
else
  _fail "diff_helper_exits_nonzero" "helper returned 0 on a mutated Composition; output:
$out"
fi

assert_summary
