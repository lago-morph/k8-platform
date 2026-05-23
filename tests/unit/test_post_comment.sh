#!/usr/bin/env bash
# Unit tests for .github/scripts/post-comment.py.
#
# post-comment.py keeps two parallel structures (OUTCOMES and STEP_LABELS)
# plus a literal list of section(...) calls in build_body. All three must
# stay in sync; drift produces a KeyError at the worst possible time —
# when the CI summary is being posted on a failed run, masking the real
# failure cause.
#
# The script reads env vars at module-import time, so every scenario runs
# in its own subprocess with a fresh process env.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

# Minimum env required for the module to import without KeyError on os.environ[...]
MIN_ENV=(
  "RUNNER_TEMP=/tmp"
  "GITHUB_REPOSITORY=lago-morph/k8-platform"
  "GITHUB_SHA=0000000000000000000000000000000000000000"
  "GITHUB_REF_NAME=main"
  "GITHUB_EVENT_NAME=workflow_dispatch"
  "GH_TOKEN=dummy"
)

# run_py <name> <expect-rc> <extra-env...> -- <python-code>
#
# Runs python3 in a clean subprocess with MIN_ENV + extra envs, executing
# the given inline python. Reports pass/fail on whether rc matches
# expect-rc. The subprocess's combined stdout+stderr is stored in the
# global LAST_OUT so the caller can inspect it without command
# substitution (which would swallow this function's _pass/_fail output).
LAST_OUT=""
run_py() {
  local name="$1" expect_rc="$2"; shift 2
  local extra_env=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    extra_env+=("$1"); shift
  done
  shift  # drop --
  local code="$1"

  local out rc
  # Parent script uses `set -uo pipefail` (no -e), so command substitution
  # failures don't terminate; capture rc directly.
  out=$(env -i PATH="$PATH" "${MIN_ENV[@]}" "${extra_env[@]}" python3 -c "$code" 2>&1)
  rc=$?
  LAST_OUT="$out"

  if [ "$rc" -ne "$expect_rc" ]; then
    _fail "$name" "rc=$rc want=$expect_rc; out: $out"
    return 1
  fi
  _pass "$name"
  return 0
}

# Common preamble for python snippets: fresh-import the module by path,
# so env vars set by `env -i ...` take effect on this import.
PREAMBLE='
import os, sys, importlib.util
spec = importlib.util.spec_from_file_location("pc", ".github/scripts/post-comment.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
'

# ---- 1. Structural invariant: keys-equal ---------------------------------
#
# Defends contract: OUTCOMES and STEP_LABELS must have identical key sets
# (bidirectional). Stronger than the original "superset" formulation —
# catches drift either way.
run_py "step_labels_keys_equal_outcomes_keys" 0 -- "
$PREAMBLE
o = set(m.OUTCOMES)
s = set(m.STEP_LABELS)
missing = o - s
extra = s - o
assert not missing and not extra, f'OUTCOMES vs STEP_LABELS drift: missing_from_labels={missing}, extra_in_labels={extra}'
"

# ---- 2. build_body section(...) literals all point at real OUTCOMES keys -
#
# Defends contract: every OUTCOMES["<k>"] reference inside the source must
# use a key that exists in OUTCOMES. Catches the third drift point — a
# literal in build_body without a matching dict entry.
run_py "build_body_section_keys_in_outcomes" 0 -- "
$PREAMBLE
import re, pathlib
src = pathlib.Path('.github/scripts/post-comment.py').read_text()
refs = set(re.findall(r'OUTCOMES\\[\"([^\"]+)\"\\]', src))
unknown = refs - set(m.OUTCOMES)
assert not unknown, f'source references unknown OUTCOMES keys: {unknown}'
"

# ---- 3. Module imports cleanly with only the minimum env -----------------
#
# Documents the testability contract — if someone adds a new module-scope
# os.environ[...] read, this test breaks loudly instead of every other
# test failing obscurely.
run_py "module_imports_with_minimum_env" 0 -- "
$PREAMBLE
assert hasattr(m, 'OUTCOMES')
assert hasattr(m, 'STEP_LABELS')
assert hasattr(m, 'build_body')
assert hasattr(m, 'overall_status_line')
"

# ---- 4. overall_status_line: test_e2e=failure path -----------------------
#
# Exact symptom observed in run 26339963529. Without the fix, accessing
# STEP_LABELS['test_e2e'] raises KeyError.
run_py "overall_status_line_test_e2e_failure" 0 "TEST_E2E_OUTCOME=failure" -- "
$PREAMBLE
print(m.overall_status_line())
"
if printf '%s' "$LAST_OUT" | grep -q "Test — E2E"; then
  _pass "overall_status_line_test_e2e_label_present"
else
  _fail "overall_status_line_test_e2e_label_present" "expected 'Test — E2E' in: $LAST_OUT"
fi

# ---- 5. overall_status_line: test_unit=failure path ----------------------
#
# Symmetric — test_unit has the same bug class and its own failure path.
run_py "overall_status_line_test_unit_failure" 0 "TEST_UNIT_OUTCOME=failure" -- "
$PREAMBLE
print(m.overall_status_line())
"
if printf '%s' "$LAST_OUT" | grep -q "Test — Unit"; then
  _pass "overall_status_line_test_unit_label_present"
else
  _fail "overall_status_line_test_unit_label_present" "expected 'Test — Unit' in: $LAST_OUT"
fi

# ---- 6. build_body succeeds end-to-end with test_e2e failure -------------
#
# Catches the "anti-fix" where someone removes test_e2e from OUTCOMES
# instead of adding it to STEP_LABELS — the keys-equal invariant would
# still pass, but build_body indexes OUTCOMES['test_e2e'] directly.
run_py "build_body_no_crash_test_e2e_failure" 0 "TEST_E2E_OUTCOME=failure" -- "
$PREAMBLE
print(m.build_body())
"
if printf '%s' "$LAST_OUT" | grep -q "Test — E2E"; then
  _pass "build_body_renders_test_e2e_section"
else
  _fail "build_body_renders_test_e2e_section" "expected 'Test — E2E' in body"
fi

# ---- 7. build_body succeeds end-to-end with test_unit failure ------------
run_py "build_body_no_crash_test_unit_failure" 0 "TEST_UNIT_OUTCOME=failure" -- "
$PREAMBLE
print(m.build_body())
"
if printf '%s' "$LAST_OUT" | grep -q "Test — Unit"; then
  _pass "build_body_renders_test_unit_section"
else
  _fail "build_body_renders_test_unit_section" "expected 'Test — Unit' in body"
fi

# ---- 8. Multi-failure: status line joins all failed labels ---------------
#
# overall_status_line concatenates labels with ", " — exercise the join
# and make sure both labels surface on the same render.
run_py "overall_status_line_multiple_failures" 0 \
  "TEST_E2E_OUTCOME=failure" "APPLY_BASE_OUTCOME=failure" -- "
$PREAMBLE
print(m.overall_status_line())
"
if printf '%s' "$LAST_OUT" | grep -q "Test — E2E" \
   && printf '%s' "$LAST_OUT" | grep -q "Base — Apply"; then
  _pass "overall_status_line_joins_multiple_failure_labels"
else
  _fail "overall_status_line_joins_multiple_failure_labels" "got: $LAST_OUT"
fi

# ---- 9. All-skipped path: no failures, no successes ----------------------
#
# Defends the "Plan only" branch — every OUTCOME is `skipped`, so the
# failures list is empty AND the successes list is empty.
run_py "overall_status_line_all_skipped" 0 \
  "INIT_BASE_OUTCOME=skipped" "PLAN_BASE_OUTCOME=skipped" \
  "APPLY_BASE_OUTCOME=skipped" "E2E_BASE_OUTCOME=skipped" \
  "DESTROY_BASE_OUTCOME=skipped" "INIT_MGMT_OUTCOME=skipped" \
  "PLAN_MGMT_OUTCOME=skipped" "APPLY_MGMT_OUTCOME=skipped" \
  "E2E_MGMT_OUTCOME=skipped" "E2E_ARGOCD_URL_OUTCOME=skipped" \
  "DESTROY_MGMT_OUTCOME=skipped" "TEST_UNIT_OUTCOME=skipped" \
  "TEST_E2E_OUTCOME=skipped" -- "
$PREAMBLE
print(m.overall_status_line())
"
if printf '%s' "$LAST_OUT" | grep -q "Plan only"; then
  _pass "overall_status_line_all_skipped_plan_only_branch"
else
  _fail "overall_status_line_all_skipped_plan_only_branch" "got: $LAST_OUT"
fi

# ---- 10. All-unset path: every OUTCOMES value is None -------------------
#
# With no *_OUTCOME envs set, every OUTCOMES entry is None. Neither
# overall_status_line nor build_body should raise.
run_py "build_body_no_crash_when_outcomes_all_unset" 0 -- "
$PREAMBLE
m.overall_status_line()
m.build_body()
print('ok')
"
if printf '%s' "$LAST_OUT" | tail -1 | grep -q "^ok$"; then
  _pass "build_body_no_crash_when_outcomes_all_unset_check"
else
  _fail "build_body_no_crash_when_outcomes_all_unset_check" "got: $LAST_OUT"
fi

# ---- 11. cancelled outcome is NOT treated as failure ---------------------
#
# overall_status_line filters strictly on v == "failure". Cancelled runs
# shouldn't appear in the failure label list.
run_py "cancelled_outcome_not_failure" 0 \
  "TEST_E2E_OUTCOME=cancelled" -- "
$PREAMBLE
print(m.overall_status_line())
"
if printf '%s' "$LAST_OUT" | grep -q "Test — E2E"; then
  _fail "cancelled_outcome_not_in_failure_label_list" "got: $LAST_OUT"
else
  _pass "cancelled_outcome_not_in_failure_label_list"
fi

assert_summary
