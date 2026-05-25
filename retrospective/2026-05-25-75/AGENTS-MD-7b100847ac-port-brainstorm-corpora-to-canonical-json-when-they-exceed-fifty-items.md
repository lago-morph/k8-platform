# agent instruction

**Port brainstorm corpora to canonical JSON when they exceed ~50 items.** When a brainstorm, spec, or research corpus in markdown exceeds ~50 cross-referenced items, port it to canonical JSON with a JSON Schema, a builder script that parses the markdown, and a verifier that confirms every source row is present in the JSON. Markdown then becomes a derived view rendered from the JSON, with its own superset verifier. Prose-only corpora lose traceability under context truncation; the JSON form preserves it.

*Grounded in: PR #73, where 400 ideas + 466 comments only became programmatically queryable after the JSON port — the prior markdown-only state had referenceable IDs in prose but no way to extract them.*

# justification

PR #73's six-agent brainstorm fanout produced 13 markdown files with 866 source tuples (400 idea rows + 466 cross-review rows). Every cross-review row referenced at least one source ID inline ("Turn `scripts/whereami.sh` (A1-001) into..."), but this traceability was only recoverable by regex grep on prose. The user explicitly flagged this fragility — *"the reviews have no way to trace back to the source ideas"* — and the JSON port (with schema, builder, three-pass verifier, linter, jq queries, and rendered-markdown view with strict-superset checker) resolved it permanently.

The cost is ~2 hours of one-time port effort plus a per-PR rebuild discipline (run the builder, run the verifier). The benefit is permanent: future sessions can `jq '.agents[].ideas[] | select(.id == "A1-019")'` instead of re-parsing prose; cross-references survive context truncation; "all extensions to A1-019 by reviewer A3" becomes a one-line query. The threshold of ~50 items is approximate but anchored: below that, manual reference-checking is feasible; above it, the cost of repeated re-parsing exceeds the cost of the port.
