# Spec: `tdd-lint-bug-class`

- **ID**: SKILL-SPEC-9149cdc0a6
- **Source retrospective**: ../2026-05-24-62.md

## Intent

Every bug fixed in this codebase is an opportunity to install a lint that prevents the bug class from returning. Write the lint **before** the fix (TDD): red → fix → green → wire into runner. This makes the lint demonstrably effective (it caught the bug) and adds a defending invariant for future code.

Grounded in: this session shipped 4 bug fixes with this pattern (PRs #59 with two lints — `test_shell_readonly_var_assignment.sh` and `test_integration_scripts_strict_mode.sh`; PR #61 with `test_composition_string_transform_type.sh`). Each lint caught the bug class across multiple instances I hadn't initially noticed: the UID lint caught both `11_platform_secret_e2e.sh` AND `scripts/diag-component.sh`; the set-e lint caught all 11 integration scripts; the composition lint caught 9 instances across both Compositions.

## Trigger

**Direct user phrases:**
- "Fix bug X"
- "Make sure this doesn't happen again"
- "TDD this"

**Proactive triggers:**
- About to apply a code fix for a real bug-of-record (i.e., reproduced from logs/diagnostics, not speculative)
- Discovery that a single-line bug exists in multiple places (e.g., grep finds 9 occurrences)
- Failure mode that "no existing unit test would have caught" — see handoff item #8

**Negative triggers:**
- The bug is a one-off typo that's not a class (e.g., misspelled function name); no lint warranted
- The bug class is already covered by an existing lint (then the lint failed — fix the lint, not the bug)

## Inputs

- The bug's reproduction signature (error message, behaviour)
- The fix's location (file paths, the exact transformation)
- The bug class invariant (what property must hold for the bug to be absent)

## Outputs

- A new `tests/unit/test_<bug-class-shortname>.sh` that exercises the invariant
- The lint added to `tests/unit/run.sh`
- The lint goes RED on the unfixed code, GREEN after the fix
- A documenting comment in the lint citing the bug-of-record (run ID, PR number, error message)

## Workflow

1. **Identify the invariant.** Phrase the bug as a property that must hold across files. Examples:
   - "No script assigns to bash readonly variables (`UID`, `EUID`, `BASHPID`, ...)."
   - "Every `tests/integration/NN_*.sh` uses `set -e` (or `set -eu`, or `set -euo pipefail`)."
   - "Every Composition `type: string` transform sets `.string.type`."

2. **Author the lint.** Place at `tests/unit/test_<invariant>.sh`. Pattern:
   ```bash
   #!/usr/bin/env bash
   # Lint: <invariant>.
   #
   # Bug-of-record: <run ID / error message / brief context>.
   # Without this lint, <bug class consequence>.

   set -uo pipefail
   cd "$(dirname "$0")/../.."
   . tests/lib/assert.sh

   bad=0
   for <iteration source>; do
     if <bug condition>; then
       _fail "<assertion name>:<file>" "<actionable error>"
       bad=$((bad+1))
     fi
   done
   if [ "$bad" -eq 0 ]; then
     _pass "<invariant name>"
   fi
   assert_summary
   ```

3. **Run the lint RED.** Confirm the lint actually catches the bug — `bash tests/unit/test_<invariant>.sh` MUST fail. If it doesn't, the lint isn't catching the bug; refine.

4. **Apply the fix** across all files the lint flagged. The fix changes might touch more files than expected — the lint surfaces them.

5. **Run the lint GREEN.** `bash tests/unit/test_<invariant>.sh` MUST now pass.

6. **Wire into `tests/unit/run.sh`.** Append a `run_suite tests/unit/test_<invariant>.sh` line.

7. **Run the full bundle** (`bash tests/unit/run.sh`) — ensure no regression in other suites.

## Concrete examples

### Example 1 — bash UID shadowing (PR #59, the actual session)

**Invariant:** "No script assigns to the bash readonly variable `$UID`."

Lint at `tests/unit/test_shell_readonly_var_assignment.sh`:
```bash
mapfile -t scripts < <(find tests scripts -type f \( -name '*.sh' -o -name 'run.sh' \) | sort)
for script in "${scripts[@]}"; do
  [ "$(basename "$script")" = "test_shell_readonly_var_assignment.sh" ] && continue
  if grep -nE '^[[:space:]]*UID=' "$script" | grep -vE '^[^:]+:[[:space:]]*#'; then
    _fail "no_uid_assignment:$script" "..."
  fi
done
```

Initial RED: caught `tests/integration/11_platform_secret_e2e.sh` AND (surprise) `scripts/diag-component.sh`. Two-file fix: rename `UID` → `XR_UID` in both. Lint green. Wired in.

### Example 2 — Composition string transform type (PR #61)

**Invariant:** "Every Composition's pipeline patch transform of type=string sets `.string.type`."

Lint at `tests/unit/test_composition_string_transform_type.sh`:
```python
for path in pathlib.Path("crossplane/compositions").glob("*.yaml"):
    doc = yaml.safe_load(path.read_text())
    for step in doc["spec"]["pipeline"]:
        for res in step["input"]["resources"]:
            for patch in res.get("patches", []):
                for tr in patch.get("transforms", []):
                    if tr.get("type") == "string" and "type" not in tr.get("string", {}):
                        bad.append(...)
```

Initial RED: 9 instances across both Compositions. Fix: insert `type: Format` after every `string:` line that has `fmt:`. Lint green. Wired in. The 9-place fix would have been impossible to spot manually.

## Anti-patterns

- **Fix first, lint later (or never).** The lint isn't proven effective if you didn't see it go red against the unfixed code.
- **Test the fix instance, not the bug class.** A test that asserts `XR_UID=…` is correct in one file misses the bug class. Lint the invariant ("no script assigns to `UID`"), not the instance.
- **Skip wiring into `run.sh`.** Lint exists but isn't run in CI. Useless.
- **Author a lint with no bug-of-record comment.** Six months later nobody knows why the lint exists or what it defends against.
- **Lint too narrowly.** "UID assignment in 11_platform_secret_e2e.sh" misses diag-component.sh. Lint should scan all relevant files.
- **Lint too broadly.** "No grep of UID in any file" matches comments / strings — false positives. Refine to actual assignments.

## Acceptance criteria

1. Every bug fix PR contains both the fix AND a new (or strengthened) lint.
2. The lint is documented with the bug-of-record (run ID, error message).
3. The lint demonstrably went RED on unfixed code and GREEN after the fix.
4. The lint is wired into `tests/unit/run.sh`.
5. The lint scans ALL relevant files, not just the one where the bug was first observed.

## Files this skill creates / modifies

- `tests/unit/test_<bug-class-shortname>.sh` — the new lint
- `tests/unit/run.sh` — append the new `run_suite` line
- The fix files themselves (per the fix's own scope)
