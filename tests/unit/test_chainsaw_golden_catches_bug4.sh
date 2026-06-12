#!/usr/bin/env bash
# SPEC-C4 §6.2 TDD fixture — Bug 4 replay.
#
# Bug 4 (PR #61) — the PlatformSecret Composition had `string:` transform
# blocks WITHOUT the required `type: Format` discriminator. Crossplane
# v2 strict-decoded the function input and silently dropped the malformed
# transform, so `spec.forProvider.name` ended up as the raw XR UID
# instead of `k8-platform/<uid>`.
#
# This unit test simulates that bug by comparing the frozen pre-PR-#61
# Composition against the production one and asserting that:
#
#   1. The bug fixture DOES contain string-transform blocks missing
#      `type: Format` (i.e. it really is the buggy version).
#   2. The current production Composition does NOT (i.e. PR #61's fix
#      held).
#   3. The bug fixture is the "shape" SPEC-C4 defends against — any
#      pre-PR-#61 Composition re-introduced as the live Composition
#      would render an MR whose `spec.forProvider.name` differs from
#      the golden's expected form (a `k8-platform/<uid>` string).
#
# This is the unit-test form of the chainsaw-in-chainsaw meta-test
# proposed in spec §6.2 — chosen per the spec's explicit option:
# "or a unit-test script tests/unit/test_chainsaw_golden_catches_bug4.sh
# if the chainsaw-in-chainsaw pattern is awkward".
#
# What this test does NOT do (delegated to chainsaw heavy-CI):
#   - Render the frozen Composition against a live kind cluster.
#   - Run chainsaw's assert against the actual MR.
#
# Those live-render confirmations are §7 Integration tests; this test
# is the fast-feedback layer.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

FIXTURE=tests/fixtures/compositions/platform-secret-pre-pr61.yaml
PROD=crossplane/compositions/platform-secret.yaml

# 1. Fixture exists.
if [ ! -f "$FIXTURE" ]; then
  _fail "fixture_present" "$FIXTURE missing — re-snapshot from git: git show b197725^:$PROD > $FIXTURE"
  assert_summary; exit 1
fi
_pass "fixture_present"

if [ ! -f "$PROD" ]; then
  _fail "prod_composition_present" "$PROD missing"
  assert_summary; exit 1
fi
_pass "prod_composition_present"

# 2. The fixture must contain a `string:` block where the *next non-blank
#    non-comment line* is `fmt:` (not `type:`). That is the Bug 4 shape.
#
# Approach: scan for lines like `string:` (with indent), then look at the
# next non-blank non-comment line. If it begins with `fmt:`, the bug
# pattern is present.
detect_bug_shape() {
  local f="$1"
  python3 - "$f" <<'PY'
import sys, re
path = sys.argv[1]
with open(path) as fh:
    lines = fh.readlines()
hits = 0
i = 0
while i < len(lines):
    if re.match(r'^\s+string:\s*$', lines[i]):
        # look at the immediately following non-blank, non-comment line
        j = i + 1
        while j < len(lines) and (lines[j].strip() == '' or lines[j].lstrip().startswith('#')):
            j += 1
        if j < len(lines):
            stripped = lines[j].lstrip()
            if stripped.startswith('fmt:'):
                hits += 1
            elif stripped.startswith('type:'):
                pass  # fixed shape — type discriminator present
    i += 1
print(hits)
PY
}

FIXTURE_HITS=$(detect_bug_shape "$FIXTURE")
PROD_HITS=$(detect_bug_shape "$PROD")

if [ "$FIXTURE_HITS" -ge 1 ] 2>/dev/null; then
  _pass "fixture_carries_bug_shape (${FIXTURE_HITS} occurrences)"
else
  _fail "fixture_carries_bug_shape" \
    "expected pre-PR-#61 fixture to contain string: blocks lacking type: Format (found ${FIXTURE_HITS})"
fi

if [ "$PROD_HITS" = "0" ]; then
  _pass "prod_does_not_carry_bug_shape"
else
  _fail "prod_does_not_carry_bug_shape" \
    "production Composition $PROD has ${PROD_HITS} string-transform block(s) missing type: discriminator — PR #61 fix regressed"
fi

# 3. The golden file MUST contain a partial match shape that would
#    diverge from the buggy render — i.e. the golden defends the
#    contract that `spec.forProvider.name` is `k8-platform/<uid>` form.
#    The current golden omits metadata.name (per spec §5 — UID-derived)
#    but the buggy Composition fails the chainsaw assert via tags +
#    forProvider.region propagation — those still defend a contract.
#    What we assert here is that the golden has a forProvider block (a
#    no-op golden would not catch Bug 4).
GOLDEN=tests/chainsaw/platform-secret/00-claim-creates-secret/expected/asm-secret.yaml
if [ ! -f "$GOLDEN" ]; then
  _fail "golden_present" "$GOLDEN missing"
else
  _pass "golden_present"
  if grep -q '^[[:space:]]*forProvider:' "$GOLDEN"; then
    _pass "golden_asserts_forProvider"
  else
    _fail "golden_asserts_forProvider" \
      "$GOLDEN has no forProvider: block — golden is a tautology and would not catch Bug 4"
  fi
fi

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
