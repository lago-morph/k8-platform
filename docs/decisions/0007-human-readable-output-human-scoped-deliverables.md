# 0007 — Human-facing output must be human-readable, calibrated by the human-scoped-deliverables skill

- **ID**: ADR-891fcd621c
- **Status**: Accepted
- **Date**: 2026-06-07
- **Source retrospective**: [`../../retrospective/2026-06-07-181.md`](../../retrospective/2026-06-07-181.md)
- **PRs covered**: #178 (the convention + skill), #183 (this adoption)

## Context

The auto-013 run summary was first written in a dense, AI-readable style — numbered
sections, inline `§X.Y` plan cross-references, run IDs and hash IDs threaded through
the prose. The owner stopped mid-edit and named the problem: that form "is like
reading directly from individual tables in a SQL database — not possible for a human
to work that way." The same failure mode recurs across run summaries, handoff notes,
PR descriptions, and chat replies — artifacts a human reads to make decisions, not
artifacts another agent consumes. The repo already had a calibration skill for this
exact reader (`human-scoped-deliverables`); it just was not yet a required default.

## Decision

All human-facing output in this repo must present every important fact in
human-readable form, calibrated by the `human-scoped-deliverables` skill, while
canonical AI-to-AI artifacts (specs, ADRs, normalized pipeline output) stay in
normalized form.

Concretely: lead with the idea in plain words; use tables and small (≤7-element)
diagrams; push hash IDs and `§X.Y` cross-references out of the prose into an
audit-trail footer; describe effort rather than estimating hours. This is encoded as
a top-of-file principle in `AGENTS.md` ("Human-readable output is a hard
requirement") and wired into the `autonomous-run` skill's morning-summary
requirements (a four-part plain-language opening plus a pointers/audit-trail footer).

## Alternatives considered

- **Leave it as a per-request preference.** Rejected — the dense form kept recurring
  because nothing made the readable form the default; a one-off correction does not
  generalize.
- **Apply human-readable style to everything, including specs/ADRs.** Rejected —
  canonical AI-to-AI artifacts are the reversible normalized underlay and benefit from
  precision; forcing prose onto them would lose detail the next agent needs. (This ADR
  itself is a canonical artifact and is intentionally written in normalized form.)

## Consequences

- Human reviewers can act on a summary in one read; the load-bearing finding is in the
  headline, not buried in an audit subsection.
- Authors carry a small ongoing cost: relocating exact references to a footer and
  rendering diagrams. The `human-scoped-deliverables` skill absorbs most of that.
- A clear boundary now exists — "is this read by a human or an agent?" — that authors
  must classify correctly; a mis-classification produces either an unreadable summary
  or an under-specified spec.

## References

- [`../../retrospective/2026-06-07-181.md`](../../retrospective/2026-06-07-181.md) — the source retrospective.
- [`../../.claude/skills/human-scoped-deliverables/SKILL.md`](../../.claude/skills/human-scoped-deliverables/SKILL.md) — the calibration skill.
- `AGENTS.md` — the top-of-file "Human-readable output is a hard requirement" principle.
- PRs: #178 (convention + vendored skill), #183 (this adoption).
