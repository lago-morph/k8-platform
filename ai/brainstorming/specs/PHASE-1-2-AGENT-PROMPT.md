# Prompt for Phase 1 + Phase 2 implementation

**Copy-paste the block below as the opening message to the next agent
session, once PR #80 (specs + plan) and the gantt-fix PR are merged to
`main`.**

The goal: implement the 11 PRs that make up Phase 1 (Tier S
foundations) + Phase 2 (Tier S chainsaw infra + diagnostic scripts) in
**one combined session** with maximum parallel subagent fanout.

---

## The prompt

You are working on the k8-platform repo at `/home/user/k8-platform`.
The specs and implementation plan for an 8-phase rollout were merged on
`main` in a prior session. Your task: implement **Phase 1 (Tier S
foundations) + Phase 2 (Tier S chainsaw infra + diagnostic scripts)
together** with maximum parallelism via the Agent tool.

### Read first (in this order)

1. `/home/user/k8-platform/ai/brainstorming/specs/IMPLEMENTATION-PLAN.md`
   — especially §2 (conflict zones), §4 (Phase 1), §5 (Phase 2), and
   the pipelined-execution preface.
2. `/home/user/k8-platform/AGENTS.md` — entire file, but pay particular
   attention to §3 (branching), §6 (testing layers + TDD + adversarial
   review), §7 (skills), and §8 (sandbox constraints).
3. `/home/user/k8-platform/ai/brainstorming/specs/larger-list-preferences.md`
   — the "Cross-cutting infrastructure" table at the bottom.
4. Each spec file you intend to implement, end-to-end, before writing
   any code for it.

### The eleven PRs

Each row gives the spec, what it produces, its dependency on other
Phase-1/2 PRs, and the recommended model for the implementing
subagent. Per-task model selection is per the user's directive
("sonnet or opus depending on complexity").

**Phase 1 — foundations:**

| PR ID | Spec | Headline output | Depends on | Model | Why |
|---|---|---|---|---|---|
| PR-1.S4 | `SPEC-S4-whereami.md` | `scripts/whereami.sh --json` + `scripts/_lib/aws-cli-helpers.sh` (the shared lib introduced here) | — | sonnet | Straightforward bash + a clean shared lib. |
| PR-1.S5 | `SPEC-S5-phase-status.md` | `scripts/phase-status.sh` with interactive + `--json` + `--assert-phase` modes | PR-1.S4 (consumes lib) | opus | Three output modes; phase definitions need careful mapping. |
| PR-1.S6 | `SPEC-S6-kubeconform-precommit.md` | `kubeconform` pre-commit hook + `kubeconform-schemas/` + audit-fix rollout | — | opus | CRD schema fetching + Crossplane function-input schema extraction + audit-and-fix of existing manifests. |
| PR-1.S10 | `SPEC-S10-apply-zero-resources-runbook.md` | `docs/runbooks/runbook-apply-zero-resources.md` + small unit test | — | sonnet | Doc-only spec. |

**Phase 2 — chainsaw infra + diagnostic scripts:**

| PR ID | Spec | Headline output | Depends on | Model | Why |
|---|---|---|---|---|---|
| PR-2.S7 | `SPEC-S7-wait-for-claim.md` | `scripts/wait-for-claim.sh` + `scripts/_lib/k8s-helpers.sh` (the shared lib introduced here) + migrate 3 integration tests | — | opus | Establishes the canonical wait primitive consumed by every later phase. Quote-on-timeout dump is non-trivial. |
| PR-2.S2 | `SPEC-S2-crossplane-trace.md` | `scripts/crossplane-trace.sh` with `--watch` + `--json` | PR-2.S7 (consumes lib) | opus | The single highest-leverage debug tool. Multi-layer walk (claim → XR → MRs → atProvider). |
| PR-2.S3 | `SPEC-S3-irsa-trust-validator.md` | `scripts/irsa_trust_validator.py --all` | — | opus | OIDC decode + fleet sweep + fail-soft per-role. |
| PR-2.A4 | `SPEC-A4-chainsaw-error-hook.md` | shared `tests/chainsaw/_lib/catch-block.yaml` pasted into every scenario + meta-test + unit-test enforcer | — | opus | Touches every chainsaw scenario; inverted-exit meta-test wiring is the load-bearing tricky bit. |
| PR-2.C4 | `SPEC-C4-chainsaw-golden-file-assert.md` | per-scenario `expected/<resource>.yaml` golden files + assert wiring + meta-test | **PR-2.A4 (stacks on)** | opus | Backfills every existing scenario; normalization rules matter. |
| PR-2.S9 | `SPEC-S9-composition-render-dryrun.md` | `scripts/composition-render.sh` + `crossplane/xrds/<name>/render-fixtures/` + pre-commit hook | — | opus | Fixture infrastructure; render-diff normalization. |

### Dispatch strategy — maximum parallelism

Do **two waves** of subagent dispatch.

**Wave 1 — 7 parallel subagents** (all start immediately, no
inter-dependencies in this wave):

- PR-1.S4 (sonnet)
- PR-1.S6 (opus)
- PR-1.S10 (sonnet)
- PR-2.S7 (opus)
- PR-2.S3 (opus)
- PR-2.A4 (opus)
- PR-2.S9 (opus)

Dispatch all seven in a **single Agent tool message** with
`run_in_background: true` on each. Use `isolation: "worktree"` so
concurrent edits cannot corrupt the shared git index.

**Wave 2 — 3 parallel subagents** (each consumes a Wave 1 output):

- PR-1.S5 (opus) — starts once PR-1.S4 is merged (needs the lib).
- PR-2.S2 (opus) — starts once PR-2.S7 is merged (needs the lib).
- PR-2.C4 (opus) — starts once PR-2.A4 is merged (stacks on the catch hook).

You don't have to wait for *all* Wave 1 to complete before starting
Wave 2 — kick each Wave 2 subagent the moment its specific
prerequisite merges.

### Per-subagent brief template

Each subagent's brief MUST include:

1. The absolute path of its target spec file.
2. The single sentence "Implement this spec literally. Do not invent
   scope. Do not modify the spec — if reality diverges, note it in the
   PR body and a retro entry."
3. Discipline: TDD per AGENTS.md §6.2; run §6 tests-required gate;
   run §11 verification checklist; adversarial review per §6.4 if the
   spec triggers it.
4. PR conventions:
   - Branch off the latest `main`.
   - PR title format: `phase-<N>-<spec-id>: <one-line summary>` —
     e.g. `phase-1-S4: scripts/whereami.sh + aws-cli-helpers lib`.
   - PR body: link the spec, summarize the diff, list any
     spec-vs-implementation deviations and why, paste §11 results.
   - Ready-for-review, not draft.
5. Hard rules:
   - Do not modify any `SPEC-*.md` file. Specs are frozen.
   - Do not touch files outside §4 of the spec (the file list).
   - Do not start work on a different spec.
6. Output: one summary message under 150 words with PR URL + open
   questions.

### Coordination during the run

- **Worktree isolation** keeps the 10 concurrent edits from clobbering
  each other; their PRs merge sequentially in dependency order.
- **Hot files that span specs** — be ready to mediate small
  hand-merges if two subagents both touch:
  - `tests/unit/run.sh` (each lint appends one line)
  - `AGENTS.md` (small section-scoped bullets)
  - `ai/testing-guidelines.md`
  - `ai/handoff.md` (skills inventory updates)
  - `.pre-commit-config.yaml` (S6 introduces; S9 also adds a hook)
- **Stacked PR** — PR-2.C4 must base off PR-2.A4's branch, not main,
  until A4 merges. Tell the C4 subagent this explicitly.

### Merge order

1. **Foundation libs first:** PR-1.S4 → PR-2.S7 → PR-2.A4.
2. **Consumers next:** PR-1.S5, PR-1.S6, PR-1.S10, PR-2.S2, PR-2.S3,
   PR-2.S9, PR-2.C4 in any order once their prereqs are in.

### When all 11 PRs are merged

Write a short retrospective at
`retrospective/YYYY-MM-DD-<PPP>.md` covering:

- Any spec-vs-reality drift surfaced during implementation.
- Any §11 verification items that needed wording tweaks.
- New merge-conflict zones to feed back into
  `IMPLEMENTATION-PLAN.md` §2.
- Per-spec subagent model choice in hindsight — was sonnet enough for
  S4/S10? Did any opus task feel under-utilized?

Commit and push the retro on its own small PR.

### Out of scope

- **Phase 3 onward.** Stop after Phase 2's PR-2.C4 merges.
- **Modifying any `SPEC-*.md`.** Specs are frozen artifacts.
- **Modifying `IMPLEMENTATION-PLAN.md`.** The retro is the feedback
  channel for plan refinements.

### Done criterion

11 PRs merged to main; retro committed; one summary message back to
the user under 300 words listing PR URLs, any unresolved questions,
and confirmation the retro is in.

---

## Notes for the human kicking off the next session

- The branch protections (per `SPEC-D5`) are not in place yet —
  hooks-as-CI move comes in Phase 3. Until then, CI is the gate.
- Sandbox constraints still apply (us-east-1 / us-west-2 only,
  t-class instances, ≤9 EC2). None of these 11 PRs provision
  EC2-class resources; they're all scripts, lints, docs, and chainsaw
  YAML.
- If a subagent reports that an in-flight unrelated PR conflicts on a
  hot file (e.g., another phase's chainsaw work landed since spec
  authoring), that's a rebase, not an abort — instruct the subagent
  to rebase and re-run the §11 checklist.
