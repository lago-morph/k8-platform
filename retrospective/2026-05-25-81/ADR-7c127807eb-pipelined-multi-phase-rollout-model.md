# ADR: Pipelined multi-phase rollout model with file-locality phase boundaries

- **ID**: ADR-7c127807eb
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-81.md
- **PRs covered**: #80, #81

## Context

The 2026-05-25 session produced 49 specs (15 existing + 34 new) plus a canonical `SPEC-TEMPLATE.md`. The user explicitly stated their working pattern: *"I will probably do them by phase, then go through a cycle of implementing what we have up to now of the architecture. Phase N+1 implementation while Phase N outputs are running against a full build."*

The naïve approach — group by ROI tier (S → D → B → A → C per `larger-list-preferences.md`) and merge each tier as one phase — would have produced phases that all touched the same hot files (skill `SKILL.md`s, `tests/unit/run.sh`, `tests/chainsaw/**`, `terraform/**/providers.tf`). Phase N+1 implementation, running concurrently with Phase N's debug-fix hotfixes, would have hit unavoidable rebase pain on those files multiple times per phase. The user would not have been able to actually pipeline.

The `CLUSTERING-REVIEW.md` from a prior session had already partly addressed this for the 15 existing specs (six clusters drawn by skill-edit contention and shared file footprint), but that review did not consider the new 34 specs or the pipelining requirement.

## Decision

Adopt an 8-phase pipelined rollout model where Phase N's debug-soak in the deployed architecture overlaps temporally with Phase N+1's parallel implementation, with phase boundaries drawn primarily by file-locality rather than by ROI tier. Encoded in `ai/brainstorming/specs/IMPLEMENTATION-PLAN.md`.

The plan ships with:

- A top-level Gantt showing the implement/soak overlap explicitly.
- A cross-phase hot-files conflict-zone table identifying the 14 files / directories touched by ≥2 phases.
- A per-phase mermaid graph showing internal parallel vs stacked PRs.
- A pipelined-timing sequence diagram showing the branch model (Phase N+1 branches off main as soon as Phase N merges; hotfixes land on a separate branch).

## Alternatives considered

- **One-tier-per-phase (naïve ROI ordering).** Five phases matching the larger-list tiers verbatim. Rejected because (a) Tier S alone touched scripts/_lib/, tests/chainsaw/, .pre-commit-config.yaml, terraform/, and skill SKILL.md files — far too broad a soak surface; (b) every tier had hot-file collisions with the next, so pipelining wasn't possible.
- **Cluster-only ordering (the existing CLUSTERING-REVIEW.md model).** Six clusters scoped only to the original 15 specs. Rejected because it does not cover the 34 new specs and does not address pipelined execution.
- **No phases — author all 49 PRs in parallel.** Rejected because the hot-file conflicts would compound (e.g., five PRs all editing `tests/unit/run.sh`), and review surface would be unmanageable.
- **Sequential single-PR rollout (no parallelism).** Rejected because the user's stated capacity is concurrent work, and the project has many genuinely independent items (e.g., the seven Tier A debug scripts in Phase 6).

## Consequences

**What becomes easier:**

- The user can implement Phase N+1 while Phase N soaks, with minimal expected rebase pain on hot files (the conflict-zone table tells them exactly which files to watch).
- Each phase has 5–8 PRs and ≥3 parallel PRs once dependencies resolve, giving high fanout opportunity per phase.
- The per-phase mermaid + hot-files table is a durable reference the implementing agent reads at the start of each phase.

**What becomes harder:**

- Cross-phase coordination requires discipline: the implementer must check the conflict-zone table before starting Phase N+1 to know which Phase N hotfixes might collide.
- The phase boundaries are not the obvious tier boundaries, so a user reading only the larger-list-preferences ordering may be surprised.
- 8 phases × (1 implement cycle + 1 soak cycle) = 16 cycles minimum, vs ~5 cycles for naïve tier-order. Total wall-clock is longer; the trade-off is that the wall-clock is parallelizable.

**Trade-off accepted:** explicit phase-boundary discipline (and a single planning artifact to maintain) in exchange for genuinely pipelineable execution.

## References

- [`../2026-05-25-81.md`](../2026-05-25-81.md) — the source retrospective.
- [`./SKILL-SPEC-61948bb3d1-pipelined-multiphase-rollout-planner.md`](./SKILL-SPEC-61948bb3d1-pipelined-multiphase-rollout-planner.md) — the skill that produces plans of this shape.
- `ai/brainstorming/specs/IMPLEMENTATION-PLAN.md` — the concrete plan instance for the 49-spec rollout.
- `ai/brainstorming/specs/CLUSTERING-REVIEW.md` — the prior-session 6-cluster review this plan supersedes for the broader 49-spec body.
- `ai/brainstorming/specs/larger-list-preferences.md` — the tier-order input.
- PRs the decision was made in: #80 (plan authored), #81 (Gantt fix + Phase 1+2 prompt).
