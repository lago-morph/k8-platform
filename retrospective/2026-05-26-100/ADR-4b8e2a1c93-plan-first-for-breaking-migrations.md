# ADR: Plan-first not execute-first for breaking-change migrations

- **ID**: ADR-4b8e2a1c93
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-26
- **Source retrospective**: ../2026-05-26-100.md
- **PRs covered**: #99 (the migration plan as deliverable)

## Context

When the v1/v2 root cause was diagnosed (session 2026-05-26, Phase 3), the natural reflex was to start executing the migration immediately: bump the version pins, fix the manifests, update the tests, ship. The user instead requested a comprehensive PLAN: situation doc, mechanical impact tracing, per-segment plans, adversarial review, synthesis. Execution was deferred to a future session.

This decision was load-bearing in three ways. First, the migration's blast radius (29 files, both XRDs are cluster-wide CRD orphan risks, cross-segment shared values, in-flight PRs that needed rebase decisions) was much larger than a single execution session could absorb without thrashing. Second, the planning pass surfaced three issues that would have caused failed executions if they'd hit the cluster — `v2.5.4` doesn't exist on upstream (would 404 the apply), `ClusterProviderConfig` vs `ProviderConfig` confusion across segments (would silently install the wrong kind), unit composition test sequencing (would red-CI main for days). All three were caught at plan-review time, by adversarial reviewers reading per-segment plans without execution pressure. Third, the plan itself is a durable artifact: a future session — possibly with a different agent, possibly with the original session's user — can pick it up cold and execute without re-deriving any of the decisions.

The contrast with a hypothetical execute-first approach: the agent would have started by bumping `v2.5.4` (the same mistake PR #98 made), the apply would have 404'd, the agent would have debugged the version pin, fixed to `v2.5.0`, started the manifest migration, hit the XRD `claimNames` BLAST problem mid-execution, had to halt and figure out the drain protocol live, lost claim state, etc. Each step's mistake compounds the next; recovery is expensive.

## Decision

For any migration involving (a) more than ~15 files, (b) cross-concern boundaries (production + infra + tests + tooling), (c) breaking API changes, or (d) in-flight PRs that need disposition decisions, the agent produces a PLAN as the deliverable of the planning session. Execution happens in a separate, later session that takes the plan as input.

## Alternatives considered

1. **Execute as you go, with rollback for each step.** Rejected. The Crossplane v1→v2 migration has at least one BLAST-radius irreversibility: removing `claimNames` from an XRD deletes the CRD cluster-wide; if there are live claims at that moment, they're orphaned. `git revert` does not restore that state. Step-by-step rollback fails when any single step is irreversible.
2. **Skip the planning step, do a partial migration first to "see what breaks."** Rejected. The breakage modes are well-documented upstream (v2 migration guide enumerates the breaking changes). A partial migration just lands in a worse intermediate state; nothing is learned that the migration guide didn't already say.
3. **Write a one-page sketch, not a full multi-segment plan.** Rejected for this size of migration. A one-page sketch lacks the resolution to catch cross-segment inconsistencies. The adversarial review process (the load-bearing quality gate) needs per-segment plans of enough depth that reviewers can attack them. This session's plan was 12 files, ~3400 lines total — overkill for a routine bump, right-sized for a v1→v2 breaking migration.
4. **Plan, but skip the adversarial review.** Rejected. Three of the round-1 review findings (v2.5.4 nonexistent, `ClusterProviderConfig` cross-segment disagreement, test sequencing red-main risk) were not visible to the original planners; only adversarial reviewers with fresh context caught them. Without that step, the plan would have shipped with three latent execution failures baked in.

## Consequences

**Easier:**
- Future migrations of similar scale follow a known shape: situation → impact-trace → plan-per-segment → adversarial-review → revise → synthesize. The pipeline is now a skill (`multi-subagent-migration-plan`) the agent can invoke directly.
- A plan that survives adversarial review is robust enough to be executed by a different agent — the original session's context is captured in the plan files, not in the agent's memory.
- Per-segment plans are independently reviewable; the user can sign off on each segment without reading the whole plan.
- Mistakes are caught at planning cost (subagent compute time), not at execution cost (cluster impact, recovery work, user-facing CI red).

**Harder:**
- Planning takes wall-clock time (this session: ~2 hours for 24 subagents). For routine bumps that don't qualify as "breaking migrations" this is over-engineering.
- The plan-and-then-execute split means the executor must be disciplined enough not to deviate from the plan mid-execution without writing a decision brief. Without that discipline, the plan becomes documentation theatre.
- Storing plans on disk (`ai/<migration-name>/`) accumulates artifacts; older completed migrations should be archived periodically to keep the directory navigable.

**Trade-offs knowingly accepted:**
- The plan defers 5 open questions to the executor (per session 2026-05-26's plan §7). Some of these may only be resolvable at execution time (e.g., "does the live cluster have real workloads that would be lost in the drain?"). The plan acknowledges this rather than guessing.
- The plan optimizes for parallelism but is constrained by hot files (touched by multiple segments). For the Crossplane migration, Wave 2 cutover collapses to a single stacked PR because the unit composition tests are tightly coupled to the Composition shapes. The plan accepts the loss of parallelism as the price of CI safety.

## References

- [`../2026-05-26-100.md`](../2026-05-26-100.md) — the source retrospective.
- [`./SKILL-SPEC-d72f4a8b1c-multi-subagent-migration-plan.md`](./SKILL-SPEC-d72f4a8b1c-multi-subagent-migration-plan.md) — the plan pipeline skill.
- [`./SKILL-SPEC-5e8a3f2bd9-pre-commit-cross-segment-decisions.md`](./SKILL-SPEC-5e8a3f2bd9-pre-commit-cross-segment-decisions.md) — the cross-segment-decision skill used during plan revision.
- `ai/crossplane-v1-v2-un-fuckify/40-final-plan.md` (now on `main`) — the master plan deliverable.
- PRs the decision was made in: #99 (the plan PR), with the decision tied to the workflow established during session 2026-05-26.
