# 0002 — docs/open-issues.md is the durable register of undiagnosed problems

- **ID**: ADR-a52e64a8c7
- **Status**: Accepted
- **Date**: 2026-05-28
- **Source retrospective**: [`../../retrospective/2026-05-28-129.md`](../../retrospective/2026-05-28-129.md)
- **PRs covered**: #128

## Context

The auto-003 chainsaw composition-drift failure was a problem this session walked past initially: I observed the failure, framed it as "AWS-provider cold-start" (hypothesis dressed as conclusion, see AGENTS.md §6.17), and proposed deferring it as "out of scope, file as separate follow-up". The user named this as horrible engineering discipline because the follow-up filing mechanism was undefined — "we'll do it later" was indistinguishable from "we drop it on the floor". Without a durable mechanism, the next session inheriting this codebase would have to re-discover the same problem.

The session's other tracked items (`handoff-followups-2026-05-28.md`, the in-flight tasks file at repo root) covered planned work. There was no place for *unplanned observed problems that need follow-up but weren't fixed this session*. Without that place, every flake, every red check we couldn't immediately fix, every "huh, weird" moment becomes either a fix-now or a forget.

## Decision

Track every observed-but-undiagnosed failure in `docs/open-issues.md` with a per-issue entry carrying status, symptom (verbatim error text or log quote), evidence available, labelled hypotheses, ruled-out causes, next concrete diagnostic step, and an owner / next action. The register format is enforced by AGENTS.md §6.18 ("Never ignore an undiagnosed failure — log to the open-issues register").

Each entry uses identifier `OI-YYYY-MM-DD-N` (sequence within date). Entries can be in two states — "open" (waiting for diagnosis) or "diagnosed" (root cause known; fix may or may not have landed). Closed items are removed once their fix lands and is verified; the register is small by intent.

## Alternatives considered

- **GitHub Issues.** The standard way to track undiagnosed work. Rejected for this repo because: (1) issues live in a separate UI from the code that agents read in every session, (2) discoverability requires the agent to know to query the issue tracker, (3) closing an issue does not delete its context — stale issues accumulate. The in-repo register is discoverable via `ls docs/`, lives next to AGENTS.md, and is trivially cleaned up via `git rm`.

- **AGENTS.md itself.** Inline open-issue tracking in AGENTS.md was rejected because AGENTS.md is for stable agent instructions, not for ephemeral diagnostic state. Mixing the two would bloat AGENTS.md with content that should be cleaned up after the bug closes.

- **A handoff-doc convention (`handoff-*.md` at repo root).** Considered — there are already several handoff docs in this format. Rejected because handoff docs are session-bounded (handoff from agent A to agent B) while the issue register is session-spanning (an issue tracked across multiple sessions). Mixing the two means handoff docs grow indefinitely with stale issues.

## Consequences

**Easier:** every observed failure has a known disposition (diagnosed now, or registered for future). Future sessions inherit the register as ground-truth backlog. The §6.18 rule has a concrete enforcement mechanism: "did you commit a register entry?".

**Harder:** the register adds a maintenance surface. Stale entries are a tax. The §6.18 rule explicitly says "keep it tight" — closed items are removed, not archived. Discipline is required to clean up promptly; the alternative is the same "graveyard of stale issues" pattern that the GitHub Issues rejection cited.

**Trade-off accepted:** the register is project-internal (no cross-repo discoverability, no issue numbers exposed to PRs). For a single-repo platform-engineering project, that's the right scope; for a multi-repo system, the same content might be better placed in an issue tracker.

## References

- [`../../retrospective/2026-05-28-129.md`](../../retrospective/2026-05-28-129.md) — the source retrospective.
- [`../open-issues.md`](../open-issues.md) — the canonical file.
- PRs the decision was made in: #128.
- AGENTS.md §6.18 — the prose rule the register implements.
