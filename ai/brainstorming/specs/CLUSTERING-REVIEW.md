# Clustering review — 15 specs → recommended PR clusters

**Branch:** `spec/top-15-immediate-changes`
**Date:** 2026-05-25
**Reviewer:** primary (orchestrator) agent after dispatching SPEC-A1 … SPEC-C5

The 15 specs were authored independently by parallel subagents. Reviewing them
together surfaces substantial overlap in **which files they touch**, **which
audit-before-merge rollouts they require**, and **which composite processes
they extend**. This report groups them into six clusters and recommends PR
shapes, sequencing, and shared infrastructure to extract.

Each cluster section names: the included specs, the substantive overlap
(concrete shared files / patterns), the recommended PR shape, dependencies
to other clusters, and risks of combining vs. keeping separate.

---

## At-a-glance

| Cluster | Specs | PR shape | Order |
|---|---|---|---|
| 1 — **Crossplane claim skill: diagnose + verify** | A1, A2, C2 | 3-PR stack on `.claude/skills/crossplane-claim-verify/` | First (A2 needs A1; C2 stacks on A1) |
| 2 — **Static lints (auto-discovered unit tests)** | B1, B2, B3, B5 | 1 baseline-cleanup PR + 4 lint PRs (stackable) | Can run in parallel with Cluster 1; cleanup PR first |
| 3 — **Terraform drift detection** | C1, C5 | 1 combined PR | After Cluster 2 baseline (so lints don't churn the same files) |
| 4 — **Chainsaw infra + per-XRD contract bundle** | A4, C4 (+ C2 sub-pattern) | 2-PR stack (A4 first, then C4) | After Cluster 1 lands (C2 establishes the "per-XRD bundle" idiom C4 extends) |
| 5 — **`terraform-ci-watch` skill enhancements** | A5, C3 | 1 combined PR (with prerequisite default_tags PR ahead of C3) | Independent; can run any time after Cluster 2 baseline |
| 6 — **Standalone** | A3, B4 | 1 PR each | A3 anytime; B4 after Cluster 1 (A2 class D consumes B4's PolicyReport) |

**Total recommended PRs: 12** (down from 15 if shipped one-per-spec; **5 fewer review cycles**, with no spec losing scope.)

---

## Cluster 1 — Crossplane claim skill: diagnose + verify

**Specs:** SPEC-A1, SPEC-A2, SPEC-C2

**Why these belong together.** All three modify the same skill
(`.claude/skills/crossplane-claim-verify/`), which is the canonical
post-claim-apply hook per AGENTS.md §7. The skill currently has phases 1-5
(verify Ready) plus 6 (failure taxonomy). The specs collectively add:

- **A1** — a new Phase 6.0 chain-walk block emitted on Ready=False (before
  taxonomy).
- **A2** — a Phase 6.5 decision-tree classifier that consumes A1's chain
  output and routes to one of four named gap classes (A/B/C/D).
- **C2** — a new Phase 5.5 post-Ready AWS-shape assertion (before the
  existing success exit), reading a per-XRD `aws-shape-contract.yaml`.

A1 and A2's own report cards confirm A2 explicitly stacks on A1's chain
output. C2 is on the success path so it's orthogonal to A1/A2 in flow,
but **all three edit the same `SKILL.md`** and all three add to the same
new `reference/` directory (`reference/chain-walk.md`,
`reference/decision-tree.md`, `reference/shape-contracts.md`). Shipping as
three separate PRs serialises three merge-conflict surfaces on one file.

**Recommended PR shape.** **3-PR stack**, in order:

1. **PR-1.A1** — chain walk + reference/chain-walk.md + the IRSA-subject
   `MATCH/MISMATCH` token + three chainsaw fixtures (SA mismatch, missing
   MR, provider unhealthy). Lands `Phase 6.0`.
2. **PR-1.A2** — decision tree + reference/decision-tree.md + four fixtures
   (classes A/B/C/D). Lands `Phase 6.5`. Base = PR-1.A1.
3. **PR-1.C2** — shape assertion + reference/shape-contracts.md + the
   PlatformSecret contract YAML + `tests/unit/test_xrd_ships_with_shape_contract.sh`.
   Lands `Phase 5.5`. Base = PR-1.A1 (not A2) — independent codepath.

**Shared infrastructure to extract once across the stack:**
- A common skill-phase logging helper (every phase emits a structured `### Phase X.Y` header) so the three new phases are self-labeling.
- The IRSA-subject diff utility from A1 is referenced by A2's class D classifier — surface it as a named function in `reference/chain-walk.md` so A2 doesn't duplicate.
- The skill front-matter trigger-phrase list (Ready=False, Waiting, IRSA, shape-drift, etc.) lands once in PR-1.A1 and gets extended in A2 and C2.

**Cross-cluster dependencies:**
- PR-1.A2 class D consumes the PolicyReport from Cluster 6's SPEC-B4 — non-blocking (class D works without B4, just less informative).
- C2's per-XRD contract pattern is the *seed* that Cluster 4's SPEC-C4 (golden files) extends — see Cluster 4 below.

**Risk of NOT clustering.** Three independent PRs against the same skill
would race on `SKILL.md` edits and the `reference/` directory. The skill
description has subtle activation semantics — three uncoordinated edits
could break the trigger.

---

## Cluster 2 — Static lints (auto-discovered unit tests)

**Specs:** SPEC-B1, SPEC-B2, SPEC-B3, SPEC-B5

**Why these belong together.** All four follow the **same exact pattern**:

- Single `tests/unit/test_<name>.sh` file.
- Auto-discovered by `tests/unit/run.sh` (no wiring change needed).
- Runs in the existing `.github/workflows/unit-tests.yml` on every push.
- **All four require an "audit current repo, fix or allowlist" rollout
  before merge** — otherwise the new lint lands red and is hostile.

The shared rollout discipline is the dominant overlap. Doing four
separate audit-and-fix passes (one per lint) would touch overlapping
files four times in serial.

The two Terraform-parsing lints (**B2** IRSA SA pinning, **B3** terraform_data
manifest hash) explicitly share parsing infrastructure — both choose regex
over `hcl2json` / `terraform show -json`, and both define the same allowlist
file format (inline comment marker `# noqa: <lint-name> - <reason>`).

**Recommended PR shape.** **1 baseline-cleanup PR + 4 lint PRs**:

- **PR-2.0 (baseline cleanup)** — one PR that does the union of the four
  audits and fixes everything to compliance. Each fix is a separate
  commit titled `cleanup(<lint>): fix <file>` so reviewers can isolate.
  No new tests yet — this PR makes the repo *fit* for the lints to come.
- **PR-2.B1** — `test_shell_safety.sh` + supersedes the two existing
  partial lints (`test_shell_readonly_var_assignment.sh`,
  `test_integration_scripts_strict_mode.sh`) that B1's report card
  flagged as redundant.
- **PR-2.B2** — `test_irsa_sa_pinned.sh` + shared HCL regex helper at
  `tests/unit/_lib/hcl_extract.sh`.
- **PR-2.B3** — `test_terraform_data_hashes_manifest.sh` + reuses the
  helper from B2.
- **PR-2.B5** — `test_no_account_id_hardcoded.sh` + the `# noqa:
  account-id` allowlist marker.

PR-2.B1…PR-2.B5 are **mergeable in any order** once PR-2.0 lands (they
touch disjoint test files). They can run in parallel review.

**Shared infrastructure to extract once:**
- `tests/unit/_lib/hcl_extract.sh` — shared regex parser for HCL blocks,
  consumed by B2 and B3 (and B5 to skip 12-digit literals inside HCL
  string contexts that aren't account IDs).
- The `# noqa:` inline-comment allowlist convention — define once in
  `ai/testing-guidelines.md §6.1`.
- A meta-test pattern: every lint ships a `tests/unit/fixtures/<lint>/{passing,failing}/`
  directory with positive and negative cases. Standardize the layout
  across all four.

**Cross-cluster dependencies:** None. This cluster can run fully in
parallel with all others.

**Risk of NOT clustering.** Four sequential audit passes touching the
same handful of files (esp. `terraform/management/helm.tf`, `ai/handoff.md`,
the `tests/integration/*.sh` scripts) would produce four nasty merge
storms.

---

## Cluster 3 — Terraform drift detection

**Specs:** SPEC-C1, SPEC-C5

**Why these belong together.** Both run `terraform plan -detailed-exitcode`.
Both protect against the same bug class (PR #67 silent no-op). They
differ only in **invocation context**:

- **C1** runs inside `terraform-test.yml`'s `apply-and-verify` action,
  immediately post-apply. Catches drift that exists at apply time.
- **C5** runs as the final integration test (`99_no_drift.sh`) in
  `tests/integration/run.sh`, which is invoked per AGENTS.md §6.3 full-bundle
  phase verify. Catches drift that develops between apply and verify.

They share the **same allowlist** of tolerated transient drift (Helm
release re-render timestamps, `tags_all` provider defaults, Crossplane
reconcile-in-flight churn). They share the **same output formatting**
budget (≤5 KB plan diff). They share the **same retry semantics** (sleep
60s, retry once).

**Recommended PR shape.** **1 combined PR** that:

- Extracts a shared `scripts/diagnose/tf-drift-check.sh` helper invoked
  from BOTH the workflow step (C1) and the integration test (C5).
- Defines the allowlist once at `scripts/diagnose/tf-drift-allowlist.json`.
- Lands both invocation sites in the same diff so reviewers see the
  helper, the workflow step, and the integration test together.

**Cross-cluster dependencies:**
- Should land **after** Cluster 2's PR-2.0 baseline cleanup, because that
  cleanup may itself introduce one-shot drift (e.g., re-formatted HCL).
- Should land **before** any Cluster 4/5 work that modifies the Terraform
  state, so future PRs are gated by drift detection.

**Risk of NOT clustering.** Two separate PRs would duplicate the
allowlist and the retry logic; the allowlist would drift between the two
invocation sites — exactly the class of bug C1/C5 are supposed to catch.

---

## Cluster 4 — Chainsaw infra + per-XRD contract bundle

**Specs:** SPEC-A4, SPEC-C4, plus the **per-XRD bundle pattern** seeded
by SPEC-C2 (Cluster 1).

**Why these belong together.** Both A4 and C4 modify every existing
chainsaw scenario under `tests/chainsaw/`. Both introduce per-scenario
template content. Both require a backfill across all existing scenarios
*before* merging the new assertion (otherwise existing tests break).

The deeper observation: **C2 introduces the idiom "every XRD ships with
a contract bundle"** (`crossplane/xrds/<name>/aws-shape-contract.yaml`).
**C4 extends the same idiom** (`tests/chainsaw/<scenario>/expected/<resource>.yaml`).
A future agent should recognize these as one pattern and apply it
consistently. The "contract bundle" lives partly in `crossplane/`
(intent → C2) and partly in `tests/chainsaw/` (rendered → C4). This is
fine; what matters is that the *checklist item* "did this XRD ship with
a contract bundle?" covers both.

**Recommended PR shape.** **2-PR stack:**

1. **PR-4.A4** — shared `_lib/catch-block.yaml`, every existing
   scenario's `catch:` block pasted in, the meta-test that proves the
   catch fires, the `test_chainsaw_catch_block.sh` unit test. Land
   before C4 because catch hooks help debug C4's golden-file work.
2. **PR-4.C4** — golden files for every XRD's scenarios, the `assert:
   (file ...)` wiring per scenario, the meta-test that mutates the
   Composition and confirms drift flagged. Base = PR-4.A4.

**Shared documentation rule** (lands in BOTH PRs, with cross-link):
> Every chainsaw scenario MUST include `catch:` from `_lib/catch-block.yaml`
> AND `assert:` referencing `expected/<resource>.yaml`. This rule belongs
> in `ai/testing-guidelines.md §6.1` and triggers `§6.4` adversarial
> review when a new scenario lands.

**Cross-cluster dependencies:**
- C4 lands after Cluster 1's PR-1.C2 so the "contract bundle" pattern is
  defined once (in C2's `reference/shape-contracts.md`) and C4 cross-links.
- A4 is independent — could land in parallel with Cluster 1 work.

**Risk of NOT clustering.** Two uncoordinated PRs would each rewrite
every scenario YAML. Merge conflict on every scenario file. Hostile.

---

## Cluster 5 — `terraform-ci-watch` skill enhancements

**Specs:** SPEC-A5, SPEC-C3

**Why these belong together.** Both modify
`.claude/skills/terraform-ci-watch/`. Both are post-apply hooks:

- **A5** — on apply *failure* or apply with `0 added/changed/destroyed`
  that smells like the PR #67 no-op class, fetch post-apply state and
  emit a structured "intent vs reality" diff.
- **C3** — on apply *success*, sample resources via
  `resourcegroupstaggingapi get-resources` and confirm the
  `k8platform-phase` / `k8platform-component` tags landed.

A5 fires on failure-or-suspicious-success; C3 fires on plain success.
Together they cover every apply terminal state. They share:
- The same skill front-matter (one merge surface).
- The same state-fetch primitive (A5 needs it for the diff, C3 implicitly
  needs it to know which resources to query).
- The same ≤5 KB output budget format.

**Recommended PR shape.** **1 combined PR** (with one prerequisite):

- **Prerequisite PR-5.0** — add `default_tags = { k8platform-phase, k8platform-component }`
  to every `provider "aws"` block. C3 explicitly calls this out as a
  prerequisite. This PR has no skill changes; it only changes Terraform.
- **PR-5** — A5 + C3 combined in the skill. Base = PR-5.0.

**Cross-cluster dependencies:**
- Cluster 1's PR-1.A1 chain-walk could consume C3's tags (the chain block
  can surface `k8platform-phase` for any resource it touches). Soft
  dependency — A1 works without C3.
- PR-5.0's Terraform edits intersect with Cluster 3's drift detection;
  land PR-5.0 *before* Cluster 3 so the tag additions are part of the
  drift-free baseline.

**Risk of NOT clustering.** Two separate PRs both modifying the same
skill's trigger logic could break activation. The state-fetch primitive
would be implemented twice.

---

## Cluster 6 — Standalone

**Specs:** SPEC-A3, SPEC-B4

These two have **no substantive overlap** with each other or with
clusters 1-5. Ship as individual PRs.

### A3 — `phase-2-diagnose.yml` IRSA / Provider-SA / reconcile-events

- Touches only `.github/workflows/phase-2-diagnose.yml`.
- No shared infrastructure with anything else.
- Tiny PR (3 step additions in one YAML).
- Land anytime; doesn't block or depend on other clusters.
- **Soft pairing:** A3's three new steps cover similar diagnostic ground
  to Cluster 1's PR-1.A1 chain walk. After A1 lands, an *optional*
  follow-up PR could have A3's workflow body call into A1's chain walk
  rather than reimplementing — but not now. A3's value is that it works
  even when the agent can't invoke the skill (CI-only sessions).

### B4 — Kyverno SA-existence audit policy + CronJob sync

- Touches `policies/audit/`, `crossplane/policies/`, extends the
  existing `tests/unit/test_kyverno_policy_lint.sh` (no new test file).
- Self-contained — its only soft consumer is Cluster 1's A2 class D
  classifier, which can read `kubectl get policyreport` to surface
  drift.
- Land **after** Cluster 1's PR-1.A2 lands so A2 can immediately use
  the PolicyReport. Otherwise B4 emits PolicyReports nothing reads.

---

## Recommended sequencing (Gantt-style)

```
Time →
─────────────────────────────────────────────────────────────────────
Cluster 2  PR-2.0 ─── PR-2.B1 ──┐
                     PR-2.B2 ──┤   (any order, parallel)
                     PR-2.B3 ──┤
                     PR-2.B5 ──┘
─────────────────────────────────────────────────────────────────────
Cluster 1                       PR-1.A1 ── PR-1.A2 ──┐
                                          PR-1.C2 ──┤  (A2 + C2 parallel)
─────────────────────────────────────────────────────────────────────
Cluster 5  PR-5.0 ────────────  PR-5 ─────────────────
─────────────────────────────────────────────────────────────────────
Cluster 3                       PR-3 (after 2.0 + 5.0)
─────────────────────────────────────────────────────────────────────
Cluster 4                                  PR-4.A4 ── PR-4.C4
─────────────────────────────────────────────────────────────────────
Cluster 6  PR-A3 (anytime)
Cluster 6                                            PR-B4 (after PR-1.A2)
─────────────────────────────────────────────────────────────────────
```

**Critical path:** PR-2.0 → PR-1.A1 → PR-1.A2 → PR-B4. Five PRs serially;
everything else parallel.

**Optimistic total wall-clock if a single agent works serially:** ~12
PRs × 1-3 hr each = 2-4 days. With parallel subagents (Cluster 2's
B1/B2/B3/B5 are perfect parallel candidates), **1.5-2 days** is realistic.

---

## Cross-cluster infrastructure to extract once

These appear repeatedly across specs and should be defined in one place,
with all clusters cross-referencing:

| Shared piece | First introduced by | Used by |
|---|---|---|
| `# noqa: <lint-name> - <reason>` allowlist marker convention | PR-2.B5 (B5) | B1, B2, B3, B5 |
| `tests/unit/_lib/hcl_extract.sh` HCL regex parser | PR-2.B2 (B2) | B2, B3, future Terraform lints |
| `tests/unit/fixtures/<lint>/{passing,failing}/` layout | PR-2.B1 (B1) | All four B lints |
| Per-XRD "contract bundle" idiom | PR-1.C2 | C2, C4 |
| Skill phase-logging helper (structured `### Phase X.Y` headers) | PR-1.A1 | A1, A2, C2, A5, C3 |
| `scripts/diagnose/tf-drift-check.sh` shared drift helper | PR-3 (C1+C5) | C1, C5 |
| `_lib/catch-block.yaml` shared chainsaw catch | PR-4.A4 | A4 today, all future scenarios |
| `ai/testing-guidelines.md §6.1` checklist additions ("XRD MUST ship with contract bundle"; "chainsaw scenario MUST include catch + golden") | PR-1.C2 + PR-4.C4 | Anyone authoring a new XRD or scenario |

---

## Risks and caveats

1. **Backfill drag.** Several clusters require backfilling existing
   files to comply with new tests (Cluster 2 baseline; Cluster 4 golden
   files; Cluster 1 C2 backfilling the existing XRD into the
   per-XRD-directory pattern). These backfills are mechanical but
   *unbounded* in PR diff size — recommend reviewers grant scope to
   the cleanup PRs explicitly.

2. **Skill-edit contention.** Clusters 1 and 5 both edit
   `.claude/skills/<name>/SKILL.md`. Within a cluster the stacked-PR
   order resolves it, but if Cluster 1 and Cluster 5 land in true
   parallel they'll conflict on each other's *adjacent* skill's
   front-matter. Low risk because they touch different skills, but
   reviewers should not approve a cross-skill change in either.

3. **Adversarial-reviewer trigger fatigue.** AGENTS.md §6.4 mandates
   adversarial subagents at every test-drafting moment. With ~12 PRs
   each containing tests, that's ~12 adversarial reviews. Consider
   batching: run one adversarial review per *cluster* against the
   stacked set of tests, not per-PR. This is a deviation from §6.4
   but a defensible one (the spec is "one adversarial review per
   test-drafting trigger" — a cluster's tests share the trigger).

4. **The "other implementation agent" is in flight on phase 2.** Several
   clusters touch files that agent might also be editing (`tests/`,
   `policies/`, `.claude/skills/`). Before starting, the implementing
   agent should `git fetch` and review what's in flight; coordinate by
   stacking on top of that agent's PRs rather than against `main`.

5. **None of these specs cover phase 3+.** All 15 specs are scoped to
   phases 0-2 problems demonstrated in current retros. When phase 3
   work begins, expect to author a new top-N brainstorm — the existing
   `brainstorm.json` has thousands of phase-3+ ideas waiting.

---

## TL;DR for the implementing agent

- **Start with PR-2.0** (baseline cleanup) — un-blocks everything in
  Cluster 2, and the cleanup itself is a sane orientation pass that
  forces the implementing agent to read every script + workflow once.
- **Then PR-1.A1 in parallel** — the chain-walk is the single
  highest-leverage spec and unblocks A2, A3 follow-up, B4 consumer,
  C2's structural pattern.
- **Don't ship any spec alone if its cluster is named here.** The
  combined PR shape is always smaller in total review surface and
  always safer than serial.
- **Use the "Shared infrastructure to extract once" table** as a
  checklist when writing each cluster's PR — extract first, then have
  the specs reference the extraction.
- **When in doubt, read the spec.** Every individual SPEC-X-Y.md is
  self-contained with files-to-change, tests-to-implement,
  documentation updates, and discoverability mechanisms. The
  implementing agent should not need to ask the user "what does this
  spec mean" — that's what the 250-400 line specs are for.

End of review. Stop.
