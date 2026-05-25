# agent instruction

**Multi-agent artifacts carry durable prefix-based IDs.** Any artifact produced by multiple agents in a session must carry durable, machine-grep-able prefix-based IDs (e.g., `A1-001`, `A2→A1-001`, `P→A1-001`, `SPEC-B2`). The IDs let cross-references be programmatically verified, let JSON ports anchor comments to source ideas, and survive markdown rendering and context truncation. Free-form references in prose are unrecoverable at scale.

*Grounded in: PR #73 — without per-agent ID prefixes, the JSON port could not have anchored 430 of 466 cross-review comments to specific source ideas via regex extraction.*

# justification

The ID scheme in PR #73 was load-bearing for everything downstream: builder, verifier, JSON schema, jq queries, rendered-markdown view, strict-superset checker. The `A{N}-NNN` pattern (origin ideas) and `A{X}→A{Y}-NNN` pattern (cross-review extensions) were chosen specifically to be regex-extractable from prose. The builder's reference-extraction regex `\bA[1-6]-\d+\b` returned 430 successful anchorings out of 466 comment rows; the remaining 122 (general comments) landed in a clearly-labeled bucket, preserved verbatim rather than fudged.

Without the prefix discipline, "all extensions to A1-019" would require a fuzzy substring search through prose with high false-positive and false-negative rates. With the prefix, it's a `jq` one-liner that returns exact matches.

The cost of the convention is small: subagents need ~one sentence in their brief defining the ID scheme. The cost of omitting it is large: the corpus becomes prose-only and cross-references rot under context truncation. Apply broadly — to brainstorm ideas, to spec IDs, to ADR hashes (already conventionalized in this skill), to test names, to any artifact that another agent or another session will reference.
