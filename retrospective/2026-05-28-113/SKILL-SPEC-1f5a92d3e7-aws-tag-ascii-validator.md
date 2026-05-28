# Spec: `aws-tag-ascii-validator`

- **ID**: SKILL-SPEC-1f5a92d3e7
- **Source retrospective**: ../2026-05-28-113.md

## Intent

Scan any file likely to flow a value into AWS Resource Groups Tagging (Crossplane Compositions, chainsaw scenarios, example XRs, integration test fixtures) for non-ASCII characters in tag-bound fields. AWS rejects non-ASCII tag values with `InvalidRequestException`; the rejection surfaces as a 245s chainsaw timeout that takes substantial wall-clock to diagnose. A pre-commit / unit-test layer ASCII validator catches these before chainsaw runs.

## Trigger

Activate when:
- User edits a chainsaw scenario YAML (`tests/chainsaw/**/chainsaw-test.yaml`) and adds or modifies a `description:` or any `tags.*:` value.
- User edits a Crossplane Composition (`crossplane/compositions/*.yaml`) and modifies a `forProvider.tags.*` base or patches into `forProvider.tags.*`.
- User edits an example XR (`crossplane/claims/example-*.yaml`).
- User runs `bash tests/unit/test_chainsaw_tag_chars.sh` or `bash tests/unit/run.sh`.
- Slash-command `/check-aws-tags` (if exposed).

Do NOT activate when:
- The file is a markdown comment or docstring (non-ASCII OK there).
- The file is under `retrospective/` or `docs/decisions/` (retrospective text is allowed to use em-dashes).

## Inputs

- Working tree state.
- Optional explicit file list (skill argument).

## Outputs

- Stdout report: PASS / FAIL per scanned file, with line numbers and the offending character (Unicode codepoint hex).
- Exit code 0 if all PASS, 1 otherwise.

## Workflow

1. Discover candidate files: `find tests/chainsaw crossplane/claims crossplane/compositions -name '*.yaml' -type f`.
2. For each file:
   a. Strip YAML comments (lines starting with `#`) — comments are allowed any character set.
   b. Scan each non-comment line that matches the tag-bound patterns: `^\s*description:`, `^\s*tags:\s*$` followed by indented key/value lines, `^\s*Description:`, `^\s*Name:`.
   c. For each match, scan the value for any byte > 0x7F (non-ASCII).
   d. If found, emit `<file>:<line>: non-ASCII char U+<hex> in '<line-content>'`.
3. Exit 0 if no offenders; exit 1 otherwise.

## Concrete examples

**Example 1**: `tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml:29` contains:
```yaml
description: "chainsaw scenario 00 — happy path"
```
The em-dash `—` (U+2014) is non-ASCII. The skill emits:
```
tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml:29: non-ASCII char U+2014 in 'description: "chainsaw scenario 00 — happy path"'
```
Exit 1. Fix: replace `—` with `-`.

**Example 2**: `tests/chainsaw/platform-secret/02-data-rotation/chainsaw-test.yaml` after fix:
```yaml
description: "chainsaw scenario 02 - rotation"
```
Pure ASCII. Skill emits `tests/chainsaw/platform-secret/02-data-rotation/chainsaw-test.yaml: PASS`. Exit 0.

## Anti-patterns

- **Scanning comment text.** Comments are documentation, not tag-bound values; rejecting em-dashes there breaks human-readable narrative.
- **Allowlisting "common" non-ASCII chars** (em-dash, en-dash). The rule is binary: AWS Tagging service rejects most Unicode punctuation. Maintaining an allowlist is fragile.
- **Running only on chainsaw scenarios.** Example XRs (`crossplane/claims/example-*.yaml`) flow into the same Composition path and have the same exposure; include them.

## Acceptance criteria

1. Exit code 0 when all in-scope files are pure ASCII in tag-bound fields; exit 1 otherwise.
2. Comments are exempt (a file with `# this scenario covers — happy path` in a comment passes).
3. Runs in < 1 second on the repo's full chainsaw + claims tree.
4. Surface each offender's location (file + line) and the Unicode codepoint, so the human can paste the codepoint into a search engine if unfamiliar.
5. Idempotent — re-running on unchanged tree produces identical output.

## Files this skill creates / modifies

- `tests/unit/test_chainsaw_tag_chars.sh` — the implementation (already exists, written during auto-003 PR #105 commit `d843915`).
- No files modified at runtime; the skill is a validator, not a fixer. Users fix manually by replacing the offending character with its ASCII equivalent.
