# Spec: `brainstorm-corpus-port`

- **ID**: SKILL-SPEC-fd1201e660
- **Source retrospective**: ../2026-05-25-75.md

## Intent

When a markdown brainstorming corpus grows past a few dozen ideas with cross-references between them, the prose form becomes unmaintainable: queries require regex grep, traceability between cross-references and source ideas lives only in commenter intent, and context truncation lossily flattens the data on later session restarts. This skill ports a markdown brainstorm corpus to a canonical JSON form (with a JSON Schema, a builder that parses the markdown, a verifier that round-trips every row, a structural linter, jq utility queries, and a rendered-markdown view derived from the JSON) so future sessions can query, transform, and audit the corpus programmatically. The pattern was proven in PR #73 on 400 ideas + 466 comments and survived a strict-superset verification of 866 source tuples with zero loss.

## Trigger

Direct triggers — invoke immediately:

- "Port the brainstorm to JSON" / "structure this brainstorm" / "make the brainstorm queryable"
- "Build a JSON view of this corpus"
- The user expresses concern about traceability ("how do these references trace back") for a markdown corpus that has more than ~50 cross-referenced items.

Proactive triggers — offer the skill:

- A brainstorm or research corpus in markdown reaches ~50 items with cross-references.
- The user asks for filtering, ranking, or extraction operations against a prose corpus.
- A markdown corpus is about to be referenced by another tool that needs structured access.

Negative triggers — do NOT invoke for:

- One-off documents with <20 items.
- Linear narratives without cross-references (ADRs, runbooks, retros without nested tables).
- Already-structured corpora (existing JSON, existing database).

## Inputs

- A markdown corpus in a known directory (typically `ai/brainstorming/` or similar).
- Convention: one file per agent / source / track, each containing a pipe-table with ID + content columns.
- Cross-reference files (if any) follow a "per-target section" structure (e.g., `## For A1-...md`).
- The user may specify the canonical schema location (default: alongside the JSON under `tools/`).

## Outputs

- `<corpus_dir>/brainstorm.json` — canonical JSON.
- `<corpus_dir>/tools/brainstorm.schema.json` — JSON Schema (Draft 2020-12).
- `<corpus_dir>/tools/build_brainstorm_json.py` — parser/builder; idempotent.
- `<corpus_dir>/tools/verify_brainstorm.py` — three-pass independent verifier (row counts, comment counts, tuple-equality).
- `<corpus_dir>/tools/lint_brainstorm.py` — schema + structural validation.
- `<corpus_dir>/tools/queries/*.jq` — utility queries (totals, by-agent, by-id, by-phase, by-category, most-discussed, orphan-comments).
- `<corpus_dir>/brainstorm.md` — rendered markdown derived from JSON (single file, all-in-one-view).
- `<corpus_dir>/tools/render_markdown.py` + `verify_rendered_superset.py` — renderer + strict-superset checker.

## Workflow

1. **Audit the source corpus.** Run `grep -c '^|' <corpus_dir>/*.md` to count table rows per file; confirm the user's expected counts match. Identify any cross-reference files (typically `cross-review-from-*.md` or similar naming).
2. **Design the schema.** Top-level: `metadata` (date, branch, totals) + `agents[]` (id, short_mandate, long_mandate, source_file, ideas[], general_comments[]). Each idea: id, idea, category, justification, applies_to_phase, comments[]. Each comment: comment_id, from_agent, to_agent, idea, category, justification, applies_to_phase, references[], external_refs[].
3. **Write the JSON Schema.** Draft 2020-12; relax patterns to accept what the data actually contains (e.g., en-dash phase ranges like `0–6` if any source file used them — lossless port mandate). Validate by running the schema against a hand-crafted minimal fixture.
4. **Write the builder.** Parse each original file's table rows BEFORE the "## Cross-review additions" line. Parse each cross-review file's "## For X-...md" sections. For each comment row, regex-extract `A[1-6]-\d+` references from the idea text to anchor the comment to a specific source idea. If no anchor resolves, add to the target agent's `general_comments` bucket.
5. **Critical: column-boundary regex constraints.** Use `[^|]+?` (no embedded pipes) for short fixed-width columns (ID, category, phase) and `.+?` (may contain backtick-quoted pipes) for long-text columns (idea, justification). Mismatched constraints between builder and verifier produce silent spurious mismatches.
6. **Write the verifier.** Three independent passes: (a) row counts per agent / per cross-review file, (b) per-row tuple equality of `(id, idea, category, justification, phase)` between markdown and JSON, (c) per-row tuple equality of comment rows. Verifier MUST use the same column-boundary regex as the builder.
7. **Write the linter.** Schema validation via `jsonschema` if available; structural fallback covering id patterns, required fields, duplicate-id detection. Linter passes if either check passes.
8. **Write jq queries.** At minimum: totals, ideas-by-agent, idea-by-id (parameterized), most-discussed, by-phase (parameterized), by-category (parameterized), comments-from (parameterized), orphan-comments. Document each in a `queries/README.md`.
9. **Write the renderer.** Read JSON via stdlib `json`. Emit one section per agent, one pipe-table row per idea, comments bulleted by commenter inside each cell. Escape embedded `|` characters to `&#124;` so cell column counts stay correct. Include EVERY source field (id, idea, category, justification, phase) so the rendered file is a strict superset.
10. **Write the superset verifier.** Two passes against the rendered file: (PASS A) every source value must appear somewhere in the rendered file; (PASS B) every value must appear on the same line as the row's durable id. Both passes must report zero missing.
11. **Run everything.** `python3 build_brainstorm_json.py && python3 verify_brainstorm.py && python3 lint_brainstorm.py && python3 render_markdown.py && python3 verify_rendered_superset.py`. Every script must report success.
12. **Commit + PR.** One PR for the whole stack so reviewers see the schema, builder, verifier, linter, queries, renderer, and superset-verifier together.

## Concrete examples

### Example 1: Six-agent brainstorm with 866 source tuples

Input: `ai/brainstorming/{A1..A6}-*.md` (400 idea rows total) + `ai/brainstorming/cross-review-from-{A1..A6,primary}.md` (466 comment rows total).

Builder output:
```
wrote ai/brainstorming/brainstorm.json
  agents=6 ideas=400 comments=466
  comment_associations=430 general_comments=122
```

Verifier output:
```
[1] A1 ideas: markdown=70 json.idea_count=70 json.actual=70 -> OK
... (21 checks total)
VERIFY OK — markdown corpus and brainstorm.json agree on every row.
```

Superset verifier output:
```
sources: 866 tuples (400 ideas + 466 comments)
PASS A (substring presence anywhere):     0 missing
PASS B (co-located on one rendered line): 0 missing
STRICT-SUPERSET CHECK PASSED
```

### Example 2: Bug caught by mismatched regex

First verifier pass reported 7 spurious mismatches. Investigation showed builder used `[^|]+?` for the phase column (forbidding embedded pipes) but verifier used `.+?` for the same column. Rows where justification contained `kubectl logs ... | grep` (literal `|` inside backticks) parsed differently: builder correctly assigned the justification cell with the embedded pipe, verifier wrongly split it across the justification/phase boundary. Fix: align the verifier's regex with the builder's. Zero spurious mismatches after fix.

## Anti-patterns

- **Two independent regexes between builder and verifier.** Drift is silent — the verifier passes or fails on inputs the builder handled correctly. Share the regex via a helper module, or at minimum review side-by-side.
- **Pre-filtering during the port.** If a source row exists in markdown, it MUST exist in JSON. "Lossless" is the contract; any source-row drop is a bug.
- **Tightening the schema to reject existing data.** When A5's en-dash phase ranges (`0–6`) didn't fit a strict `^\d\+$` pattern, the correct response was to relax the schema, not rewrite the data.
- **Skipping the renderer.** Without a rendered-markdown view, the JSON form is unreadable to humans reviewing PRs. The renderer is part of the deliverable, not optional.
- **Trusting "looks right" without running the verifier.** Run all four scripts (build, verify, lint, render+verify-superset) before declaring done.

## Acceptance criteria

- [ ] `verify_brainstorm.py` reports OK on every check (~21 for a six-agent corpus).
- [ ] `lint_brainstorm.py` passes both schema validation (if `jsonschema` installed) and structural fallback.
- [ ] `verify_rendered_superset.py` reports 0 missing on both PASS A (substring presence) and PASS B (co-location on anchor row).
- [ ] Total idea count in JSON matches `grep -c '^| A[1-6]-' <originals>` exactly.
- [ ] Total comment count in JSON matches `grep -c '^| .→A[1-6]-' <cross-reviews>` exactly.
- [ ] Every comment is either anchored to ≥1 source idea OR appears in the target agent's `general_comments` bucket.

## Files this skill creates / modifies

- `<corpus_dir>/brainstorm.json` — canonical JSON.
- `<corpus_dir>/brainstorm.md` — rendered markdown view.
- `<corpus_dir>/tools/brainstorm.schema.json` — JSON Schema.
- `<corpus_dir>/tools/build_brainstorm_json.py` — builder.
- `<corpus_dir>/tools/verify_brainstorm.py` — round-trip verifier.
- `<corpus_dir>/tools/lint_brainstorm.py` — schema linter.
- `<corpus_dir>/tools/render_markdown.py` — renderer.
- `<corpus_dir>/tools/verify_rendered_superset.py` — superset checker.
- `<corpus_dir>/tools/queries/*.jq` — utility queries (7+).
- `<corpus_dir>/tools/queries/README.md` — usage cheatsheet.
