# SPEC-A5 — terraform-ci-watch: intent-vs-reality diff on apply failure or silent no-op

## 1. Summary

Extend the `terraform-ci-watch` skill so that after a Terraform apply
step either fails OR completes with a suspicious "0 added, 0 changed,
0 destroyed" outcome, the skill fetches the post-apply state, re-runs
`terraform plan -detailed-exitcode`, and renders a compact structured
diff of *what was supposed to change* (the pre-apply plan) vs *what
actually changed* (the post-apply replan). The output names the
specific resource addresses that were intended to move but did not —
killing the PR #67 class of silent no-op where a `terraform_data`
`triggers_replace` miss let an apply report green while the intended
manifest edit never reached the cluster.

## 2. Retro pain killed (cite PR #67 with line evidence)

- **PR #67 — `triggers_replace` miss** (`ai/handoff.md:51`):
  *"PR #66's YAML edit was a no-op at apply time.
  `terraform_data.crossplane_aws_provider.triggers_replace` only watched
  the IRSA arn + provider version, not the manifest body. Extracted
  manifest into `local.crossplane_aws_provider_manifest` and added
  `sha256(local....)` to triggers."* The apply step exited 0; CI
  reported success; the cluster did not receive the manifest change.
  The skill today reports "✅ green" and stops at Phase 3.
- **Silent-no-op restatement** (`ai/handoff.md:117`):
  *"A `0 added, 0 changed, 0 destroyed` after a manifest edit means
  `triggers_replace` is missing a hash — PR #67 added the manifest
  sha256 idiom."* This is the load-bearing oracle the skill currently
  ignores.
- **Same-session pattern, three independent failures**
  (`ai/handoff.md:125`):
  *"Three times this session a green apply did not produce the intended
  cluster state: PR #66's YAML edit was no-op'd by `triggers_replace`;
  PR #67's apply ran but didn't roll the Deployment; the very first
  apply (run 26354235231) reported 'Apply complete! Resources: 0 added'
  but I initially read that as success."* — justifies treating
  "apply succeeded but 0 effective changes" as a first-class signal,
  not a happy path.
- **Brainstorm convergence** (`ai/brainstorming/A4-debug-tool-gaps-prior-constraints.md:16`,
  `:22`, `:71`): three independent A4 entries (A4-007 state-show
  workflow, A4-013 zero-resources runbook, A4-062 trigger-audit lint)
  all point at the same PR #67 root cause. This spec is the runtime
  surfacing complement to those static-time and dispatch-time tools.
- **Cross-review** (`ai/brainstorming/cross-review-from-primary.md:30`,
  `P→A2-007`): a "manifest hash drift" regression test was proposed.
  SPEC-A5 is the live-CI sibling: tests catch it pre-merge; this skill
  catches it post-merge / post-apply so a regression never silently
  ships.

## 3. Out of scope

- The static lint (A4-062 / A3-011) that audits every `terraform_data`
  for a `sha256(manifest)` in `triggers_replace`. That is a pre-apply
  unit test; SPEC-A5 is post-apply runtime detection. The two layers
  are complementary (defense in depth per AGENTS.md §6.1).
- Auto-remediation. The skill names the gap, points at the missed
  resource address, and escalates. The agent or operator decides
  whether to add the hash, force a replace, or accept the no-op.
- Crossplane-side verification (`crossplane-claim-verify`). That skill
  covers the cluster-object layer; SPEC-A5 stops at the Terraform
  state-vs-plan layer. They are companion skills, not overlapping.
- New `workflow_dispatch` paths to fetch state. The post-apply plan
  runs inside the existing `terraform-test.yml` apply job whenever
  possible; only the local-dispatch fallback adds a small read-only
  helper.
- Drift detection for resources Terraform did not intend to touch.
  SPEC-A5 only compares the **planned change set** against the
  post-apply state for the **same addresses**. General drift is
  A4-007's territory.
- Crossplane v2.0.1 reconciler quirks (SPEC-A2 class C).
- Changing the existing failure-taxonomy entries beyond cross-linking.

## 4. Files to change / create

Modify:

- `.claude/skills/terraform-ci-watch/SKILL.md`:
  - Add a new **Phase 3.5 — Intent-vs-reality check** between the
    current Phase 3 (On success) and Phase 4 (On failure). It runs
    *before* the agent reports "✅ green" and *also* runs from inside
    Phase 4 when the apply step's terminal status is `failure` but the
    apply log includes a partial "Apply complete!" line (partial
    apply). Phase 3.5 is **mandatory** on any apply step whose log
    contains the line `Apply complete!`.
  - Update the **When to invoke** bullet "Immediately after a
    successful `git push`" to add: *"…and on any workflow run whose
    apply step printed `Apply complete!` regardless of exit code."*
  - Update the **Companion skill** section so the
    `crossplane-claim-verify` reference notes that SPEC-A5 fires before
    handing off — a cluster-state walk against a Terraform no-op would
    waste time chasing the wrong layer.

- `.claude/skills/terraform-ci-watch/reference/failure-taxonomy.md`:
  - Add a new row:
    `| "Apply complete! Resources: 0 added, 0 changed, 0 destroyed" after a manifest-affecting commit | silent-no-op | `terraform/*/helm.tf` `terraform_data.*.triggers_replace` | Add `sha256(local.<manifest>)` to triggers; see SPEC-A5 reference. | yes (with care) |`
  - Cross-link existing entries that can also surface as silent no-ops
    (none today, but leave a one-line note pointing to the new
    reference doc).

Create:

- `.claude/skills/terraform-ci-watch/reference/apply-intent-diff.md` —
  the procedure for Phase 3.5: how to capture the pre-apply plan
  artifact, how to re-run `terraform plan -detailed-exitcode` against
  post-apply state, the diff schema (resource address → intended
  action → observed action → verdict), the output budget, and the
  three exit verdicts (`MATCH`, `DRIFT`, `NO_OP_SUSPECTED`). ~120 lines.
- `.claude/skills/terraform-ci-watch/reference/scripts/apply-intent-diff.sh`
  — small helper invoked by the procedure. Reads two JSON plan files
  (`pre.json`, `post.json` from `terraform show -json`), emits the
  structured diff as Markdown (≤5 KB). Pure jq + bash; no new deps.
  ~80 lines.
- (No change to `terraform/`, `crossplane/`, `argocd/`, `clusters/`,
  `platform-services/`, `tests/`, `policies/`, `scripts/`, or
  `.github/` per the spec's scope rules. The workflow change to
  *emit* the pre-apply plan artifact is captured below in §12
  Rollout notes as a separate, prerequisite PR.)

## 5. Implementation notes

### 5.1 When to trigger

Phase 3.5 fires on **any** of:

1. The apply step exited 0 AND the log line
   `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.`
   appears AND the pre-apply plan was non-empty (`Plan: N to add,
   M to change, K to destroy.` with `N+M+K > 0`).
2. The apply step exited non-zero AND the log contains a partial
   `Apply complete!` line (a mid-apply failure that succeeded on
   some resources and stopped on others).
3. The apply step exited 0 AND the agent's local git diff vs the
   PR's base branch touches any file referenced by a `terraform_data
   ... provisioner "local-exec"` body that is hashed into
   `triggers_replace` — defensive trigger for the PR #67 class even
   if the plan was empty (the manifest edit may have been silently
   absorbed).

The skill MUST NOT fire Phase 3.5 when the pre-apply plan was
`Plan: 0 to add, 0 to change, 0 to destroy.` — that is a legitimate
no-op (e.g. re-run with no commits since last apply) and the silent
no-op test would generate noise.

### 5.2 How to fetch state + replan

**In CI** (preferred path): the apply job already runs
`terraform plan` then `terraform apply <plan-file>`. Add (in the
prerequisite workflow PR — see §12) two steps:

- After the existing pre-apply plan, write
  `terraform show -json mgmt.tfplan > pre-apply.plan.json` and
  upload as a workflow artifact.
- After the apply step, run `terraform plan -refresh-only
  -detailed-exitcode -out=post.tfplan` followed by
  `terraform show -json post.tfplan > post-apply.plan.json`, upload
  as a workflow artifact. Exit code 2 from `-detailed-exitcode`
  means drift; the skill consumes both artifacts.

The skill in Phase 3.5 downloads both artifacts via the active
capability profile's job-log/artifact path (gh / github-mcp /
ext-github; mirror the LIST_FAILED_JOBS pattern in
`capabilities.md` §2 — add an analogous `FETCH_ARTIFACT` row
implemented per profile).

**Locally** (when the agent runs apply outside CI, e.g. a manual
`terraform apply` from a workstation): the script reads
`pre.tfplan` and `post.tfplan` from the working directory; if
either is missing it falls back to `terraform show -json` against
the current state and a fresh `terraform plan -refresh-only`. The
local path is best-effort; the CI path is authoritative.

### 5.3 Diff schema and output budget

The script emits **≤5 KB** of Markdown:

```
## Intent vs reality — <run-url>
Verdict: NO_OP_SUSPECTED   # one of MATCH | DRIFT | NO_OP_SUSPECTED

| Address | Intended | Observed | Verdict |
|---|---|---|---|
| terraform_data.crossplane_aws_provider | replace | no-op | MISSED |
| helm_release.crossplane | update (in-place) | update (in-place) | OK |

Missed addresses (intended action did not occur):
- terraform_data.crossplane_aws_provider — triggers_replace likely
  missing sha256 of manifest body; see SPEC-A5 §2 (PR #67 pattern).

Next read:
  git diff <base>..HEAD -- terraform/management/helm.tf
  grep -n triggers_replace terraform/management/helm.tf
```

Truncation rule: if the table exceeds ~80 rows, group by verdict and
print at most the first 20 `MISSED` + 5 `OK` rows; everything else
becomes `… (N more rows)`. The Markdown output is the contract; the
exit code (0=MATCH, 2=DRIFT, 3=NO_OP_SUSPECTED) is the
machine-readable signal that drives Phase 4 escalation.

### 5.4 Race conditions with concurrent applies

`terraform-test.yml` is `workflow_dispatch`-only and its concurrency
group prevents two applies running simultaneously against the same
state (per `capabilities.md` §4). However, between the apply step
completing and the post-apply `terraform plan -refresh-only`
running, a separate dispatched run could begin. Phase 3.5
mitigates by:

1. Using the apply step's `.terraform/.terraform.lock.hcl` and the
   plan file that was captured *within the same step* — the
   post-apply plan is taken before the runner releases the state
   lock.
2. If the post-apply `terraform plan` fails to acquire the lock,
   the skill retries once after 60 s; on second failure it emits
   `Verdict: UNKNOWN_LOCK_CONTENTION` and escalates per
   `escalation-template.md`. It does NOT auto-retry beyond that —
   another agent's apply may have moved state out from under the
   verdict.
3. Local invocations honor the same lock; if `terraform plan`
   reports `Error acquiring the state lock`, the script exits
   non-zero and the SKILL.md procedure tells the agent to wait
   (the existing taxonomy entry `state-lock` applies).

### 5.5 Output forwarded into the PR/commit comment

The skill appends the Phase 3.5 Markdown to the same PR/commit
comment that Phase 3 reads (per the existing post-comment.py path
in SKILL.md Phase 3). When `Verdict != MATCH` the comment header
is prefixed `⚠️ INTENT-VS-REALITY MISMATCH` so the agent's next
read of the PR surfaces the silent-no-op immediately. (No emoji
in code/files per AGENTS.md general style; the warning glyph
appears only in the PR comment, which is human-facing UI.)

## 6. Tests required (per AGENTS.md §6.1)

| Layer | File | Assertion shape |
|---|---|---|
| Unit | `tests/unit/test_apply_intent_diff.sh` | Pipe two synthetic `terraform show -json` fixtures (pre + post) representing a clean replace into `apply-intent-diff.sh`. Assert (a) exit code 0, (b) stdout contains `Verdict: MATCH`, (c) no `MISSED` rows. |
| Unit | same file | PR #67 reproduction fixture: pre plan shows `terraform_data.crossplane_aws_provider` with action `replace`; post plan shows the same address with action `no-op`. Assert exit 3, `Verdict: NO_OP_SUSPECTED`, table contains the address and `MISSED`, and the "Missed addresses" section names `triggers_replace`. |
| Unit | same file | Drift fixture: pre plan shows `helm_release.crossplane` with action `update`; post plan shows the same address with a *different* set of attribute changes than intended. Assert exit 2, `Verdict: DRIFT`, table row marked `DRIFT`. |
| Unit | same file | Legitimate-empty-plan fixture: pre plan = `Plan: 0 to add, 0 to change, 0 to destroy.`; post plan identical. Assert exit 0 and stdout does NOT contain `NO_OP_SUSPECTED` (the skill MUST not fire on this case). |
| Unit | same file | Output-budget assertion: feed a 500-address fixture; assert the output file is ≤5 KB and ends with `… (N more rows)` truncation marker. |
| Unit | same file | Negative shape: malformed JSON input. Assert exit 1 and stderr names the missing field — script must never silently emit `Verdict: MATCH` on broken input. |
| Unit lint | `tests/unit/test_skill_phase_35_present.sh` | `grep -c "Phase 3.5" .claude/skills/terraform-ci-watch/SKILL.md` ≥ 1; the new failure-taxonomy row exists and references SPEC-A5. |
| Integration | `tests/integration/NN_apply_intent_diff_e2e.sh` (slot per existing numbering) | Against the live management cluster after a phase-1 apply: introduce a controlled `triggers_replace` miss by editing a manifest local without bumping its sentinel, dispatch `terraform-test phase=management action=apply`, then run the skill against the resulting run. Assert the skill prints `NO_OP_SUSPECTED` and names the exact affected address. Revert the edit and re-dispatch; assert the second run prints `MATCH`. |

§6.4 adversarial-reviewer-of-test-plans applies: before authoring the
unit fixtures, dispatch one `general-purpose` subagent with the brief
template in AGENTS.md §6.4. The fixtures are the load-bearing surface
— a fixture that doesn't match the real `terraform show -json` shape
green-lights a parser that doesn't work in production.

No new Kyverno layer (no cluster-runtime invariant). No new chainsaw
scenario (no XRD/Composition). The contract is text-transformation
over Terraform's own JSON schema.

## 7. Testing suggestions (unit / integration / e2e)

This section is the broader catalogue of tests one might add as the
surrounding system matures. §6 is the gate (the spec is not done
without those tests); §7 documents follow-on coverage that increases
confidence but is not a merge blocker.

### Unit

Fast (<10 s each). Files follow `tests/unit/test_<name>.sh`.

1. **`tests/unit/test_apply_intent_diff.sh` — MATCH path**: feed two
   identical pre/post plan JSON fixtures (all intended actions appear
   in post). Assert exit 0 and `Verdict: MATCH` in stdout.
2. **`tests/unit/test_apply_intent_diff.sh` — NO_OP_SUSPECTED path**:
   pre plan shows `terraform_data.crossplane_aws_provider` with
   action `replace`; post plan shows the same address with action
   `no-op`. Assert exit 3, `Verdict: NO_OP_SUSPECTED`, and the
   "Missed addresses" block names `triggers_replace`.
3. **`tests/unit/test_apply_intent_diff.sh` — DRIFT path**: pre plan
   shows `helm_release.crossplane` with a specific set of attribute
   changes; post plan shows a different set. Assert exit 2 and
   `Verdict: DRIFT`.
4. **`tests/unit/test_apply_intent_diff.sh` — legitimate empty plan**:
   pre plan is `Plan: 0 to add, 0 to change, 0 to destroy`; post
   plan identical. Assert exit 0 and stdout does NOT contain
   `NO_OP_SUSPECTED` (the Phase 3.5 trigger guard must fire).
5. **`tests/unit/test_apply_intent_diff.sh` — output budget**: feed a
   500-address fixture; assert the rendered Markdown is ≤5 KB and
   ends with the `… (N more rows)` truncation marker.

### Integration

Tests against a live cluster (kind for chainsaw; sandbox EKS for
deeper ones). Slower (seconds to minutes). Files follow
`tests/integration/<NN>_<name>.sh`.

1. **`tests/integration/NN_apply_intent_diff_round_trip.sh` —
   clean-apply MATCH**: after a phase-1 apply with no pending
   manifest changes, invoke Phase 3.5 via the skill. Assert the
   skill prints `Verdict: MATCH` and no `MISSED` rows appear.
2. **`tests/integration/NN_apply_intent_diff_round_trip.sh` —
   controlled no-op injection**: introduce a `triggers_replace` miss
   (edit a manifest body without bumping its sentinel), dispatch
   `terraform-test phase=management action=apply`, invoke the skill.
   Assert `Verdict: NO_OP_SUSPECTED` and the exact affected address
   appears in the output. Revert the edit, re-dispatch, assert
   `Verdict: MATCH`.
3. **`tests/integration/NN_apply_intent_diff_round_trip.sh` — lock
   contention path**: dispatch two `terraform-test` runs
   back-to-back; assert the skill on the second run emits either a
   clean `Verdict:` line or `UNKNOWN_LOCK_CONTENTION`, never a false
   `Verdict: MATCH` on broken state.

**E2E**: not applicable for this spec. Phase 3.5 operates entirely
within the Terraform state-vs-plan layer; there is no XRD,
Composition, or chainsaw scenario surface. Crossplane-side
verification is the responsibility of the `crossplane-claim-verify`
skill (see §5 Implementation notes). A full-stack E2E scenario would
add value only if a future spec wires these two skills into a single
orchestrated pipeline — that is out of scope here (see §3).

## 8. Documentation updates

- `.claude/skills/terraform-ci-watch/SKILL.md` — Phase 3.5 insertion
  per §4.
- `.claude/skills/terraform-ci-watch/reference/apply-intent-diff.md` —
  new, per §4.
- `.claude/skills/terraform-ci-watch/reference/failure-taxonomy.md` —
  new `silent-no-op` row + cross-link to SPEC-A5 reference.
- `.claude/skills/terraform-ci-watch/reference/capabilities.md` — add
  one row to §2 for `FETCH_ARTIFACT` under each of the three profiles
  (gh: `gh run download <run-id> -n <artifact-name>`; github-mcp:
  the artifact-download tool if exposed, else degrade; ext-github:
  the jentic API equivalent).
- `ai/handoff.md` — under "Behavioral rule additions" add:
  *"After every terraform-ci-watch run, the skill prints a
  `Verdict:` line; treat anything other than `MATCH` as a failure
  even if the workflow run is green."*
- `AGENTS.md` — no change. §7 already names the skill; the new
  phase is internal.

## 9. Workflow / auto-invocation wiring

AGENTS.md §7 already mandates invocation after every `git push`
affecting Terraform. The new Phase 3.5 fires inside that same
invocation — no new trigger, no new workflow file.

Confirmation that the new logic fires on the existing trigger:

- §7 trigger: any `git push` to a non-main branch that affects
  Terraform.
- Existing skill flow: detect profile → Phase 1 (LOCATE_RUN) →
  Phase 2 (POLL_RUN) → Phase 3 (success) OR Phase 4 (failure).
- New flow: Phase 3 now first calls Phase 3.5 (intent-vs-reality);
  Phase 4 also calls Phase 3.5 when its trigger conditions in
  §5.1 hold. Phase 3.5's verdict can downgrade a Phase 3 "success"
  into a Phase 4 escalation (`NO_OP_SUSPECTED` → enter Phase 4 with
  category `silent-no-op` and the new taxonomy row's fix recipe).

The skill's three-strike envelope (Phase 5) treats a
`NO_OP_SUSPECTED` verdict as one attempt; three consecutive
`NO_OP_SUSPECTED` verdicts after fix attempts escalate per
`escalation-template.md`. This prevents an infinite loop when
the operator's intended change is structurally impossible to
detect (e.g. a `triggers_replace` that genuinely needs a different
strategy).

## 10. Discoverability for future agents

Four forcing functions:

1. **SKILL.md Phase 3.5 is unconditional on the §5.1 trigger
   conditions.** The skill cannot reach its "report green and
   stop" path without first emitting a `Verdict:` line. A future
   agent reading the procedure sees Phase 3.5 as a required step,
   not optional reference.
2. **The failure-taxonomy `silent-no-op` row links to the SPEC-A5
   reference doc.** When an agent reads `failure-taxonomy.md`
   (which Phase 4 requires), it sees the row and the link.
3. **The unit test enforces the `Verdict:` output shape.** If a
   future refactor drops the line or renames a verdict, the test
   fails. The test name (`test_apply_intent_diff.sh`) shows up in
   `tests/unit/run.sh` output every push.
4. **The PR/commit comment header is prefixed on mismatch.** Human
   reviewers — and the next session reading the PR — see the
   warning header even before scrolling logs.

## 11. Verification checklist

Concrete observable checks the agent runs after implementing this
spec:

- [ ] `bash tests/unit/test_apply_intent_diff.sh` exits 0; output
  contains one `PASS` line per assertion (6 total).
- [ ] `bash tests/unit/test_skill_phase_35_present.sh` exits 0.
- [ ] `bash tests/unit/run.sh` includes both new tests and exits 0.
- [ ] `grep -c "Phase 3.5" .claude/skills/terraform-ci-watch/SKILL.md`
  returns ≥ 1.
- [ ] `grep -c "silent-no-op" .claude/skills/terraform-ci-watch/reference/failure-taxonomy.md`
  returns ≥ 1.
- [ ] Forced-miss smoke test: on a throwaway branch
  `test/spec-a5-force-no-op`, edit a manifest body controlled by a
  `terraform_data` resource WITHOUT updating its `triggers_replace`,
  push, dispatch `terraform-test phase=management action=apply`,
  invoke the skill. Confirm the skill output names the affected
  address (e.g. `terraform_data.crossplane_aws_provider`) and
  prints `Verdict: NO_OP_SUSPECTED`. Revert the edit, redispatch,
  confirm `Verdict: MATCH`.
- [ ] Concurrent-apply smoke: dispatch two `terraform-test` runs
  back-to-back; confirm the skill on the second run either reports
  a clean `Verdict:` or `UNKNOWN_LOCK_CONTENTION` with an
  escalation hand-off, never a false `MATCH`.
- [ ] Output-budget check: artificially construct a 500-address
  plan diff (test fixture), confirm the rendered comment is
  ≤5 KB.

## 12. Rollout notes

- Land on branch `feat/terraform-ci-watch-intent-diff` stacked off
  `main` per AGENTS.md §3. No prerequisite spec; the skill changes
  are self-contained.
- **Prerequisite workflow PR (separate, NOT this spec's scope):**
  edit `.github/workflows/terraform-test.yml` to emit
  `pre-apply.plan.json` and `post-apply.plan.json` as artifacts
  per §5.2. This is a small, isolated change that lands first;
  SPEC-A5's skill changes consume those artifacts. The spec
  itself is the skill-side procedure; the workflow edit is
  authored by a separate PR (mentioned here so the implementer
  doesn't merge SPEC-A5 against a workflow that doesn't yet
  emit the artifacts).
- No Terraform changes, no cluster changes, no destruction. Safe
  to land at any phase state.
- No account-derived values per AGENTS.md §8.1. Fixtures use
  placeholders (`<account-id>`, `<region>`); the script treats
  any account-shaped string as an opaque token.
- Backward-compatible — agents using the skill today see one
  extra `Verdict:` line per apply step and one PR-comment block.
  Existing escalation behavior is unchanged on `Verdict: MATCH`.
- After landing, the next session that hits a silent-no-op
  produces a one-line root-cause hint instead of a
  multi-failure-mode debug session. If it doesn't, the fixture
  corpus is incomplete — add the new shape, re-run §6's tests,
  iterate.
- Coordinate with SPEC-A2 (claim decision tree): the
  `crossplane-claim-verify` skill should NOT begin its walk if
  this skill's most-recent invocation for the same SHA emitted
  `Verdict: NO_OP_SUSPECTED`. The companion-skill stub in
  SKILL.md notes this; the actual cross-skill coordination is a
  follow-up if it proves load-bearing.

## 13. Estimated effort

**M** — medium.

Justification: the script and SKILL.md edits are small (~200 lines
total across the skill repo). The load-bearing complexity is in
three areas: (1) the workflow-side artifact emission (prerequisite
PR — small, but coordinated), (2) the per-profile `FETCH_ARTIFACT`
implementation (three profiles in `capabilities.md`), and (3) the
unit fixture corpus (six fixtures with realistic
`terraform show -json` shapes). The integration test requires a
live phase-1 cluster and a controlled `triggers_replace` miss —
~30 minutes of real CI time per dispatch and at least two
dispatches to verify the round-trip. Total: ~1–2 focused days
including adversarial review and the live smoke test.
