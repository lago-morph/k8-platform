# SPEC-D1 — Delete `post-comment.py` + `test_post_comment.sh`

Tier D, brainstorm IDs A6-014 + A6-015.

## 1. Summary

Delete `.github/scripts/post-comment.py` and `tests/unit/test_post_comment.sh`
from the repository. The script was written to post Terraform run summaries as
PR comments from inside a GitHub Actions workflow; now that the agent executes
`terraform plan` and `terraform apply` in-sandbox and writes diffs directly
into the PR body via `gh pr edit`, the Actions-driven auto-comment mechanism
is obsolete. Per the P→A6-001 "blast radius" rule, the replacement path
(agent-written in-PR-body summary) is documented and fixtures are captured
first; then the files are removed in the same PR. The unit test
`test_post_comment.sh` exists solely to defend the now-deleted script and
goes away with it. The rendering logic the script embodied is preserved via
fixtures so the agent's in-PR-body summary can be regression-tested against
the same section-heading and truncation shape (cross-comment A1→A6-013).
This spec is part of the Tier D cleanup cluster
(`ai/brainstorming/CLUSTERING-REVIEW.md`, Cluster D).

## 2. Retro pain killed

- **Silent masking of real failures.** `post-comment.py` itself suffered a
  `KeyError` during a live run (run 26339963529) when `test_e2e` was in
  `OUTCOMES` but not in `STEP_LABELS`. The error caused the summary step
  to fail while the real test failure was already present — the summary
  machinery broke in the worst moment and required its own fix
  (`test_post_comment.sh` test 4, "overall_status_line_test_e2e_failure").
  Removing the script eliminates this failure class entirely.
- **Workflow-only environment coupling.** The script reads
  `RUNNER_TEMP`, `GITHUB_REPOSITORY`, `GITHUB_SHA`, `GITHUB_REF_NAME`,
  `GITHUB_EVENT_NAME`, and `GH_TOKEN` at module-import time (lines 17–22 of
  `post-comment.py`), making the module impossible to import outside of
  Actions. This forced the unit test (`test_post_comment.sh`) to set up an
  elaborate `env -i ... python3` subprocess harness (lines 37–58) just to
  isolate environment state between cases. The coupling was a known pain
  point flagged in brainstorm A6-013: "Drop RUNNER_TEMP / GITHUB_REPOSITORY
  / GITHUB_SHA / GITHUB_REF_NAME plumbing once it no longer needs to run
  inside Actions."
- **Duplicate reporting path.** Once the agent writes the PR body directly,
  a parallel Actions comment adds noise: two structured summaries for the
  same run appear on the PR thread. The auto-comment is now redundant by
  construction.
- **Maintenance surface without a consumer.** The 11 unit tests in
  `test_post_comment.sh` defend three internal invariants of a script no
  agent invokes. Every future change to `OUTCOMES` or `STEP_LABELS` in the
  workflow would require a matching edit to `post-comment.py`; those dicts
  are dead weight.

## 3. Out of scope

- **Replacing the script with a local equivalent.** A3→A6-003 suggested
  porting the truncation and section-heading logic into
  `scripts/pr-body-format.sh`. That extraction is a follow-on refactor
  (potentially SPEC-D1.1). This spec removes the file; it does not
  prescribe a replacement helper. The implementing agent writes the
  in-PR-body summary inline using `gh pr edit --body`.

- **Archiving rendered output from prior CI runs.** A1→A6-013 suggested
  capturing the last 30 days of rendered comment output as fixtures. The
  PR comment history exists permanently in GitHub and is recoverable via
  `gh api`. What this spec DOES require is extracting the shape (section
  headings and truncation rule) into static fixtures under
  `tests/unit/fixtures/post_comment_rendering/` before deletion — those
  fixtures serve as the regression baseline for the in-PR-body summary
  going forward. Full historical capture is out of scope.

- **Rewriting the in-PR-body summary logic.** How the agent structures the
  PR body after a `terraform plan` or `apply` run is governed by the
  relevant skill (`crossplane-claim-verify`, terraform CI skill, or inline
  agent behavior). This spec only removes the Actions-only predecessor.

- **Updating `.github/workflows/terraform-test.yml` to add a replacement
  summary step.** The workflow no longer needs a "Post summary comment"
  step once the agent controls the PR body. The implementing agent removes
  the step entirely; wiring in a new step is a separate concern.

### Considered and rejected

- **Keep the script but strip the Actions env coupling (A6-013 as a
  precursor, not A6-014).** Rejected. The script's only consumer is the
  Actions workflow. Once the agent owns the PR body, the script has no
  caller. Refactoring an orphan adds churn with no payoff.
- **Keep `test_post_comment.sh` as a canary for Python import hygiene.**
  Rejected. The tests are structurally tied to `post-comment.py`'s internal
  dict layout. Decoupled Python import hygiene tests belong in a generic
  lint, not in a file whose name declares its subject.

## 4. Files to change / create

### Delete

| Path | Reason |
|------|--------|
| `/home/user/k8-platform/.github/scripts/post-comment.py` | Auto-comment script, Actions-only, no agent consumer (A6-014). |
| `/home/user/k8-platform/tests/unit/test_post_comment.sh` | Unit test solely defending the deleted script (A6-015). |

### Modify

| Path | What changes |
|------|-------------|
| `/home/user/k8-platform/.github/workflows/terraform-test.yml` | Remove the "Post summary comment" step (lines 501–519) including its `env:` block and the `if: always()` guard. |
| `/home/user/k8-platform/.github/workflows/unit-tests.yml` | Remove the "Verify python3" step (line 60) and the "test_post_comment" step (lines 86–87). |
| `/home/user/k8-platform/tests/unit/run.sh` | Remove `run_suite tests/unit/test_post_comment.sh` (line 33). |
| `/home/user/k8-platform/AGENTS.md` | Add a note in §6 (or whichever section describes CI summary behavior) that plan/apply output goes in the PR body directly; the auto-comment script is gone. |

### Create

| Path | Purpose |
|------|---------|
| `/home/user/k8-platform/tests/unit/fixtures/post_comment_rendering/expected_sections.txt` | Canonical section headings extracted from `post-comment.py`'s `build_body()` before deletion. Used by future rendering regression tests. |
| `/home/user/k8-platform/tests/unit/fixtures/post_comment_rendering/truncation_rule.txt` | Documents the `MAX_LINES = 100` truncation contract and the "_(output truncated — showing last N of M lines)_" message shape, so any replacement respects it. |

## 5. Implementation notes

### Order of operations (P→A6-001 blast radius rule)

The P→A6-001 rule requires the replacement be proven before the removal.
Applied here in a single PR with three steps in order:

1. **Capture fixtures first.** Extract section headings and truncation
   contract from `post-comment.py` into the fixture files listed in §4.
2. **Document the in-PR-body path.** Add one sentence to `AGENTS.md`
   confirming `gh pr edit --body` is the approved reporting mechanism.
3. **Remove files and workflow steps.** Do not split across separate
   branches; the audit trail requires all three changes in one diff.

### Preserve rendering via fixtures (cross-comment A1→A6-013)

The fixture files capture two rendering contracts from `post-comment.py`
that must survive deletion:

**Section headings** (`expected_sections.txt`) — extracted verbatim from
the `build_body()` call list (lines 118–132). The implementing agent copies
the human-readable titles from the `section(...)` calls:

```
Base — Init
Base — Plan
Base — Apply
Base — E2E Verify
Base — Destroy
Management — Init
Management — Plan
Management — Plan (post-base apply)
Management — Apply
Management — E2E Verify
Management — ArgoCD URL
Management — Destroy
Test — Unit
Test — E2E
```

Any future PR-body summary that covers the same Terraform phases should
include a section for each of these steps (or explicitly document which
steps were skipped and why).

**Truncation rule** (`truncation_rule.txt`) — captures the contract:
output exceeding 100 lines is truncated; the first line of truncated output
is `_(output truncated — showing last 100 of N lines)_`. This budget
(≤100 lines per section) exists to keep PR comments readable. A replacement
PR-body summary must honor an equivalent output budget.

### Workflow changes (callers that need updating)

Two workflows call the script or its test directly:

**`.github/workflows/terraform-test.yml`** — the "Post summary comment"
step at lines 501–519 calls `python3 .github/scripts/post-comment.py` with
`if: always()`. Remove this entire step and its `env:` block (the thirteen
`*_OUTCOME` vars). Nothing else in the workflow reads those env vars; the
`id`-labelled outcome steps (`steps.init_base.outcome`, etc.) remain because
the gate logic at the start of the job uses them independently. Verify no
other step in the workflow references `post_comment` or the deleted env
keys after the edit.

**`.github/workflows/unit-tests.yml`** — two steps reference the deletion:
- "Verify python3 (test_post_comment.sh subprocesses use it)" at line 60 —
  remove this step. Python is still available on the runner for other uses,
  but this comment-step exists only to document the post_comment dependency.
- "test_post_comment" at lines 86–87 — remove. No `continue-on-error` is
  needed because the step is gone, not failing.

After both edits, run a local search to confirm no workflow YAML contains
the string `post-comment` or `post_comment`:

```bash
grep -rn "post.comment\|post_comment" \
  /home/user/k8-platform/.github/workflows/
```

Expected: zero matches.

### Idempotency and ordering

These are pure deletions. The PR is idempotent: re-applying the diff on an
already-clean branch is a no-op. No migration scripts, no state files, no
data to preserve beyond the two fixture files created in the same PR.

## 6. Tests required

Per AGENTS.md §6.1, this is a removal-only spec. The normal "author tests
alongside features" rule still applies in the form of proving the removal is
safe:

1. **Workflow syntax check** — after editing `terraform-test.yml` and
   `unit-tests.yml`, run `yamllint` or `actionlint` against both files to
   confirm they parse cleanly after the step removals.

   ```bash
   actionlint /home/user/k8-platform/.github/workflows/terraform-test.yml
   actionlint /home/user/k8-platform/.github/workflows/unit-tests.yml
   ```

2. **No remaining references** — grep confirms zero occurrences of
   `post-comment` and `post_comment` across the repo after the PR lands:

   ```bash
   git grep -rn "post.comment\|post_comment" -- \
     .github/ tests/ scripts/ AGENTS.md
   ```

3. **Fixture presence** — both fixture files exist and are non-empty:

   ```bash
   test -s tests/unit/fixtures/post_comment_rendering/expected_sections.txt
   test -s tests/unit/fixtures/post_comment_rendering/truncation_rule.txt
   ```

4. **`tests/unit/run.sh` passes** — the suite must exit 0 after
   `test_post_comment.sh` is removed from it. The remaining 17 suite
   entries must still pass.

These four checks are the gate — the spec is not done without them.

## 7. Testing suggestions (unit / integration / e2e)

### Unit

- **Rendering regression guard.** A future `test_pr_body_format.sh` (if
  `scripts/pr-body-format.sh` is ever written per A3→A6-003) would load
  `tests/unit/fixtures/post_comment_rendering/expected_sections.txt` and
  assert that every section heading appears in a sample rendered PR body.
  Not required by this spec; recorded here so the implementing agent knows
  the fixture's intended consumer.

- **No-orphan-test lint.** A future unit test could scan `tests/unit/` for
  `test_*.sh` files whose subject file (inferred from the name) no longer
  exists in the repo. `test_post_comment.sh` is precisely the class of
  orphan this lint would catch. The lint is follow-on work; note it here
  as motivation.

Not applicable for a pure deletion spec beyond the §6 required checks.

### Integration

Not applicable. The deleted files have no integration-layer surface — the
script only ran inside GitHub Actions, not against a live cluster. After
deletion, the Terraform CI workflow still runs; its integration behavior
(plan, apply, e2e verify, destroy) is unchanged. The only difference is
that the final "Post summary comment" step is gone, so no GitHub API call
is made from the workflow.

A2→A6-004 ("add an e2e regression that the in-PR-body summary appears on
every plan/apply") is deferred: it requires the agent's PR-body-writing
logic to be specified in a follow-on spec first.

### E2E

Not applicable for the deletion itself. The removed step ran at the
Actions layer, not against a Kubernetes cluster. No chainsaw scenario
exercises PR commenting behavior.

Once the replacement in-PR-body summary path exists, an e2e check that the
PR body contains the expected section headings would be appropriate.
That is follow-on work (brainstorm A2→A6-004).

## 8. Documentation updates

- **`AGENTS.md`** — add one sentence to whichever section describes the
  agent's CI reporting workflow (currently absent; add near §9 or §6.3):
  "Plan and apply output goes in the PR body directly via `gh pr edit`;
  the legacy `post-comment.py` Actions script was removed in the PR
  implementing SPEC-D1."
- **`ai/testing-guidelines.md`** — if there is an entry in the unit-test
  inventory for `test_post_comment.sh`, remove it and add a brief note:
  "test_post_comment.sh deleted; see SPEC-D1."
- No other docs reference the script by name. The `run.sh` edit is a
  functional change, not a documentation update.

## 9. Workflow / auto-invocation wiring

This spec removes automation rather than adding it. After the PR merges:

- `terraform-test.yml` no longer calls `post-comment.py` on any dispatch.
- `unit-tests.yml` no longer runs `test_post_comment.sh` on any push.
- `tests/unit/run.sh` no longer includes the test in the local suite.

No new hooks or workflow triggers are introduced. The PR-body summary
mechanism that replaces the auto-comment is an agent-behavior concern,
not a workflow concern; it requires no workflow wiring.

## 10. Discoverability

1. **Mechanical enforcement** — after this PR merges, `grep -rn
   "post-comment" .github/ tests/` returns zero results. If a future
   agent re-introduces the file without reading this spec, the grep-based
   §6 check would catch it in the PR diff review. Additionally,
   `tests/unit/run.sh` no longer contains `test_post_comment.sh`, so any
   accidentally re-added test file would be silently skipped unless the
   agent also edits `run.sh` — a forcing function to notice the removal.

2. **Documentation pointer** — `AGENTS.md` (after the §8 edit above)
   explicitly names SPEC-D1 as the record for the removal. Any agent
   reading `AGENTS.md` and wondering why there is no `post-comment.py`
   follows the citation here.

3. **Adversarial-review trigger** — §6.4 review checklist item: "Does the
   PR remove a file without proving no workflow still calls it?" is
   satisfied by the `grep` check in §6 item 2 above. The checklist item
   also applies: "Does a removal spec capture the rendering contract before
   deleting?" — satisfied by the fixture files in §4.

## 11. Verification checklist

- [ ] `test -f /home/user/k8-platform/.github/scripts/post-comment.py`
      returns non-zero (file does not exist).
- [ ] `test -f /home/user/k8-platform/tests/unit/test_post_comment.sh`
      returns non-zero (file does not exist).
- [ ] `grep -rn "post.comment\|post_comment" /home/user/k8-platform/.github/workflows/`
      returns zero lines.
- [ ] `grep "test_post_comment" /home/user/k8-platform/tests/unit/run.sh`
      returns zero lines.
- [ ] `actionlint /home/user/k8-platform/.github/workflows/terraform-test.yml`
      exits 0.
- [ ] `actionlint /home/user/k8-platform/.github/workflows/unit-tests.yml`
      exits 0.
- [ ] `test -s /home/user/k8-platform/tests/unit/fixtures/post_comment_rendering/expected_sections.txt`
      exits 0 (fixture non-empty).
- [ ] `test -s /home/user/k8-platform/tests/unit/fixtures/post_comment_rendering/truncation_rule.txt`
      exits 0 (fixture non-empty).
- [ ] `bash /home/user/k8-platform/tests/unit/run.sh` exits 0 (full suite
      passes without the deleted test).
- [ ] `grep -n "SPEC-D1" /home/user/k8-platform/AGENTS.md` returns at
      least one match (documentation update landed).

## 12. Rollback notes

If the deletion causes a regression (e.g. a downstream consumer of the
auto-comment is discovered post-merge), restore as follows:

1. **Restore `post-comment.py`** from git history:
   ```bash
   git show <merge-commit>^:.github/scripts/post-comment.py \
     > /home/user/k8-platform/.github/scripts/post-comment.py
   ```

2. **Restore `test_post_comment.sh`**:
   ```bash
   git show <merge-commit>^:tests/unit/test_post_comment.sh \
     > /home/user/k8-platform/tests/unit/test_post_comment.sh
   ```

3. **Re-add the "Post summary comment" step** to `terraform-test.yml`.
   The step content is preserved in this spec's §5 prose (the 13 env vars
   and the `python3 .github/scripts/post-comment.py` run command). The
   full original step is also recoverable via `git show`.

4. **Re-add `run_suite tests/unit/test_post_comment.sh`** to `run.sh`
   after the `test_helm_render.sh` line.

5. **Re-add the two unit-tests.yml steps** ("Verify python3" and
   "test_post_comment") after `test_helm_render`.

No database migrations, no state files, no AWS resource changes. Rollback
is a pure file restore + PR revert.

The fixture files under `tests/unit/fixtures/post_comment_rendering/`
can be left in place after rollback; they are inert and do not affect
test execution.

## 13. Estimated effort

**S** (small, approximately 1 hour).

- 15 min — capture fixtures (extract section headings and truncation rule
  from `post-comment.py` before deletion).
- 10 min — delete two files, edit three files (`terraform-test.yml`,
  `unit-tests.yml`, `run.sh`).
- 10 min — add one sentence to `AGENTS.md`, remove inventory row from
  `ai/testing-guidelines.md`.
- 15 min — run `actionlint`, `tests/unit/run.sh`, and the grep checks
  from §11.
- 10 min — PR description, review cycle.

No AWS spend. No cluster required. No cross-cutting refactor. The only
risk factor is discovering an undocumented caller of `post-comment.py`
outside the two known workflows; the §6 grep check surfaces that before
the PR merges.
