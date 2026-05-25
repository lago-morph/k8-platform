# ADR: Brainstorm corpora are stored as JSON canonical with derived views

- **ID**: ADR-24c70f66ae
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-75.md
- **PRs covered**: #73, #75

## Context

PR #73 produced a six-agent brainstorm fanout: 400 ideas + 466 cross-review comments across 13 markdown files. The original prose form had every cross-review row reference at least one source ID inline ("Turn `scripts/whereami.sh` (A1-001) into..."), but this traceability was readable only by humans and grep — there was no programmatic way to query "all extensions to A1-019" without re-parsing prose. The user explicitly flagged this as a fragility: "the reviews have no way to trace back to the source ideas. Am I misinterpreting this?"

Quantification of the problem: of 466 cross-review rows, **all 466** referenced at least one source ID in prose, but the cross-review IDs themselves (`A2→A1-001`) were sequential-per-section rather than pointing-at-source. Reconstructing the (comment → source idea) graph required regex extraction. Without a structured representation, the next session's first action would be to re-implement that extraction.

## Decision

Store any brainstorm corpus exceeding ~50 cross-referenced items as **canonical JSON** with a **JSON Schema**, a **builder** that parses the markdown originals, a **verifier** that confirms every source row round-trips, a **linter** that validates the schema, **jq utility queries** for common operations, and a **rendered markdown view** derived from the JSON (with its own strict-superset verifier). Markdown originals remain on disk as the input source; markdown is **never the canonical form** once the JSON exists.

## Alternatives considered

- **Status quo (markdown only).** Rejected. Traceability is inline-prose-only; queries require regex grep; a later session would have to re-implement the parser anyway. The cost of the port is paid once; the cost of repeated re-parsing is paid every session.
- **SQLite or another embedded database.** Rejected. JSON is human-readable in PRs, plays naturally with `jq`, and survives `git diff` review. SQLite would need either a dump-to-text view or a custom diff tool.
- **YAML.** Rejected. YAML's whitespace sensitivity is brittle for machine generation; JSON's strict syntax catches builder bugs earlier. JSON Schema tooling is also more mature than YAML schema tooling.
- **JSON with no rendered-markdown view.** Rejected. Without a rendered view, the JSON is unreadable to humans reviewing PRs. The renderer with strict-superset verification is part of the deliverable.

## Consequences

**Easier:**
- Programmatic queries via `jq` (totals, by-agent, by-id, most-discussed, by-phase, by-category, etc.).
- Future sessions can `jq` the JSON without re-parsing prose.
- Schema makes the data structure inspectable and lintable.
- Comment-to-source-idea linkages survive context truncation.
- A future "triage" or "ranking" pass can output JSON that joins on the corpus's IDs.

**Harder:**
- Every change to the brainstorm now requires running the builder + verifier (one extra step per PR touching the corpus).
- Schema changes require coordinated updates to builder, verifier, linter, renderer (but the round-trip tests catch drift quickly).

**Trade-off accepted:**
- ~2 hours of one-time port effort + ongoing per-PR rebuild discipline, in exchange for permanent programmatic queryability and traceability that survives session boundaries.

## References

- [`../2026-05-25-75.md`](../2026-05-25-75.md) — the source retrospective.
- [`./SKILL-SPEC-fd1201e660-brainstorm-corpus-port.md`](./SKILL-SPEC-fd1201e660-brainstorm-corpus-port.md) — the skill spec that codifies this pattern.
- PRs the decision was made in: #73.
- See also: AGENTS-MD-7b100847ac (port brainstorm corpora to canonical JSON when they exceed ~50 items).
