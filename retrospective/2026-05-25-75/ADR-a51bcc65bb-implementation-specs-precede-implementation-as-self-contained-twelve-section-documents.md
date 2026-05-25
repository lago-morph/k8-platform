# ADR: Implementation specs precede implementation as self-contained 12-section documents

- **ID**: ADR-a51bcc65bb
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-75.md
- **PRs covered**: #75

## Context

PR #75 produced 15 implementation specs (one per top-15 immediate change) authored by 15 parallel subagents. Each spec is 250-400 lines and follows a strict 12-section template: summary, retro pain killed, out-of-scope, files to change/create, implementation notes, tests required, documentation updates, workflow/auto-invocation wiring, discoverability for future agents, verification checklist, rollout notes, estimated effort.

The motivating problem: prior PRs on this project repeatedly hit "what does this design mean?" debugging loops where the implementing agent had to ask the user for clarification or guess at intent. PR #66/#67/#68 (the IRSA SA-pinning fix chain) is the worst example — three separate PRs were required because each implementing agent had partial context about what the fix should be. A spec authored once, in full, by an agent with full context, costs ~30 minutes of subagent time and saves multi-PR debugging loops later.

The 12-section template is the load-bearing piece: it forces the spec author to think through every dimension before implementation, and it gives the implementing agent a checklist they can mechanically follow.

## Decision

Before implementing any non-trivial change (anything bigger than a one-line fix), author a **self-contained 12-section spec document** covering: (1) summary, (2) retro pain killed, (3) out-of-scope, (4) files to change/create, (5) implementation notes, (6) tests required, (7) documentation updates, (8) workflow/auto-invocation wiring, (9) discoverability for future agents, (10) verification checklist, (11) rollout notes, (12) estimated effort. The spec lives under `ai/brainstorming/specs/` (or a project-specific path); the implementing PR cites it in the PR description and consumes it without modification.

A fresh-context agent reading only the spec must be able to implement without asking the user for clarification. If the spec defers to the session, it has failed.

## Alternatives considered

- **PR descriptions only.** Rejected. PR descriptions are written after the design is complete, not before, and they don't survive the merged-and-archived lifecycle as well as a tracked file. The spec lives independently of any single PR.
- **Free-form design docs.** Rejected. Without the 12-section template, authors silently skip the hard sections (discoverability, rollout). The 12 sections are a checklist that forces every dimension to be considered.
- **Spec authored by the implementing agent themselves.** Rejected. The point of the discipline is to separate design from implementation. An implementing agent has different cognitive overhead than a design agent; mixing them loses the value of either.
- **Shorter spec template (e.g., 5 sections).** Rejected. The retros show every one of the 12 sections is load-bearing: discoverability (§9) prevents the producer-without-consumer failure mode; rollout (§11) prevents the audit-before-merge omission that makes new lints hostile; estimated effort (§12) lets the user plan sequencing.

## Consequences

**Easier:**
- Implementing PRs don't ask "what did the user mean?" — the spec already answers.
- Multi-PR debugging loops (PR #66/#67/#68 style) become rare because the spec catches the chain-of-dependencies at design time.
- Specs are durable across sessions and across context truncation. A future agent can pick up an unimplemented spec and finish it.
- Clustering review (see PR #75's `CLUSTERING-REVIEW.md`) is possible because specs are uniformly structured.

**Harder:**
- ~30 minutes of subagent time per spec, in exchange for saving ~1-3 hours of implementing-agent debugging time.
- The "spec author" role is distinct from "implementing agent" — adds a step to any non-trivial change.
- Specs may go stale if the surrounding code drifts before the spec is implemented; mitigated by the rollout section that explicitly addresses the existing state.

**Trade-off accepted:**
- One extra step (spec authoring) per non-trivial change, in exchange for implementing agents working from a self-contained brief rather than re-deriving design.

## References

- [`../2026-05-25-75.md`](../2026-05-25-75.md) — the source retrospective.
- PRs: #75 (the 15 specs themselves; `ai/brainstorming/specs/CLUSTERING-REVIEW.md` for the meta-pattern).
- See also: the existing `Plan` agent type in this CLI (which produces architectural plans but not at the 12-section discipline level).
