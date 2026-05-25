# Spec: `pipelined-multiphase-rollout-planner`

- **ID**: SKILL-SPEC-61948bb3d1
- **Source retrospective**: ../2026-05-25-81.md

## Intent

Produce a multi-phase implementation plan for a large body of independent specs (typically 30+) such that Phase N can debug-soak in the live system while Phase N+1 is being implemented in parallel. The skill draws phase boundaries primarily by file-locality (so Phase N+1's parallel implementation rarely collides with Phase N's debug-fix hotfixes), produces a top-level Gantt diagram showing the soak/implement overlap, a per-phase mermaid graph showing parallel vs stacked PRs, and a cross-phase hot-files conflict-zone table that the implementing agent uses to predict rebase pain. Born in the 2026-05-25 session where 49 specs (15 existing + 34 new) needed sequencing into a pipeline that would let the user implement Phase N+1 while Phase N's outputs were being debugged in the deployed architecture.

## Trigger

**Direct user phrases:**
- "Plan the rollout for these specs."
- "How should we sequence these into phases?"
- "I want a phased implementation plan with parallelism."
- "Pipelined rollout."

**Proactive triggers:** offer when the user (a) commits 20+ specs/items they intend to implement, (b) describes a working pattern of "implement phase N+1 while phase N soaks/runs", or (c) asks for a Gantt or sequencing diagram for a body of work.

**Negative triggers:** do NOT activate for single-spec implementation, for cluster/ROI re-prioritization that doesn't change boundaries, or for sprint planning at the issue-tracker level.

## Inputs

- A directory of spec files (canonical: `ai/brainstorming/specs/SPEC-*.md`) or a list of items to be implemented.
- Optional: an existing clustering review (e.g., `CLUSTERING-REVIEW.md`) and user-stated tier preferences (e.g., `larger-list-preferences.md` of the form S → D → B → A → C).
- Optional: the user's working cadence — typical session length, soak duration, hotfix-branch policy.

## Outputs

A single Markdown file at a stable path (recommended `ai/IMPLEMENTATION-PLAN.md` or `ai/brainstorming/specs/IMPLEMENTATION-PLAN.md`) containing:

1. A "how to read" preface explaining the implement/soak overlap.
2. A top-level Gantt diagram (one row per phase, with `implement` and `soak` sub-bars, each 1 cycle wide, soak starting at the cycle the implement ends — so Phase N soak shares a column with Phase N+1 implement).
3. A cross-phase **conflict-zone table** listing the hot files / directories and which phases touch each (e.g., `.claude/skills/*/SKILL.md`, `tests/unit/run.sh`, `tests/chainsaw/**`, `AGENTS.md`).
4. One section per phase containing: scope, list of PRs, dependencies, a per-phase mermaid graph showing parallel vs stacked PRs, the hot files this phase touches, the "soak watch" (what to look for when it hits the live system), and "unlocks" (what later phases this phase enables).
5. A pipelined-timing sequence diagram showing the branch model (Phase N+1 branches off main as soon as Phase N merges; hotfixes land on a separate branch).
6. A summary table recapping phases.

## Workflow

1. **Inventory.** Read the spec directory and any clustering review. Map every item to a (cluster, tier, file-locality footprint) tuple. Identify the existing items vs the new items.
2. **First pass — tier order.** Apply the user's tier preference verbatim as a draft order.
3. **Second pass — file-locality merge.** For each tier group, identify which items touch shared "hot files" (skill SKILL.md, test runners, terraform providers, etc.). Co-locate items that share hot files in the same phase so the conflict is internal to the phase rather than cross-phase.
4. **Third pass — phase sizing.** Each phase should have 5–8 PRs and at least 3 parallel PRs once dependencies resolve. If a phase has only 2 items, fold it into an adjacent phase. If a phase has >10 items, split it.
5. **Conflict-zone table.** Identify every file or directory touched by ≥2 phases. List in a markdown table with one row per file.
6. **Per-phase mermaid.** Use `graph LR` with explicit dependency arrows. Annotate parallel groups via `subgraph`. Tag stacked PRs that must base off another PR's branch.
7. **Top-level Gantt.** Use `gantt` with `dateFormat X` and `axisFormat Cycle %s`. Each phase has two bars: `implement` (1 cycle, `active` class) and `soak` (1 cycle, `crit` class). Start times are explicit integers so Phase N+1 implement and Phase N soak share a column.
8. **Validate every mermaid.** Use the `validate_and_render_mermaid_diagram` tool before writing the final file. A diagram that fails to render is a documentation bug.
9. **Soak watch + open questions.** For each phase, list what to monitor during soak. End the plan with an "Open questions" section that the user can resolve before Phase 1 starts.

## Concrete examples

### Example 1: 49-spec rollout (the 2026-05-25 origin session)

Input: 50 SPEC files (15 existing A1–C5, 34 new S2–S10, D1–D5, LA1–LA8, LB3–LB8, LC1–LC6), plus `CLUSTERING-REVIEW.md` (6 clusters) and `larger-list-preferences.md` requesting order S → D → B1+B2+B6 → A → rest of B → C.

Output: 8 phases. Hot-files table identified `.claude/skills/crossplane-claim-verify/SKILL.md` as touched by SPEC-A1, SPEC-A2, SPEC-C2 — they all landed in Phase 5 as a stack. `tests/chainsaw/**` is touched by SPEC-A4 (catch hook) and SPEC-C4 (golden files) — both in Phase 2 with C4 stacked on A4. Each phase ended up with 5–8 PRs and ≥3 parallel PRs.

### Example 2: smaller 12-spec rollout (hypothetical)

Input: 12 specs, no tier preference. Output would likely collapse to 3–4 phases. The skill would warn the user that pipelining overhead may not pay off below ~3 phases (one cycle of P0 spec authoring + N implement/soak + final soak = N+2 cycles). For small bodies of work, suggest a simpler "all parallel, no phases" plan instead.

## Anti-patterns

- **ROI-tier ordering without file-locality merging.** Drawing phase boundaries solely by ROI tier (without considering which files each item touches) creates needless cross-phase merge conflicts. Always do the second pass.
- **Implement bars longer than soak bars.** Made the soak chunks tiny and easy to miss in the original Gantt; user couldn't read the diagram. Both bars should be 1 cycle wide.
- **`dateFormat X` + `axisFormat %s` with implicit `after` chains.** Produces unreadable axis labels (`0 0 0 1 1 1`) and obscures the overlap. Use explicit integer start times.
- **Phases of 1–2 PRs.** Pipelining overhead exceeds the benefit. Fold into adjacent phase.
- **Phases of >10 PRs.** Soak surface is too broad; debug pain dominates. Split.

## Acceptance criteria

- [ ] Output file written to a stable repo path; committed in the same PR as the plan was requested.
- [ ] Every mermaid validated via the validator tool before write.
- [ ] Conflict-zone table covers every file touched by ≥2 phases.
- [ ] Each phase has between 5–8 items and ≥3 parallel PRs.
- [ ] Top-level Gantt visually shows Phase N soak overlapping Phase N+1 implement.
- [ ] Open-questions section at the end so the user can resolve sequencing decisions before Phase 1.

## Files this skill creates / modifies

- `ai/IMPLEMENTATION-PLAN.md` (or equivalent stable path) — the full plan, one file.
- May reference (read-only) `CLUSTERING-REVIEW.md`, `preferences.md`, `larger-list-preferences.md`, and the spec directory.
