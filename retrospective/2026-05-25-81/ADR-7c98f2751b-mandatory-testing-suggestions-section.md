# ADR: Mandatory Testing-suggestions section in SPEC template

- **ID**: ADR-7c98f2751b
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-81.md
- **PRs covered**: #80

## Context

The 15 existing `SPEC-*.md` files (A1–A5, B1–B5, C1–C5) authored in a prior session included a `## 6. Tests required` section listing the must-have tests for the spec to be considered complete. During the 2026-05-25 session's Phase 0 planning, the user requested *"add to every generated spec a 'testing suggestions', for unit, integration and e2e tests to add to that particular item. Also augment in the same way the 15 that are already done."*

The distinction matters: §6 is the **gate** (without these tests the spec is incomplete); the new section is the **broader catalogue** (tests one might add as the surrounding system matures). Conflating the two would either bloat §6 with optional cases (making the gate fuzzy) or leave the catalogue uncaptured (losing testing intent).

This was a structural change to the spec format. All 49 specs in the 2026-05-25 fanout had to follow it; the canonical `SPEC-TEMPLATE.md` had to encode it; and the 15 existing specs had to be retroactively augmented.

## Decision

Add section 7 "Testing suggestions (unit / integration / e2e)" as a mandatory section in the canonical spec template, distinct from section 6 "Tests required" which remains the must-have completion gate.

Section 7's body is three labeled sub-blocks (Unit / Integration / E2E), each listing 1–5 concrete test cases (file path + assertion). When a layer is genuinely not applicable, the spec must say so explicitly with a one-sentence explanation — silent omission is not allowed, because a reader can't tell whether the missing layer was a scoping decision or an oversight.

## Alternatives considered

- **Extend §6 "Tests required" to include unit/integration/e2e sub-blocks.** Rejected because it conflates "the gate" with "the catalogue" — making §6 a vaguer authorial gate.
- **Make the section optional.** Rejected because optional sections drift to "rarely written"; the must-have-or-explicit-N/A discipline is what gives the section signal.
- **Put it in an appendix or a separate file.** Rejected because per-spec test catalogues are most useful at the spec level, in the same document the implementing agent reads top-to-bottom.
- **Keep the prior format and add testing notes ad hoc.** Rejected for the same reason the larger spec format exists: structured docs scale; ad hoc notes don't.

## Consequences

**What becomes easier:**

- Spec readers see all testing intent in one structured location.
- The N/A-with-explanation discipline prevents silent gaps.
- Future phases can lift specific tests from §7 into actual implementation work when adjacent items make them cheap.

**What becomes harder:**

- All 15 existing specs needed retroactive augmentation (one parallel subagent per spec; completed in this session).
- Authors of new specs must thoughtfully address all three layers, even for items where one layer is N/A — adds ~10 min per spec.
- The spec template grew from 12 to 13 sections.

**Trade-off accepted:** ~10 minutes of additional spec authoring cost per item in exchange for a structured per-spec testing catalogue that's recoverable across sessions.

## References

- [`../2026-05-25-81.md`](../2026-05-25-81.md) — the source retrospective.
- `ai/brainstorming/specs/SPEC-TEMPLATE.md` — the template that encodes the requirement.
- `ai/brainstorming/specs/SPEC-A1-crossplane-claim-chain-walk.md` — exemplar augmented spec with the new §7.
- `ai/brainstorming/specs/SPEC-S2-crossplane-trace.md` — exemplar newly-authored spec with §7 from the start.
- PRs the decision was made in: #80.
