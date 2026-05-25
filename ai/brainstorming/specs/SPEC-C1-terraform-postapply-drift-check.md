# SPEC-C1 — `terraform-test.yml` `apply-and-verify`: post-apply `terraform plan -detailed-exitcode` drift check

Status: DRAFT (spec only — no implementation in this PR)
Branch: `spec/top-15-immediate-changes`
Owner: next agent picking up CI hardening work

---

## 1. Summary

Add a step to `.github/workflows/terraform-test.yml` that, immediately after
each `terraform apply` succeeds, runs `terraform plan -detailed-exitcode`
against the just-applied state. Exit code `0` (no diff) is the expected
outcome and lets the workflow proceed; exit code `2` (drift) fails the
`apply-and-verify` job and surfaces the offending plan inline so the agent
sees the mismatch in the **same** run that produced it. Exit code `1`
(plan errored) also fails the step.

---

## 2. Retro pain killed

**PR #67 — "silent partial apply".** PR #66's manifest edit was a no-op at
apply time because
`terraform_data.crossplane_aws_provider.triggers_replace` only watched the
IRSA arn and provider version — not the manifest body. The apply ran,
reported `Apply complete! Resources: 0 added, 0 changed, 0 destroyed`,
and the workflow turned green. The intended `DeploymentRuntimeConfig`
edit never reached the cluster. The drift only surfaced on the *next*
push, when a different change re-triggered the resource and finally
applied PR #66's body too — by which point the misdiagnosis had already
cost a debug loop.

Generalised, this is the **"Apply complete: 0 added" misread class**
called out in `ai/handoff.md`:

> "It applied successfully" ≠ "the change reached the cluster". Three
> times this session a green apply did not produce the intended cluster
> state.

A post-apply `terraform plan -detailed-exitcode` would have failed the
PR #66 workflow run inline. The apply step would have reported
"0 added/changed/destroyed", and the immediately-following post-apply
plan would have re-detected the still-pending manifest diff (because
the `triggers_replace` hash *would* have flipped on the next plan after
state refresh discovered the existing resource's stored body differed
from the new manifest literal). The agent could not have missed it.

---

## 3. Out of scope

This spec is narrow on purpose. It does **NOT**:

- **Validate that the apply matches user intent.** A green post-apply
  plan only proves `state == config`. If the config itself is wrong
  (e.g. the wrong manifest body committed), this check passes happily.
  Intent validation is the job of unit tests
  (`tests/unit/test_*_*.sh`), Kyverno audit policies
  (`policies/audit/*.yaml`), and the integration suite
  (`tests/integration/*.sh`).
- **Cover Kubernetes-side drift.** Once an apply lands a Crossplane
  Composition or an ArgoCD Application, ongoing drift between the
  declared manifest and the live cluster object is **ArgoCD's job**
  (selfHeal, OutOfSync detection). Terraform's plan does not see
  in-cluster mutations; do not extend this step to try.
- **Catch state-corruption / out-of-band edits made between runs.**
  Those are surfaced by the *next* regular `plan` action. This step
  is specifically about the **single-run round-trip**: did the apply
  we just ran leave state and config in agreement?
- **Re-apply** anything. The post-apply plan is read-only; on drift,
  the agent fixes the upstream cause (usually a `triggers_replace`
  gap) and dispatches a new apply.

---

## 4. Files to change

Single file: **`.github/workflows/terraform-test.yml`**.

Two new steps, one per module, inserted in the existing job:

| Insertion point (after) | New step `id`            | Module     |
|-------------------------|--------------------------|------------|
| `apply_base`            | `postapply_plan_base`    | base       |
| `apply_management`      | `postapply_plan_mgmt`    | management |

Each step runs **only** when its corresponding `apply_*` step's outcome
is `success` AND the gate that fired the apply (`base_apply` /
`mgmt_apply`) is `true`. It runs **before** the matching
`e2e-verify` step so a drift failure short-circuits the rest of the
pipeline and the verification work is not wasted on a known-bad apply.

The matching `Post summary comment` step (currently lines 501–519)
gains two more env vars:
- `POSTAPPLY_PLAN_BASE_OUTCOME: ${{ steps.postapply_plan_base.outcome }}`
- `POSTAPPLY_PLAN_MGMT_OUTCOME: ${{ steps.postapply_plan_mgmt.outcome }}`

so `post-comment.py` can render them in the per-step outcome table.
The `STEP_LABELS` / `OUTCOMES` keys-equal invariant in
`tests/unit/test_post_comment.sh` (per `ai/TESTING-PLAN.md`
bug-class registry) automatically requires both sides to be updated
in lockstep — the existing unit test enforces this.

No other workflows are touched. No other directories are touched
(no `terraform/`, no `crossplane/`, no `tests/` source — but see
§6 for **test additions** that *will* land alongside the
implementation PR).

---

## 5. Implementation notes

### Command shape

Per-module, run inside `working-directory: terraform/<module>`:

```bash
set +e
terraform plan -detailed-exitcode -no-color -lock=false \
  -out=postapply.tfplan 2>&1 | tee "${RUNNER_TEMP}/<module>-postapply-plan.txt"
EC=${PIPESTATUS[0]}
set -e
echo "exit_code=${EC}" >> "$GITHUB_OUTPUT"
```

`-lock=false` is safe here because the apply step that just completed
already released the lock; we are reading state, not mutating it.
`-out=postapply.tfplan` is written so the plan body is preserved as
an artifact even when the step's stdout is later truncated.

### Exit-code handling

- `0` — no diff. Step exits 0. Workflow proceeds to `e2e-verify`.
- `1` — plan failed (Terraform error: provider crash, malformed
  config, transient AWS API error). Step exits 1. The taxonomy entry
  is the same as a normal plan failure — fix and re-dispatch.
- `2` — drift detected. Step exits 1 (so the job fails). The plan
  body (truncated, see below) is written to `$GITHUB_STEP_SUMMARY`
  so the failure is visible without descending into raw logs.

### Output exposure

The full plan body is uploaded as a workflow artifact, addressable
via `${{ steps.postapply_plan_<module>.outputs.plan }}` semantics —
the step writes the path to `$GITHUB_OUTPUT` so downstream consumers
(the summary-comment poster, future debug skills) can read it without
re-parsing logs.

In the inline step summary, keep the body **≤5 KB** (truncate with
`head -c 5000` and append `... [truncated; see artifact <name>]`
when triggered). 5 KB is empirically large enough for the typical
1–3-resource drift report and small enough not to overwhelm the
GitHub Actions summary UI, which clips long messages.

### Rerun budget — idempotent helm releases that briefly drift

Some `helm_release` resources legitimately re-render slightly between
plans — Crossplane in particular reconciles its packages a few seconds
after a chart upgrade, and the *next* plan may see a one-line change
to a `metadata.generation`-derived field before settling. To avoid
flapping the workflow on this transient class:

1. First run of `postapply_plan_<module>` after `apply_<module>`:
   if exit code is `2`, **sleep 60 seconds**, then re-run the plan
   **once**.
2. If the second plan also exits `2`, fail the step with the
   second plan's body as evidence.
3. If the second plan exits `0`, log the first plan body (so the
   transient is still visible in the run history) but pass the
   step.

The 60-second window is calibrated to Crossplane's default
`--poll-interval=1m` and is short relative to the management
apply's ~15-minute wall clock; total worst-case overhead per
run is one extra minute.

If, over time, a specific resource is found to drift legitimately
on every apply (not transiently), the right fix is **upstream** —
either pin the field, add it to `lifecycle.ignore_changes`, or
restructure the resource — not to extend the retry budget here.

---

## 6. Tests required

Per `AGENTS.md §6.1` (maximal coverage) and `§6.2` (TDD on bug
fixes — PR #67's bug is what this spec defends against, so a
regression-catching test is mandatory).

### Unit (must)

`tests/unit/test_workflow_postapply_plan_present.sh` — parses
`.github/workflows/terraform-test.yml` with `yq` and asserts:

- A step with `id: postapply_plan_base` exists after the step with
  `id: apply_base` and before the step with `id: e2e_base`.
- A step with `id: postapply_plan_mgmt` exists after the step with
  `id: apply_management` and before the step with `id: e2e_management`.
- Both steps' commands contain the literal
  `plan -detailed-exitcode`.
- Both steps run conditionally on the matching apply step's
  `outcome == 'success'`.
- The retry/sleep loop is present (look for the `sleep 60` literal
  and a second plan invocation).

This is a pure-local lint; runs as part of `tests/unit/run.sh`.

### Fixture branch (must — reproduces PR #67 directly)

A dedicated fixture under `tests/fixtures/postapply-drift/` containing:

- A minimal `terraform/` snippet with a `terraform_data` resource
  whose `triggers_replace` deliberately does NOT watch a sibling
  manifest file.
- A second commit on the fixture branch that edits the manifest
  body without changing anything `triggers_replace` watches.

The integration assertion: dispatch `apply-and-verify` against the
fixture, and **the new `postapply_plan_*` step must fail** with
exit code `2`. If it passes, the spec is unimplemented or the
retry budget is masking the bug.

Lives at `tests/integration/12_postapply_drift_repro.sh` and is
opt-in (the bug-class CI runs it explicitly; the regular phase
bring-up does not, to avoid cost).

### Adversarial subagent review

Per `AGENTS.md §6.4`, when the implementation PR adds the test
plan above it MUST first spawn an adversarial-reviewer subagent
with the brief template from §6.4. The reviewer should hammer on
at least:

- "What if the plan diff is in a `data` source refresh, not a
  managed resource? Does the step still fire?"
- "What if `-lock=false` collides with a concurrent dispatch?"
- "What if the retry window of 60s spans an ArgoCD reconcile that
  itself causes a Provider CRD update Terraform sees on the
  second plan?"
- "What if `postapply_plan_*` itself crashes mid-run — does the
  workflow fail open or closed?"

Adopt every concrete suggestion or document a one-line dismissal
in the PR body.

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast, local, no cluster required. Names follow `tests/unit/test_<name>.sh`.

1. `tests/unit/test_workflow_postapply_plan_present.sh` — assert both
   `postapply_plan_base` and `postapply_plan_mgmt` steps exist, carry
   `plan -detailed-exitcode`, and are conditioned on `outcome == 'success'`
   of the preceding apply step. (Overlaps §6 gate test; this copy is the
   discovery-catalogue entry.)
2. `tests/unit/test_postapply_exit_code_mapping.sh` — feed synthesised
   exit codes `0`, `1`, and `2` into the step shell fragment and assert
   the expected workflow-step exit code and `$GITHUB_OUTPUT` content.
3. `tests/unit/test_postapply_summary_truncation.sh` — pipe a 10 KB plan
   body through the truncation logic and assert the output is ≤5 KB with
   the `... [truncated; see artifact ...]` trailer appended.
4. `tests/unit/test_post_comment_postapply_keys.sh` — extend the existing
   `STEP_LABELS`/`OUTCOMES` keys-equal invariant test to cover both
   `POSTAPPLY_PLAN_BASE_OUTCOME` and `POSTAPPLY_PLAN_MGMT_OUTCOME` env
   vars added to `post-comment.py`.
5. `tests/unit/test_retry_sleep_present.sh` — grep the workflow YAML for
   the `sleep 60` literal and a second `terraform plan` invocation within
   the same step body; assert both are present.

### Integration

Requires a local kind cluster or the Pluralsight sandbox (us-east-1 /
us-west-2). Names follow `tests/integration/<NN>_<name>.sh`. These are
opt-in and are not run in the regular phase bring-up to avoid cost.

1. `tests/integration/12_postapply_drift_repro.sh` — dispatches
   `apply-and-verify` against the fixture at
   `tests/fixtures/postapply-drift/` (§6 gate) and asserts the
   `postapply_plan_*` step exits non-zero (exit code `2` detected).
2. `tests/integration/13_postapply_drift_fixed.sh` — same fixture,
   after a manifest-hash-aware `triggers_replace` is patched in; asserts
   the post-apply plan exits `0`.
3. `tests/integration/14_postapply_transient_retry.sh` — injects a
   synthetic one-shot plan diff (exit `2` on first call, `0` on second)
   and asserts the step sleeps, retries, and ultimately passes with a
   logged warning about the transient.

N/A for a fourth or fifth case at this layer: the three cases above cover
the full exit-code matrix (`0`, transient-`2`-then-`0`, persistent-`2`)
and adding more would duplicate unit-level assertions at a higher cost.

### E2E

Full-stack, against a deployed phase-N cluster. Names follow
`tests/chainsaw/<scenario>/chainsaw-test.yaml` or `tests/e2e/<name>/`.

E2E is **not applicable** for this spec. The post-apply plan step is a
CI workflow concern, not a cluster-state concern. Chainsaw scenarios
exercise live Crossplane / ArgoCD resource lifecycles; there is no
cluster-state assertion this spec could make that is not already covered
by the integration layer above. Adding a chainsaw wrapper here would add
cost and complexity without increasing coverage. If a future spec wires
the drift-check output into an ArgoCD out-of-sync event, an E2E test
would then be warranted.

---

## 8. Documentation updates

When the implementation PR lands:

- **`AGENTS.md §5` (Phase workflow)** — the current text doesn't
  describe individual workflow steps, so likely no change is
  required. If a sentence is added describing
  `apply-and-verify`, mention that drift is now caught inline.
- **`ai/testing-guidelines.md §3` (phase-loop)** — under
  "State = `code-only` or `plan-green`", add a sentence:
  "`apply-and-verify` now includes an inline post-apply
  `terraform plan -detailed-exitcode`; a failure here means the
  apply produced state that disagrees with config — usually a
  missing `triggers_replace` hash; see PR #67."
- **`ai/testing-guidelines.md §5` (action wall-clock reference)** —
  bump the `apply-and-verify management` line by ~1–2 min to
  account for the post-apply plan + worst-case retry.
- **`ai/TESTING-PLAN.md` (bug-class registry)** — add a row:
  `"Silent partial apply (triggers_replace gap; apply reports
  0 added/changed/destroyed)" | "post-apply plan -detailed-exitcode
  step in terraform-test.yml" | "drift body emitted inline as run
  evidence"`.
- **`.claude/skills/terraform-ci-watch/reference/failure-taxonomy.md`** —
  add an entry: "post-apply plan exit 2 = silent-partial-apply; do
  not retry the apply blindly; trace from the drift body back to the
  resource whose `triggers_replace` is incomplete."

---

## 9. Workflow / auto-invocation wiring

`apply-and-verify` is already the canonical phase bring-up action
per `AGENTS.md §5` and `ai/handoff.md`'s NEW SESSION QUICKSTART
(Steps 2 and 3). Every fresh-account bring-up runs it. Every phase
`apply` in steady state runs it. There is no new wiring to add —
the new step lives **inside** an action that is already invoked
on every phase touchpoint.

This is by design: the spec must not depend on the agent
remembering to dispatch a separate "drift-check" workflow. The
drift check rides on the existing critical path.

---

## 10. Discoverability for future agents

The implementation buys discoverability automatically:

1. A failed `apply-and-verify` shows the failing step name
   (`[base] postapply-plan` or `[management] postapply-plan`)
   in the GitHub Actions run UI's red badge. The label itself
   tells the agent "this is a drift check, not an apply failure".
2. The truncated plan body in `$GITHUB_STEP_SUMMARY` is visible
   without log-fetch — the first place an agent looks.
3. The full plan is in `${{ steps.postapply_plan.outputs.plan }}`
   artifact form for the `terraform-ci-watch` skill to consume.
4. The summary-comment poster surfaces both outcomes in its
   per-step table, so the PR / commit comment shows the failure
   without the reviewer needing to open the workflow run.

There is no path by which an agent can complete `apply-and-verify`
green while drift exists, short of physically deleting the step
from the workflow — which the unit test in §6 rejects at
authoring time.

---

## 11. Verification checklist

Before marking the implementation PR ready:

- [ ] `tests/unit/test_workflow_postapply_plan_present.sh` exists
      and passes locally via `tests/unit/run.sh`.
- [ ] Adversarial subagent (§6.4) run and findings either adopted
      or explicitly dismissed in PR body.
- [ ] Fixture branch under `tests/fixtures/postapply-drift/`
      reproduces PR #67's failure mode and the new step **fails**
      against the unfixed fixture (red).
- [ ] Same fixture, after a manifest-hash-aware `triggers_replace`
      is added to the fixture's `terraform_data`, makes the step
      pass (green).
- [ ] `apply-and-verify` on `phase=base` against the test account
      passes with the new step green (exit code 0).
- [ ] `apply-and-verify` on `phase=management` against the test
      account passes with the new step green (exit code 0). The
      step's wall-clock overhead is observed and recorded — if
      >2 min, revisit the retry budget.
- [ ] `ai/handoff.md` "Behavioral rule additions" section gets a
      new bullet: "Silent partial apply is now caught inline by
      the post-apply drift step. If `apply-and-verify` is green,
      state and config agree."
- [ ] `post-comment.py`'s `STEP_LABELS` / `OUTCOMES` keys-equal
      invariant unit test still passes (it MUST, because both
      sides were updated together).

---

## 12. Rollout notes

- **Idempotent helm-release transient drift.** Crossplane's chart
  occasionally re-renders a `metadata.generation`-derived field on
  the first post-apply plan. The retry/sleep window in §5 (60s
  sleep, one retry) is the proposed mitigation. Tune via
  observation, not preemptively. If after the first month the
  retry is consistently unused, drop it; if it's consistently
  hit on a specific resource, fix that resource's lifecycle
  upstream rather than extending the retry.
- **Rollout sequencing.** Land the unit test first, in a tiny
  PR, with the workflow change failing it (red). Then the
  workflow change in a follow-up PR makes it green. This is
  the §6.2 TDD discipline applied to the spec's own
  implementation.
- **No backfill needed.** The drift check is a forward-looking
  gate; existing state that has been live for months may or may
  not have residual drift, and the first post-apply plan against
  it will reveal the truth. That is the desired behaviour, not
  a bug — fix any surfaced drift before marking the phase
  re-verified.
- **Sandbox compliance.** No new AWS resources are provisioned
  by this step; it only reads state (`terraform plan`). Stays
  inside Pluralsight sandbox limits
  (`ai/aws-test-environment-limitations.md`) — no region change,
  no instance, no IAM principal. Adds approximately one
  Terraform plan's worth of AWS Read API calls per
  `apply-and-verify`.

---

## 13. Estimated effort

**S** (small).

- Workflow YAML edit: ~30 minutes including the retry/sleep
  block and `$GITHUB_OUTPUT` plumbing.
- Unit test: ~30 minutes.
- Fixture + integration repro: ~1–2 hours (most of the time is
  in shaping the fixture to be deterministic).
- Docs updates (§8): ~30 minutes.
- Adversarial review + adoption: ~1 hour.

Total: half a day of focused work. Pays for itself the first
time it catches a silent partial apply.
