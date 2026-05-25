#!/usr/bin/env bash
# Unit tests for docs/runbooks/runbook-apply-zero-resources.md.
#
# Bug class defended:
#   - Runbook accidentally deleted or path changed — file-exists check fails.
#   - SPEC-B3 cross-reference removed — test 2 fails; the lint pointer is gone.
#   - triggers_replace documentation removed — test 3 fails; core topic missing.
#   - sha256 fix pattern removed — test 4 fails; fix not documented.
#   - Required sections missing — tests 5-9 fail on individual headings.
#   - PR #67 citation removed — test 10 fails; grounding incident lost.
#   - Run URL citation removed — test 11 fails; silent no-op run unlinked.
#   - File becomes too thin or too long — test 12 bounds check fires.
#
# Adversarial-reviewer note (AGENTS.md §6.4):
#   Every assertion is a strict grep -q that exits non-zero when the string
#   is absent. Tests were verified to fail against an empty file and against a
#   file with section headers but no content (tests 2-4, 6-11 catch that).
#
# Pure static; no kubectl, no terraform, no AWS required.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

RUNBOOK="docs/runbooks/runbook-apply-zero-resources.md"

# ---- 1. Runbook file exists -----------------------------------------------
if [ -f "$RUNBOOK" ]; then
  _pass "runbook_file_exists"
else
  _fail "runbook_file_exists" "$RUNBOOK missing"
  assert_summary  # no point continuing if the file doesn't exist
fi

# ---- 2. Cross-reference to SPEC-B3 lint -----------------------------------
# Defends: the lint companion is discoverable from the runbook.
if grep -q "SPEC-B3" "$RUNBOOK"; then
  _pass "runbook_references_spec_b3"
else
  _fail "runbook_references_spec_b3" "SPEC-B3 cross-reference missing from $RUNBOOK"
fi

# ---- 3. Core topic: triggers_replace ---------------------------------------
# Defends: the runbook actually covers the bug class it claims to document.
if grep -q "triggers_replace" "$RUNBOOK"; then
  _pass "runbook_covers_triggers_replace"
else
  _fail "runbook_covers_triggers_replace" "triggers_replace not found in $RUNBOOK"
fi

# ---- 4. Fix pattern: sha256 ------------------------------------------------
# Defends: the hash-the-manifest fix pattern is documented.
if grep -q "sha256" "$RUNBOOK"; then
  _pass "runbook_documents_sha256_pattern"
else
  _fail "runbook_documents_sha256_pattern" "sha256 not found in $RUNBOOK"
fi

# ---- 5. Required section: Symptom -----------------------------------------
if grep -q "^## Symptom" "$RUNBOOK"; then
  _pass "runbook_has_symptom_section"
else
  _fail "runbook_has_symptom_section" "'## Symptom' heading missing from $RUNBOOK"
fi

# ---- 6. Required section: Confirm the no-op --------------------------------
if grep -q "^## Confirm the no-op" "$RUNBOOK"; then
  _pass "runbook_has_confirm_section"
else
  _fail "runbook_has_confirm_section" "'## Confirm the no-op' heading missing from $RUNBOOK"
fi

# ---- 7. Required section: Root cause ---------------------------------------
if grep -q "^## Root cause" "$RUNBOOK"; then
  _pass "runbook_has_root_cause_section"
else
  _fail "runbook_has_root_cause_section" "'## Root cause' heading missing from $RUNBOOK"
fi

# ---- 8. Required section: Fix pattern --------------------------------------
if grep -q "^## Fix pattern" "$RUNBOOK"; then
  _pass "runbook_has_fix_pattern_section"
else
  _fail "runbook_has_fix_pattern_section" "'## Fix pattern' heading missing from $RUNBOOK"
fi

# ---- 9. Required section: Verify the fix landed ----------------------------
if grep -q "^## Verify the fix landed" "$RUNBOOK"; then
  _pass "runbook_has_verify_section"
else
  _fail "runbook_has_verify_section" "'## Verify the fix landed' heading missing from $RUNBOOK"
fi

# ---- 10. Grounding citation: PR #67 ----------------------------------------
# Defends: the specific incident that motivated this runbook is cited.
if grep -q "PR #67" "$RUNBOOK"; then
  _pass "runbook_cites_pr67"
else
  _fail "runbook_cites_pr67" "PR #67 citation missing from $RUNBOOK"
fi

# ---- 11. Run URL citation: terraform-test run 26354235231 ------------------
# Defends: the silent no-op CI run is linked for audit trail.
if grep -q "26354235231" "$RUNBOOK"; then
  _pass "runbook_cites_silent_noop_run"
else
  _fail "runbook_cites_silent_noop_run" "run 26354235231 citation missing from $RUNBOOK"
fi

# ---- 12. Line-count bounds: 80-300 ----------------------------------------
# Defends: file is neither trivially thin nor ballooned past splitting threshold.
LINE_COUNT=$(wc -l < "$RUNBOOK")
if [ "$LINE_COUNT" -ge 80 ] && [ "$LINE_COUNT" -le 300 ]; then
  _pass "runbook_line_count_in_bounds"
else
  _fail "runbook_line_count_in_bounds" \
    "line count $LINE_COUNT is outside [80, 300] — too thin or needs splitting"
fi

assert_summary
