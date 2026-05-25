# SPEC-B1 — `tests/unit/test_shell_safety.sh`: shell-safety lint

## 1. Summary

Consolidate and extend the existing partial shell-safety lints
(`test_shell_readonly_var_assignment.sh`, `test_integration_scripts_strict_mode.sh`)
into a single comprehensive linter that scans every `*.sh` under
`scripts/`, `tests/`, and `.github/scripts/` for (a) `set -euo pipefail`
(or equivalent — all three flags present), (b) any assignment to
bash readonly built-ins, and (c) workflow YAML using
`continue-on-error: true` without an adjacent justification comment.
The lint exits non-zero on any violation, runs in CI on every push via
the existing `unit-tests.yml`, and is the load-bearing defense against
the silent-PASS bug class that has now recurred twice (PRs #46, #59).

## 2. Retro pain killed

- **PR #46** — `scripts/diag-component.sh` set `$SELECTOR` but referenced
  `$LABEL` in a downstream `kubectl` call. With `set -uo pipefail` (no
  `-e`), the unbound-variable error fired on stderr and the script
  continued to the next line, eventually exiting 0. CI showed PASS until
  a human read the logs. **Evidence:** PR #46 description and the
  bug-of-record comment in
  `tests/unit/test_shell_readonly_var_assignment.sh` lines 1-22 cite the
  pattern as the originating regression.
- **PR #59** — `tests/integration/11_platform_secret_e2e.sh` line 78
  contained `UID=$(kubectl get xplatformsecret "$XR" -o jsonpath=...)`.
  `$UID` is a readonly bash built-in; the assignment silently failed,
  `$UID` retained its prior value (1001), every claim collided on
  `ASM_KEY="k8-platform/1001"`, and four downstream `wait_for` calls
  timed out — yet the script lacked `set -e` and printed the final
  `PASS:` line. **Evidence:** `tests/unit/test_integration_scripts_strict_mode.sh`
  lines 1-18 and `tests/unit/test_shell_readonly_var_assignment.sh`
  lines 3-17 name run `26347839740` and reproduce the bug pattern.

The two existing tests defend narrow slices (one variable `$UID`, one
directory `tests/integration/`). SPEC-B1 expands both axes so the next
related bug — `EUID=`, `RANDOM=`, a missing `set -e` in `scripts/`, an
unannotated `continue-on-error` — is caught at lint time.

## 3. Out of scope

- POSIX-compliance checking (the codebase uses bashisms intentionally
  — `mapfile`, `[[ ]]`, `<<<`, etc.).
- Unused-variable detection (shellcheck's `SC2034`); this lint targets
  silent-PASS bug classes only.
- Style concerns (indentation, quoting around `$var`, `[[ -n ]]` vs
  `[ -n ]`). Shellcheck integration is a separate future spec.
- Linting Python helpers (`.github/scripts/post-comment.py`); SPEC-B1
  is bash-only.
- Linting vendored / third-party scripts checked into the repo
  (none today, but if any land, see §5 allowlist).
- Linting workflow YAML beyond the `continue-on-error` rule. Other
  workflow hygiene (timeout-minutes, permissions blocks) belongs in
  a separate lint.
- Modifying the silent-PASS-causing scripts to add `set -euo pipefail`
  — see §11 rollout. SPEC-B1 ships the lint; rollout audits and fixes
  current violations as a prerequisite to enabling it.

## 4. Files to create

Create:

- `tests/unit/test_shell_safety.sh` — single-file lint. Sources
  `tests/lib/assert.sh`. Performs all three checks (a/b/c) below.
- `tests/unit/fixtures/shell_safety/` — directory of meta-test fixtures:
  - `should_pass_strict_mode.sh` — has `set -euo pipefail`, no
    readonly assignments. Lint must accept.
  - `should_fail_missing_strict.sh` — has only `set -uo pipefail`
    (the PR #46 pattern). Lint must reject.
  - `should_fail_readonly_assign.sh` — has `set -euo pipefail` but
    contains `UID=$(...)`. Lint must reject.
  - `should_pass_workflow.yml` — YAML with
    `continue-on-error: true  # justified: tracked in #XX` adjacent.
    Lint must accept.
  - `should_fail_workflow.yml` — YAML with bare
    `continue-on-error: true` and no nearby comment. Lint must reject.

Modify:

- `tests/unit/run.sh` — replace the two existing
  `run_suite tests/unit/test_shell_readonly_var_assignment.sh` and
  `run_suite tests/unit/test_integration_scripts_strict_mode.sh`
  lines with a single
  `run_suite tests/unit/test_shell_safety.sh`. Delete the now-superseded
  files (their bug-of-record references and rationale move into the
  header comment of the new test).
- `.github/workflows/unit-tests.yml` — replace the per-test steps for
  the two superseded tests with one `test_shell_safety` step. Keep
  per-test step granularity (no `run.sh` consolidation — see existing
  workflow rationale).

Possibly create (only if §5 implementation pushes complexity above
~200 LOC in the test):

- `tests/lib/shell_safety_helpers.sh` — extracted helper functions
  (`scan_for_strict_mode`, `scan_for_readonly_assigns`,
  `scan_workflow_continue_on_error`). Avoid unless needed; keeping
  one self-contained test file is preferable.

## 5. Implementation notes

### Scope of files scanned

Use `find` rooted at the repo root (the test `cd`s there):

```
find scripts tests .github/scripts -type f -name '*.sh'
```

Also scan `tests/unit/run.sh` and `tests/integration/run.sh` (named
`run.sh`, not `*.sh` pattern — add explicitly). Skip:

- The fixtures directory itself (`tests/unit/fixtures/shell_safety/`)
  — those are intentional good/bad samples.
- `tests/unit/test_shell_safety.sh` itself (mentions the patterns in
  comments/regexes).

### (a) Strict-mode detection

Regex: a `set` invocation early in the file (within the first 20
non-comment, non-blank lines after the shebang) that contains all
three of `-e`, `-u`, and `-o pipefail`. Acceptable shapes:

```
set -euo pipefail
set -eu -o pipefail
set -e -u -o pipefail
set -o errexit -o nounset -o pipefail
```

Rejected shape (the PR #46 footgun):

```
set -uo pipefail      # missing -e
set -eu               # missing -o pipefail
set -e                # missing -u and pipefail
```

Implementation: use a small awk pass that collects every `set ...`
line in the first 20 effective lines, then checks per-flag presence
across the union of those lines (a script may legitimately have two
`set` calls). Treat `set -o errexit` as equivalent to `-e`, `-o
nounset` as `-u`, `-o pipefail` as `-o pipefail`.

### (b) Readonly-builtin assignment detection

Target list (from the bash manual's "Bash Variables" / "Shell
Variables"):

```
UID EUID PPID BASHPID BASH_VERSINFO RANDOM SECONDS LINENO FUNCNAME
```

Regex (one grep per name to keep error messages targeted):

```
grep -nE '^[[:space:]]*'"$NAME"'=' "$script" | grep -vE '^[^:]+:[[:space:]]*#'
```

The trailing filter drops comment-only lines. Also exclude `local
NAME=...` and `declare NAME=...` patterns (those are scoped
declarations; bash still rejects them for true readonly built-ins,
but flagging them keeps the error message cleaner). Do not match
`export NAME=...` either — same reason; bash will reject and we
want the lint to point at the literal `NAME=` form because that's
the bug pattern.

### (c) Workflow `continue-on-error` audit

Scan `.github/workflows/*.yml` and `.github/workflows/*.yaml`. For
every line matching `^[[:space:]]*continue-on-error:[[:space:]]*true`,
check the surrounding ±2 lines for either:

- A `#` comment containing one of: `justified`, `tracked`, `known-broken`,
  `TODO`, `FIXME`, or a GitHub issue/PR reference (`#\d+`).
- A `name:` field for the step containing the substring
  `continue-on-error` (the existing `unit-tests.yml` test_helm_render
  step uses this pattern).

If neither is found, fail with a message naming the file and line.

### Exit codes

- `0` — all scans passed.
- `1` — one or more violations. The test prints `FAIL:` lines via
  `tests/lib/assert.sh`'s `_fail` helper, then summary `N FAIL(s)`
  and exits 1. Standard for the existing unit suite.

### Allowlist mechanism

A literal `# shell-safety-lint: allow` comment on the same line as a
violation suppresses that single violation. Vendored scripts (none
today) can opt out file-wide with a `# shell-safety-lint: skip-file`
comment on the first ten lines. Both forms log a `NOTICE:` line so
the allowlist isn't invisible. Allowlist usage requires a one-line
reason in a comment immediately above; the lint does not enforce
that comment's presence (low value, high noise) but the convention
is documented in `ai/testing-guidelines.md` per §8.

### Performance

The lint scans ~30 files today; grep+awk passes complete in well
under one second. No need for parallelism or caching.

## 6. Tests required

Per AGENTS.md §6.1 (author tests alongside features) and §6.2 (TDD
discipline — regression-catching tests for known bugs):

| Layer | File | Assertion shape |
|---|---|---|
| Unit (meta) | `tests/unit/test_shell_safety.sh` (self-asserting) | Run lint against `tests/unit/fixtures/shell_safety/should_pass_strict_mode.sh` — assert exit 0 and no `FAIL:` lines for that fixture. |
| Unit (meta) | same | Run lint against `should_fail_missing_strict.sh` — assert exit 1 and `FAIL:` line names the file and the missing-flag(s). |
| Unit (meta) | same | Run lint against `should_fail_readonly_assign.sh` — assert exit 1 and the `FAIL:` line names `UID`. |
| Unit (meta) | same | Run lint against `should_pass_workflow.yml` — assert exit 0. |
| Unit (meta) | same | Run lint against `should_fail_workflow.yml` — assert exit 1 and the message names `continue-on-error`. |
| Unit (regression) | same | Synthesize the PR #46 bug pattern in a fixture (`set -uo pipefail` + later `$UNBOUND` reference) — assert lint flags missing-`-e`. Mirrors the bug-of-record. |
| Unit (regression) | same | Synthesize the PR #59 bug pattern (`UID=$(...)`) — assert lint flags it. Mirrors the bug-of-record. |
| Unit (allowlist) | same | Fixture with the readonly violation plus `# shell-safety-lint: allow` on the same line — assert exit 0 and a `NOTICE:` line. |
| Unit (allowlist) | same | Fixture with `# shell-safety-lint: skip-file` in the head — assert exit 0 even though violations exist. |

The fixture-based tests are the §6.2 regression-catching pattern: the
fixture *is* the bug; the lint *is* the test that catches it. If the
lint regresses (regex breaks, scan path narrows) the meta-fixtures fail
the unit suite on the next push.

§6.4 adversarial-reviewer trigger: before authoring the test file,
spawn one general-purpose subagent with the brief — the readonly
built-in list and the strict-mode regex are the load-bearing surfaces;
a reviewer is likely to surface bash variants we missed (e.g.
`set -o pipefail; set -eu` split across two lines, or
`UID=value command` one-line-export form).

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast (<10 s each). File names follow `tests/unit/test_<name>.sh`. All
five cases run within `tests/unit/test_shell_safety.sh`.

1. `tests/unit/fixtures/shell_safety/should_pass_strict_mode.sh` —
   assert lint exits 0 and emits no `FAIL:` lines.
2. `tests/unit/fixtures/shell_safety/should_fail_missing_strict.sh`
   (the PR #46 pattern: `set -uo pipefail` without `-e`) — assert exit 1
   and `FAIL:` line names the file and the missing flag.
3. `tests/unit/fixtures/shell_safety/should_fail_readonly_assign.sh`
   (`UID=$(...)`) — assert exit 1 and the `FAIL:` line names `UID`.
4. `tests/unit/fixtures/shell_safety/should_pass_workflow.yml` (adjacent
   justification comment present) — assert exit 0.
5. `tests/unit/fixtures/shell_safety/should_fail_workflow.yml` (bare
   `continue-on-error: true`, no comment) — assert exit 1 and the
   message names `continue-on-error`.

### Integration

Not applicable. The lint operates purely on static source files via
grep/awk; there is no live cluster surface, no API call, and no runtime
state. Spinning up a kind cluster would add 60+ seconds of overhead
with zero additional signal. Any future rule that requires a running
binary (e.g. linting generated manifests produced by a Helm chart)
would warrant an integration test; the current three rules do not.

### E2E

Not applicable. The lint is a local bash script with no network
dependency, no Kubernetes object, and no deployed phase-N artifact.
A chainsaw scenario or full-stack probe would exercise nothing beyond
what the unit fixtures already cover. If SPEC-B1 is later extended to
scan Helm-rendered YAML in a deployed environment, an e2e layer would
be warranted at that point.

Distinguish from §6: §6 lists the must-have gate tests without which
the spec is incomplete. §7 is the broader catalogue of tests one might
add as the surrounding system matures; the integration and e2e layers
are consciously deferred here because the lint has no live-system
surface.

## 8. Documentation updates

- `AGENTS.md` §6.1 — add a row to the test-layers table:
  *"Shell-safety lint | always | `tests/unit/test_shell_safety.sh`"*
  noting that every `*.sh` under `scripts/`, `tests/`,
  `.github/scripts/` is auto-scanned. Brief because the lint is
  automatic and the procedure is "don't write the footgun".
- `ai/testing-guidelines.md` — add a short subsection naming the
  three violation classes and the allowlist comment syntax
  (`# shell-safety-lint: allow` and `skip-file`). State the policy:
  allowlists need a one-line reason comment above.
- No update to `ai/handoff.md` beyond the standing convention
  (handoff records session state, not lint catalogs).
- The two superseded test files' header comments (with their
  bug-of-record citations and run IDs) move into `test_shell_safety.sh`
  so the historical context is preserved when the old files are
  deleted.

## 9. Workflow / auto-invocation wiring

The wiring is already in place — no new files needed:

- `tests/unit/run.sh` auto-discovers `test_*.sh` only via its explicit
  `run_suite` list (it's not actually globbed — see existing file).
  The new test gets one `run_suite tests/unit/test_shell_safety.sh`
  line. The two superseded lines come out in the same commit.
- `.github/workflows/unit-tests.yml` adds one `- name: test_shell_safety`
  step matching the existing per-test pattern (deliberate per-test
  granularity for diagnose-from-Actions-UI per the workflow's own
  comment). Removes the two superseded steps.

No `continue-on-error` on the new step — by definition the lint must
fail loud if it finds violations, and §12 rollout ensures the lint
is green before this step is added.

Fire-and-forget on every push to a non-main branch (the workflow's
existing trigger). No human dispatch required.

## 10. Discoverability for future agents

Three forcing functions, none requiring agent action:

1. **CI runs the lint on every push.** A regression — re-introducing
   `UID=`, dropping `set -e` from an integration script, adding an
   unjustified `continue-on-error` — fails the PR check immediately.
   No agent needs to remember to run it.
2. **AGENTS.md §6.1 lists the lint as a required test layer.** Future
   agents scanning the table for "what tests exist?" see it.
3. **Allowlist comments are searchable.** `grep -rn 'shell-safety-lint:'`
   surfaces every exception in the repo, so audit of suppressions is
   one command.

No new skill, no new doc-link required at session start. The lint is
infrastructure.

## 11. Verification checklist

- [ ] `bash tests/unit/test_shell_safety.sh` exits 0 on the current
  repo state (after §11 rollout fixes are applied).
- [ ] `bash tests/unit/run.sh` includes the new test in its output
  and overall exits 0.
- [ ] Both superseded test files (`test_shell_readonly_var_assignment.sh`,
  `test_integration_scripts_strict_mode.sh`) are deleted in the
  same commit as the new test lands.
- [ ] `.github/workflows/unit-tests.yml` has exactly one
  `test_shell_safety` step and zero references to the two superseded
  test names.
- [ ] All five fixture files exist under `tests/unit/fixtures/shell_safety/`
  and the test exercises each (visible in `PASS:`/`NOTICE:` output).
- [ ] Manual: temporarily introduce `UID=foo` into a `scripts/*.sh`
  file, run the lint locally, confirm it fails with a message naming
  the file, line, and variable. Revert.
- [ ] Manual: temporarily change `set -euo pipefail` to `set -uo
  pipefail` in a `scripts/*.sh` file, run the lint, confirm it fails
  naming the missing `-e`. Revert.
- [ ] `grep -rn 'shell-safety-lint:' .` shows zero allowlist usages
  on first landing (no pre-existing escape hatches grandfathered in).

## 12. Rollout notes — CRITICAL

**The lint will fail against the current repo on day one.** Before
adding the `test_shell_safety` step to `unit-tests.yml`, complete
this audit-and-fix sequence:

1. **Author the lint and fixtures (the §4 / §6 work).** Do not yet
   wire it into `run.sh` or the workflow.
2. **Audit pass.** Run the lint locally against the repo. Capture
   every violation into a checklist. Expect violations in:
   - Older `scripts/*.sh` that pre-date the strict-mode discipline.
   - Test scripts that adopted `set -uo pipefail` (the safe-but-not-strict
     subset) — including `tests/unit/run.sh` itself, which uses
     `set -uo pipefail` deliberately so a failed sub-suite doesn't
     abort the whole run. This is a legitimate allowlist case:
     add `# shell-safety-lint: allow` on the `set` line with a one-line
     reason comment above.
   - `.github/workflows/unit-tests.yml` already has one
     `continue-on-error: true` (test_helm_render) — the step name
     contains `continue-on-error` per the existing rationale, which
     the lint should accept under the §5(c) rules. Verify the lint
     accepts it; if not, adjust the rule to match the existing
     pattern before landing.
3. **Fix pass.** For each violation, either:
   - Add the missing flag(s) / remove the readonly assignment / add
     the justifying comment, OR
   - Add `# shell-safety-lint: allow` with a one-line reason comment
     above. Allowlist is fine for genuinely-intentional exceptions
     (the `run.sh` aggregator case above) but is not a substitute
     for fixing real bugs.
4. **Re-run the lint.** Confirm green.
5. **Wire in.** Add the `run_suite` line, add the workflow step,
   delete the two superseded tests, push.
6. **Confirm CI green** on the branch before opening the PR.

Stack the PRs per AGENTS.md §3 if the fix pass is large:

- PR 1 (parent): the lint + fixtures, NOT wired in. Allows review
  of the lint logic in isolation.
- PR 2 (child off PR 1): the audit fixes / allowlist additions,
  wire-in to `run.sh` and `unit-tests.yml`, deletion of superseded
  tests.

Both PRs are mergeable independently after stacking; PR 2's CI
gates on the new step being green, which proves the audit was
complete.

## 13. Estimated effort

**M** — medium.

Justification: the lint logic is straightforward (~150 LOC of bash
with grep/awk), but the audit-and-fix pass over current repo
contents is the bulk of the work — ~30 shell files plus a handful
of workflow YAML, each requiring a judgement call between "fix" or
"allowlist". Fixture authoring is ~5 small files. The two
superseded tests' deletion is mechanical. Adversarial-reviewer
round adds ~1 hour. Total estimate: 6–10 hours of focused work
across the two stacked PRs.
