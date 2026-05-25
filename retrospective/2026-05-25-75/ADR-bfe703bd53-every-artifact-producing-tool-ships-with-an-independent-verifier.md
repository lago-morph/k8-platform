# ADR: Every artifact-producing tool ships with an independent verifier in the same PR

- **ID**: ADR-bfe703bd53
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-75.md
- **PRs covered**: #73

## Context

PR #73 shipped four artifact-producing tools (JSON builder, schema, renderer) in stages. After writing the JSON builder, the obvious next move was "looks done, ship it" — but instead the discipline was to write `verify_brainstorm.py` first and run it against the just-built JSON. That run reported **7 spurious mismatches**: rows where the verifier's regex parsed cell boundaries differently than the builder's. Inspection showed the verifier used `.+?` for the phase column while the builder used `[^|]+?`. Rows containing backtick-quoted pipes (`Replaces \`kubectl logs ... | grep\`...`) parsed correctly in the builder but split incorrectly in the verifier. Without an independent verifier shipped in the same PR, this bug would have lived silently until a future session noticed counts didn't match.

The same pattern repeated with the renderer: the rendered-markdown view had to be a strict superset of the source, so `verify_rendered_superset.py` was authored alongside it with two passes (substring presence and co-location-on-anchor-row). The verifier reported 0 missing on both passes — but only because it was actually run, not because the renderer was "obviously correct".

## Decision

Any tool that produces an artifact (JSON port, rendered markdown, schema-generated code, migration output, structured-data extract) MUST ship in the same PR as an **independent verifier script** that confirms the artifact's correctness against the source by an algorithm distinct from the producer's. "Independent" means: different code paths, ideally different regex/parsing rules (subject to AGENTS-MD-95295de038 about sharing parsing constraints when correctness requires it), and operating on the canonical source — not the producer's intermediate state.

## Alternatives considered

- **Unit tests on the producer only.** Rejected. Unit tests verify what the author expected; an independent verifier catches what the author didn't expect. The 7 spurious mismatches were a regex-mismatch bug the producer's author would not have written a unit test for.
- **Trust the human review.** Rejected. A 466-row markdown file vs a 481 KB JSON file is not humanly verifiable. The reviewer needs the verifier to do the comparison.
- **Verifier in a follow-up PR.** Rejected. Decouples the production from the verification, allows the producer to land without correctness evidence, and creates a window where the artifact may be consumed by a downstream agent that assumes it's correct.

## Consequences

**Easier:**
- Every artifact-producing PR has machine-checkable correctness evidence on day one.
- Bugs in the producer surface immediately (the verifier failed before the JSON was committed).
- Future agents modifying the producer have a regression test for free.
- Reviewers can read the verifier alongside the producer to understand the contract.

**Harder:**
- Roughly 2x the code per artifact-producing tool (the verifier is often comparable in size to the producer).
- Verifier and producer can drift if a parsing rule changes in one but not the other (mitigated by AGENTS-MD-95295de038).

**Trade-off accepted:**
- ~50-100% additional code for each tool, in exchange for actionable correctness evidence at PR time. Roughly the same ratio as production code to tests, but with an "evidence on the artifact, not just the code" framing that matters when the artifact will be consumed by other tools.

## References

- [`../2026-05-25-75.md`](../2026-05-25-75.md) — the source retrospective.
- [`./SKILL-SPEC-fd1201e660-brainstorm-corpus-port.md`](./SKILL-SPEC-fd1201e660-brainstorm-corpus-port.md) — the skill where this discipline was first formalized.
- See also: AGENTS-MD-95295de038 (shared parsing constraints across producer and verifier).
- PRs: #73 (verifier caught 7 spurious mismatches that would have shipped silently).
