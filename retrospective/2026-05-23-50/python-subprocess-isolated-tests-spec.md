# Spec: `python-subprocess-isolated-tests`

## Intent

When a Python module reads environment variables at *import time* (not per-call), in-process tests can't change scenarios just by mutating `os.environ` between assertions — the values were already captured when the module first loaded. A test draft that does `os.environ['FOO']='bar'; importlib.reload(mod)` is brittle (reload order matters, cached subimports persist) and was the exact silent-pass risk the adversarial subagent caught for `tests/unit/test_post_comment.sh` this session: my draft would have passed against the unfixed code because the second scenario inherited the first scenario's `OUTCOMES` dict.

The robust pattern: run each scenario in a **clean Python subprocess** with `env -i ... python3 -c "..."`. Each scenario gets its own fresh import, its own fresh env, no cross-scenario contamination.

This skill is a reference + generator for that pattern: given a target Python module and a list of (env, assertion) scenarios, emit a bash test harness that drives each scenario as its own subprocess.

## Trigger

**Direct phrases**: "test a Python script that reads env at import time", "isolate the test scenarios", "the module reads env at module level".

**Proactive trigger**: when authoring tests for a Python file that has `os.environ[...]` at module scope (not inside a function), suggest this pattern.

**Negative trigger**: pure-function modules without import-time side effects don't need this. Just import them once and call.

## Inputs

- Path to the target Python module (e.g. `.github/scripts/post-comment.py`).
- The minimum env vars the module requires to import without raising (the "MIN_ENV").
- A list of scenarios: `(name, extra_env_dict, python_assertion_snippet)`.

## Outputs

- A bash test file under `tests/unit/test_<module>.sh` that:
  - Sources `tests/lib/assert.sh`.
  - Defines `MIN_ENV=(...)` and a `run_py` helper.
  - Invokes each scenario as `env -i PATH=... MIN_ENV ... EXTRA ... python3 -c "<preamble + assertion>"`.
  - Reports pass/fail per scenario.

## Workflow

1. Identify the target module's module-scope env reads via static parse (regex `os\.environ\[`). Collect them as MIN_ENV requirements.
2. Author the bash file with a generic `run_py` helper. The helper:
   - Takes `<name> <expect-rc> [<extra-env...>] -- <python-code>`.
   - Stores stdout+stderr in a global `LAST_OUT` (NOT in command substitution — `_pass`/`_fail` outputs would be swallowed by `$(run_py ...)`).
   - Uses `env -i PATH="$PATH" "${MIN_ENV[@]}" "${extra_env[@]}" python3 -c "$code"`.
3. For each scenario, the python code is `PREAMBLE + assertion`:
   ```python
   import os, sys, importlib.util
   spec = importlib.util.spec_from_file_location("m", "<path>")
   m = importlib.util.module_from_spec(spec)
   spec.loader.exec_module(m)
   # ... assertion using m.* ...
   ```
4. The bash harness ends with `assert_summary` from `tests/lib/assert.sh`.
5. The harness MUST run successfully under `set -uo pipefail` (no `set -e` — `_fail` returning a non-zero rc must not terminate the suite).

## Concrete examples

### Example 1 — structural invariant test

For `.github/scripts/post-comment.py` (this session's actual fix), one scenario:

```bash
run_py "step_labels_keys_equal_outcomes_keys" 0 -- "
import os, sys, importlib.util
spec = importlib.util.spec_from_file_location('pc', '.github/scripts/post-comment.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
o = set(m.OUTCOMES)
s = set(m.STEP_LABELS)
missing = o - s; extra = s - o
assert not missing and not extra, f'drift: missing_from_labels={missing}, extra_in_labels={extra}'
"
```

This passed against the fixed code; **failed cleanly** against the unfixed code (TDD red confirmed).

### Example 2 — per-scenario env override

For a `test_e2e=failure` scenario:

```bash
run_py "overall_status_line_test_e2e_failure" 0 "TEST_E2E_OUTCOME=failure" -- "
import os, sys, importlib.util
spec = importlib.util.spec_from_file_location('pc', '.github/scripts/post-comment.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.overall_status_line())
"

# Inspect LAST_OUT after the run_py call (NOT inside $(...))
if printf '%s' "$LAST_OUT" | grep -q "Test — E2E"; then
  _pass "overall_status_line_test_e2e_label_present"
else
  _fail "overall_status_line_test_e2e_label_present" "expected 'Test — E2E' in: $LAST_OUT"
fi
```

The `env -i ... TEST_E2E_OUTCOME=failure ... python3 -c "..."` starts a fresh process. The new subprocess imports the module fresh, reads `TEST_E2E_OUTCOME=failure` from its env, and `OUTCOMES['test_e2e']` becomes `"failure"`. The previous scenario's `unset TEST_E2E_OUTCOME` state is irrelevant — the subprocesses don't share state.

## Anti-patterns

- **Don't try to use `importlib.reload()` to refresh env-bound module-level state.** It's fragile — cached sub-imports persist, and post-load env changes don't propagate to already-bound variables.
- **Don't capture `run_py`'s output via `$(run_py ...)`.** That swallows the `_pass`/`_fail` echo to stdout, silently making green/red invisible. Use `LAST_OUT` global instead.
- **Don't use `set -e` in the bash harness.** When `_fail` runs after a subprocess returns non-zero, the shell would exit immediately, killing the suite mid-run. The parent script needs `set -uo pipefail` without `-e`.
- **Don't share an `env` dict across scenarios.** Each scenario passes its own additional env vars; the MIN_ENV is the only common base.
- **Don't `pip install` anything.** The pattern uses stdlib only. The test runs on a vanilla Python 3 in CI.

## Acceptance criteria

1. The generated test runs under `set -uo pipefail` in <2 seconds for ~10 scenarios.
2. Each scenario is observably independent: setting `TEST_X=failure` in scenario A doesn't affect scenario B's view of `TEST_X`.
3. Confirmed-red TDD: removing the fix from the target module makes ≥1 scenario fail. The skill spec assumes the user has authored the assertions; the skill produces the harness, not the asserts.
4. Subprocess startup cost stays under ~100ms each (no slow imports).
5. The harness's exit code reflects suite success: 0 if all green, non-zero if any failed.

## Files this skill creates / modifies

- `tests/unit/test_<module>.sh` — the bash test harness.
- `tests/unit/run.sh` — optionally appended with the new `run_suite` line.
- No changes to the target Python module unless requested.
