# SPEC-LB4 — `tests/regression/`: bug regression corpus directory

Brainstorm ID: `P→A2-003`. Tier B item LB4 from
`ai/brainstorming/specs/larger-list-preferences.md` §B4.

## 1. Summary

Add a `tests/regression/` directory whose layout encodes every retro'd
bug as a self-contained reproducer: one subdirectory per bug, one
assertion script per subdirectory, one discovery runner
(`tests/regression/run.sh`) that auto-discovers and executes them all.
The implementing agent creates the directory skeleton, the runner, and
the four immediate backfill reproducers (Bug 4 string transform, Bug 5
SA name, PR #59 `$UID` shadowing, PR #67 manifest hash). The runner is
wired into `tests/unit/run.sh` and `.github/workflows/unit-tests.yml`
so every future PR runs the entire corpus without any agent remembering
to invoke it. The smallest concrete artifact is
`tests/regression/run.sh` plus four populated
`tests/regression/<bug-id>/` subdirectories. This spec is standalone
(Cluster 6, per `CLUSTERING-REVIEW.md` line 28) and may be implemented
in any session after Cluster 1 is merged.

## 2. Retro pain killed

- **Bug 4 — Composition string transform type** (`retrospective/2026-05-24-62.md`
  Phase 6): `resources[0].patches[0].transforms[0].string.type: Required
  value` — the function-patch-and-transform v0.8.x validator rejects the
  entire Composition input before any managed resource renders. PR #61
  added a defending lint for existing Compositions, but that lint only
  scans YAML on disk and cannot catch the omission in a future Composition
  authored in a new session. The reproducer confirms the pre-fix shape is
  still detectable and the lint pattern still fires on it.

- **Bug 5 — Provider SA hash-suffix / IRSA trust mismatch**
  (`retrospective/2026-05-25-70.md` Phase 2): `terraform/management/irsa.tf:98`
  bound to `crossplane-system:upbound-provider-family-aws`; Crossplane
  generated `provider-family-aws-24aaab54a3a0` because
  `DeploymentRuntimeConfig.spec.serviceAccountTemplate.metadata.name`
  was unpinned. `AssumeRoleWithWebIdentity` failed silently; the XR
  stayed `Ready=False` for an entire session. The reproducer asserts the
  SA name field is non-empty in the canonical manifest on every push.

- **PR #59 — `$UID` readonly-builtin shadowing** (`retrospective/2026-05-24-62.md`
  Phase 5): `UID=$(kubectl get ...)` silently failed under `set -u`; every
  claim key became `k8-platform/1001`; the script still printed `PASS:`
  because `set -e` was absent. Two defending lints were added (TDD).
  The reproducer instantiates the exact failure — proves bash silently
  ignores `UID=` — and scans `tests/integration/` for any recurrence.

- **PR #67 — `terraform_data` manifest hash silent no-op**
  (`retrospective/2026-05-25-70.md` Phase 2): editing the
  `DeploymentRuntimeConfig` manifest without adding `sha256(local.manifest)`
  to `triggers_replace` produced `Apply complete! Resources: 0 added, 0
  changed, 0 destroyed.` — a green CI run that changed nothing on the
  cluster. The reproducer asserts every manifest-referencing `terraform_data`
  block in `helm.tf` includes a `sha256()` trigger.

## 3. Out of scope

- **Running reproducers that require a live cluster or AWS credentials.**
  Every reproducer in `tests/regression/` MUST be runnable with local
  tooling only (bash, yq, awk, python3). Tests requiring kubectl, kind,
  or AWS CLI belong in `tests/integration/` or `tests/chainsaw/` and
  are out of scope here. Reason: the regression corpus runs on every
  push via `unit-tests.yml`; it cannot gate on a live environment.

- **Full integration or chainsaw-level regression coverage.** The
  corpus captures the *minimal* reproducer — the smallest test that
  would have caught the bug at the layer closest to authoring time
  (usually unit/static). Full integration regression is the job of
  `tests/integration/` and the chainsaw scenarios. Reason: keeping
  reproducers tiny maximizes longevity — a 10-line bash test that
  exercises one schema rule will still work in five Crossplane major
  versions.

- **Retroactively cataloguing every bug ever fixed.** Only bugs with a
  clear retro citation (file + phase) are included. Speculation-without-
  citation is not a bug-of-record. Reason: §2 of the SPEC-TEMPLATE
  policy — pain must be documented before it earns a defending test.

- **Replacing existing defending lints.** This corpus supplements
  `test_composition_string_transform_type.sh`, `test_shell_readonly_var_assignment.sh`,
  etc. — it does not replace them. Each layer catches the contract at a
  different lifecycle moment. Reason: defense in depth.

### Considered and rejected

- **Single monolithic regression test file** (`tests/unit/test_regressions.sh`):
  rejected because it makes CI output unreadable (one failing test name
  gives no hint which bug regressed) and makes future additions require
  editing a shared file (merge conflicts, cognitive load). One directory
  per bug scales indefinitely.

- **Storing reproducers as chainsaw scenarios**: the corpus must be
  environment-free (see first bullet above). Chainsaw requires a kind
  cluster. Rejected.

- **Numbered bug IDs derived from PR numbers** (e.g. `pr-059/`): PR
  numbers are not self-describing. Using canonical bug names
  (`bug-4-string-transform/`, `pr-59-uid-shadow/`) makes the directory
  listing human-readable without looking up context. Adopted.

## 4. Files to change / create

### Create

| Path | Purpose |
|------|---------|
| `/home/user/k8-platform/tests/regression/run.sh` | Discovery runner — auto-discovers every `tests/regression/*/repro.sh`, runs each, aggregates exit codes. |
| `/home/user/k8-platform/tests/regression/bug-4-string-transform/README.md` | One-paragraph bug narrative, root-cause citation, test rationale. |
| `/home/user/k8-platform/tests/regression/bug-4-string-transform/repro.sh` | Reproducer: synthesize a minimal Composition YAML fragment with a `type: string` transform missing `.string.type`; assert `yq` extracts the path and it is empty or missing; assert the existing lint catches it. |
| `/home/user/k8-platform/tests/regression/bug-5-sa-name/README.md` | Bug narrative for IRSA SA hash-suffix. |
| `/home/user/k8-platform/tests/regression/bug-5-sa-name/repro.sh` | Reproducer: synthesize a `DeploymentRuntimeConfig` YAML with no `.spec.serviceAccountTemplate.metadata.name`; assert `yq` extracts the field and it is empty/null; confirm the pattern the IRSA trust check would reject. |
| `/home/user/k8-platform/tests/regression/pr-59-uid-shadow/README.md` | Bug narrative for `$UID` readonly-builtin shadowing. |
| `/home/user/k8-platform/tests/regression/pr-59-uid-shadow/repro.sh` | Reproducer: in a subshell, attempt `UID=sentinel`; assert `$UID` does NOT equal `sentinel` (proving the shadow failed); assert the scenario produces a wrong key if unchecked. |
| `/home/user/k8-platform/tests/regression/pr-67-manifest-hash/README.md` | Bug narrative for `terraform_data` manifest hash silent no-op. |
| `/home/user/k8-platform/tests/regression/pr-67-manifest-hash/repro.sh` | Reproducer: parse `terraform/management/helm.tf` with `grep`/`awk`; for every `terraform_data` block that has a `content` referencing a `local.*manifest` variable, assert `triggers_replace` contains `sha256(`; exit non-zero if any block is missing the hash. |

### Modify

| Path | Change |
|------|--------|
| `/home/user/k8-platform/tests/unit/run.sh` | Append `run_suite tests/regression/run.sh` after the last existing `run_suite` line. |
| `/home/user/k8-platform/.github/workflows/unit-tests.yml` | Add a `- name: regression-corpus` step that runs `bash tests/regression/run.sh`, following the per-test step pattern already established. |

### Directory layout (canonical shape per bug)

```
tests/regression/
  run.sh                          # discovery runner
  bug-4-string-transform/
    README.md                     # bug narrative + retro citation
    repro.sh                      # executable reproducer + assertions
  bug-5-sa-name/
    README.md
    repro.sh
  pr-59-uid-shadow/
    README.md
    repro.sh
  pr-67-manifest-hash/
    README.md
    repro.sh
```

Every future retro'd bug adds one subdirectory following this same
shape. No other files required.

## 5. Implementation notes

### 5.1 `tests/regression/run.sh` — discovery and execution

The runner `cd`s to the repo root, then uses `find tests/regression
-name 'repro.sh' -not -path '*/fixtures/*' | sort` to auto-discover
every reproducer in deterministic order. For each hit it runs
`bash "$repro"`, prints `PASS: <bug-name>` or `FAIL: <bug-name>`,
accumulates a non-zero exit in `OVERALL`, and prints a final summary.
Pattern mirrors `tests/unit/run.sh`'s `run_suite` loop.

Reproducers run with the repo root as working directory. They may
assume `yq`, `bash`, `grep`, `awk`, `python3` on PATH (present on CI
runners and local dev per existing unit tests). No kubectl, no AWS CLI,
no kind.

### 5.2 Individual `repro.sh` conventions

Each reproducer must:

1. Begin with `#!/usr/bin/env bash` + `set -euo pipefail`.
2. Print `PASS: <description>` for every assertion that passes.
3. Print `FAIL: <description>` and exit non-zero on any assertion failure.
4. Use only local tools — no network, no cluster, no cloud credentials.
5. Be idempotent and side-effect-free (no file writes outside `/tmp`,
   no state changes).

Exit codes: `0` = all assertions pass; non-zero = at least one failure.
The runner treats any non-zero exit as a corpus failure.

### 5.3 `bug-4-string-transform/repro.sh` design

Write a minimal Composition YAML fragment to a `mktemp` file (with
`trap rm EXIT`) that has `type: string` under `transforms:` but no
`.string.type` field. Assert two things: (a) `yq
'.patches[0].transforms[0].string.type // "MISSING"'` returns
`"MISSING"` (pre-fix shape confirmed), and (b) the grep pattern from
`test_composition_string_transform_type.sh` fires on the fragment —
`grep -E 'type:[[:space:]]*string'` matches AND `grep -E
'type:[[:space:]]*(Format|Convert|Regexp|TrimPrefix|TrimSuffix)'` does
not. If either check fails the reproducer exits non-zero, indicating
the defending lint's pattern has drifted from the bug's actual shape.

### 5.4 `bug-5-sa-name/repro.sh` design

Locate `crossplane/providers/deployment-runtime-config.yaml` (error
if absent). Run `yq '.spec.serviceAccountTemplate.metadata.name //
""'` and assert the result is non-empty. If the field is dropped by a
future PR the reproducer exits non-zero before the next apply cycle
reveals the IRSA trust mismatch.

### 5.5 `pr-59-uid-shadow/repro.sh` design

Two assertions: (a) in a subshell, run `bash -c 'UID=sentinel
2>/dev/null; echo "$UID"'` and assert the result is NOT `"sentinel"` —
proving bash silently ignores the readonly-assign, which is the bug's
root cause; (b) `grep -rn '^[[:space:]]*UID=' tests/integration/`
returns zero matches — proving the post-fix state holds. Exit non-zero
if either assertion fails.

### 5.6 `pr-67-manifest-hash/repro.sh` design

Parse `terraform/management/helm.tf`. For every `local.*manifest*`
variable name found with `grep -oE 'local\.[a-z_]*manifest[a-z_]*'`,
assert that `sha256(local.<name>)` appears somewhere in the same file
(in a `triggers_replace` block). Exit non-zero naming the offending
local if any is missing. Performance: grep over a ~500-line file,
sub-second.

### 5.7 README.md format per bug

Each `README.md` has exactly four sections (no headers beyond these):

```
Bug ID: <canonical name>
Retro citation: <path/to/retro.md> Phase N
Root cause: <one sentence>
Test rationale: <one sentence explaining what the repro.sh asserts and why it's the right layer>
```

Keeping READMEs minimal ensures they stay accurate as the codebase
evolves. Long narratives live in the retrospectives; the README is a
pointer, not a duplicate.

### 5.8 Performance and cross-references

All four reproducers run in well under 1 second each (grep, yq, bash
subshells). Total corpus time including runner overhead: target <5s.
No network, no disk writes beyond `/tmp`.

The PR #59 reproducer is the runtime complement to SPEC-B1's static
lint; the PR #67 reproducer is the runtime complement to SPEC-B3's
author-time lint. Both pairs defend the same bug class at different
lifecycle moments (static-analysis vs live-repo-state).

## 6. Tests required

Per AGENTS.md §6.1 and §6.2:

| Layer | File | Assertion |
|-------|------|-----------|
| Unit (meta) | `tests/regression/run.sh` (self-executing) | Runner discovers all four `repro.sh` files and exits 0 on the current repo state (post-fix). |
| Unit (regression) | `tests/regression/bug-4-string-transform/repro.sh` | Asserts pre-fix YAML shape is detectable by yq; asserts defending lint pattern fires on that shape. Fails if either check breaks. |
| Unit (regression) | `tests/regression/bug-5-sa-name/repro.sh` | Asserts `.spec.serviceAccountTemplate.metadata.name` is non-empty in the canonical manifest. Fails if field is dropped. |
| Unit (regression) | `tests/regression/pr-59-uid-shadow/repro.sh` | Asserts bash readonly behavior for `$UID`; asserts zero `UID=` assignments in `tests/integration/`. |
| Unit (regression) | `tests/regression/pr-67-manifest-hash/repro.sh` | Asserts every manifest-referencing `terraform_data` block has `sha256(local.*)` in `triggers_replace`. |

Per AGENTS.md §6.4: before authoring the repro scripts, spawn one
adversarial-reviewer subagent briefed on the four bug patterns and the
planned repro approach. The subagent's brief should identify: (a) any
assertion that would trivially pass even with the bug present, (b) any
assumption about the current repo shape that could silently change
(e.g. manifest path moves), (c) whether the `pr-67` grep is robust
against multi-block TF files with interleaved locals.

## 7. Testing suggestions (unit / integration / e2e)

**Unit** — The four `repro.sh` scripts ARE the unit layer. Additional
cases worth adding as the corpus matures:

1. `tests/unit/test_regression_runner.sh` — meta-test for `run.sh`:
   assert the runner discovers exactly N reproducers, that a synthetic
   always-failing `repro.sh` causes a non-zero exit, and that the
   `FAIL:` output names the bug directory.
2. `tests/regression/pr-67-manifest-hash/fixtures/should_fail.tf` — a
   TF snippet with a manifest local and no sha256; assert the reproducer
   flags it. Mirrors the SPEC-B1 fixture pattern.

**Integration** — Not applicable. All reproducers are environment-free
by design (§3 constraint) and run fully in the unit layer. The same
bug classes are already covered at integration depth by
`tests/integration/11_platform_secret_e2e.sh` (PR #59 class) and the
management apply-and-verify workflow (PR #67 class).

**E2E** — Not applicable. The corpus is a static-analysis layer that
must run without a cluster. Composition-level E2E coverage lives in
`tests/chainsaw/`; IRSA/manifest E2E coverage lives in
`terraform-test.yml`. Routing them here would violate §3.

## 8. Documentation updates

- `AGENTS.md` §6.1 — add a row to the test-layers table:
  `| Regression corpus | for every retro'd bug | tests/regression/<bug-id>/repro.sh |`
  and a note that the corpus auto-runs via `tests/regression/run.sh`,
  wired into `tests/unit/run.sh`.
- `ai/testing-guidelines.md` — add a subsection "Regression corpus
  (`tests/regression/`)" describing the one-directory-per-bug layout,
  the `README.md` four-field format, the environment-free constraint,
  and the naming convention (`bug-N-<slug>/` or `pr-NN-<slug>/`).
- `AGENTS.md` §6.2 — add after step 5: "If the bug has a retro citation
  and an environment-free reproducer is possible, also add
  `tests/regression/<bug-id>/repro.sh` per SPEC-LB4."

## 9. Workflow / auto-invocation wiring

- `tests/unit/run.sh`: append `run_suite tests/regression/run.sh` after
  the last existing `run_suite` line. This enrolls the corpus in every
  push via `unit-tests.yml`.
- `.github/workflows/unit-tests.yml`: add a `- name: regression-corpus`
  step running `bash tests/regression/run.sh`, matching the per-test
  step pattern for diagnosable CI output.
- The runner requires no secrets, no environment variables, no cluster —
  identical behavior on CI and developer laptop. No new workflow file.

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/run.sh` invokes
   `tests/regression/run.sh` on every push. If a future PR drops the
   SA name pin, removes the `sha256()` from `triggers_replace`, or
   re-introduces a `UID=` assignment in integration scripts, the
   corresponding `repro.sh` exits non-zero and the `unit-tests.yml`
   check goes red. No human needs to remember to run the corpus.

2. **Documentation pointer** — `AGENTS.md` §6.1 (test-layers table,
   updated per §7) and `AGENTS.md` §6.2 (step-5 addendum) both point
   at `tests/regression/` and SPEC-LB4. A future agent scanning §6.1
   for test layer obligations lands on this spec without searching.

3. **Adversarial-review trigger** — per `AGENTS.md` §6.4, when any
   agent drafts tests for a bug fix, the adversarial reviewer's brief
   must include: "Does a `tests/regression/<bug-id>/repro.sh`
   already exist for this bug class? If not, propose one." This
   checklist item surfaces the corpus as an expected artifact for every
   future bug fix.

## 11. Verification checklist

- [ ] `bash tests/regression/run.sh` exits 0 from the repo root.
- [ ] `bash tests/unit/run.sh` includes the regression corpus in its
      output (`── regression: bug-4-string-transform ──` etc.) and
      overall exits 0.
- [ ] `find tests/regression -name 'repro.sh' | wc -l` returns 4
      (one per initial backfill bug).
- [ ] `find tests/regression -name 'README.md' | wc -l` returns 4.
- [ ] Each `README.md` contains the four required fields (Bug ID,
      Retro citation, Root cause, Test rationale); verify with
      `grep -l "Retro citation" tests/regression/*/README.md | wc -l`
      returning 4.
- [ ] Manual: temporarily remove `.spec.serviceAccountTemplate.metadata.name`
      from `crossplane/providers/deployment-runtime-config.yaml`, run
      `bash tests/regression/bug-5-sa-name/repro.sh`, confirm exit 1
      and `FAIL:` output. Revert.
- [ ] Manual: temporarily add `UID=foo` to
      `tests/integration/11_platform_secret_e2e.sh`, run
      `bash tests/regression/pr-59-uid-shadow/repro.sh`, confirm exit 1.
      Revert.
- [ ] Manual: temporarily remove a `sha256(local.*manifest*)` reference
      from a `triggers_replace` block in `terraform/management/helm.tf`,
      run `bash tests/regression/pr-67-manifest-hash/repro.sh`, confirm
      exit 1 naming the affected local. Revert.
- [ ] `grep 'regression/run.sh' tests/unit/run.sh` returns one match.
- [ ] `.github/workflows/unit-tests.yml` contains a `regression-corpus`
      step.

## 12. Rollout notes

**Backward-compat:** the `run_suite` addition to `tests/unit/run.sh` is
purely additive. The corpus exits 0 on the current repo state (all four
bugs already fixed) so CI lands green on day one without an audit pass.

**Audit-before-merge:** run `bash tests/regression/run.sh` locally before
wiring. If a reproducer exits non-zero the assertion is wrong — it should
confirm the post-fix invariant, not reproduce the pre-fix failure.

**Pluralsight sandbox constraints:** orthogonal. Pure static analysis,
no AWS quota consumed.

**In-flight branch coordination:** SPEC-LB4 is standalone (Cluster 6,
`CLUSTERING-REVIEW.md` line 28). No merge dependency on Clusters 1–5.
Landing before SPEC-B1/B3 is safe — the reproducers reference the live
repo, not the new lint files those specs create.

## 13. Estimated effort

**S** (small, ≤1 hr).

Breakdown:

- 20 min: author `tests/regression/run.sh` and the four `repro.sh`
  scripts with their `README.md` files (all straightforward bash +
  yq with well-understood assertions).
- 10 min: adversarial-reviewer subagent brief and adoption of
  suggestions (single subagent acceptable per AGENTS.md §6.4 for
  small standalone additions).
- 10 min: wire into `tests/unit/run.sh` and
  `.github/workflows/unit-tests.yml`; run the corpus locally to
  confirm exit 0.
- 10 min: doc updates (AGENTS.md §6.1/§6.2, ai/testing-guidelines.md)
  and PR review cycle.
- 5 min: manual reversal tests per §11 checklist items 6–8.

Total: ~55 minutes elapsed, single session. No AWS spend. No cross-
cutting refactor.
