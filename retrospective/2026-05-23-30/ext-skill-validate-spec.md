# Spec: `ext-skill-validate`

## Intent

Provide a fast, cheap validator for the structure of `ext-*` child skills produced via the `external-api-bridge` meta-skill. The meta-skill's correctness enforcement is purely procedural — a pre-commit checklist that depends on an agent ticking boxes honestly. This skill closes the loop with a programmatic check that catches the two highest-frequency drift classes: a `resources/*.json` file that misses a required key or has a malformed `*_inputs_schema`, and a child `SKILL.md` that is missing one of the seven required H2 sections. Lands as a single `bash` + `jq` script under `tests/unit/` so it runs in the existing harness (`tests/unit/run.sh`).

Grounding moment: in the 2026-05-23 session that authored `ext-github` (PR #30), the user asked directly whether the new skills had any tests. The answer was "no, verification is procedural." The procedure works when the author follows it; the validator catches the case where a future author drifts. Highest ROI of the three test options offered.

## Trigger

**Direct user phrases:**
- "validate the ext skills"
- "lint the ext-* recordings"
- "add a unit test for ext-github structure"
- "check the skill recordings conform"

**Proactive triggers:**
- Author of a new `ext-{service}` skill via `external-api-bridge` — run before commit.
- Edit to any `.claude/skills/ext-*/resources/*.json` or `.claude/skills/ext-*/SKILL.md`.
- Anyone adding a new `last_verified` date to a recording (re-verify event).

**Negative triggers:**
- Edits to `.claude/skills/external-api-bridge/` itself — that's the parent meta-skill, has its own structure.
- Edits to any non-`ext-*` skill.

## Inputs

- Working tree of the repository.
- Authoritative schema: `.claude/skills/external-api-bridge/resources/README.md` §"Top-level shape" and §"`*_inputs_schema` per-key shape".
- Required SKILL.md sections: enumerated in `.claude/skills/external-api-bridge/resources/TEMPLATE.md` §"Required sections" (1 When to use, 2 Endpoints, 3 Test plan record, 4 Retry policy, 5 Concurrency precondition, 6 Recorded request shape, 7 Recovery on jentic outage) plus the pre-commit checklist block.

No runtime arguments. The skill discovers `ext-*` directories automatically.

## Outputs

- Exit code 0 if every `ext-*` skill passes; non-zero otherwise.
- On failure, one diagnostic line per problem to stderr, in the form `ext-github/resources/workflow_dispatch.json: missing required key 'last_verified'`.
- A summary line: `PASSED: N skills, M recordings checked` or `FAILED: K problems across N skills`.
- No file mutations. Read-only.

## Workflow

1. **Discover.** `find .claude/skills/ -maxdepth 2 -type d -name 'ext-*'` — collect candidate skill directories. Exclude `external-api-bridge` itself.
2. **For each candidate directory:**
   1. Assert `SKILL.md` exists.
   2. Run the SKILL.md section check (step 3 below).
   3. Run the recordings check for every `resources/*.json` (step 4 below).
3. **SKILL.md section check.** Grep for the seven required H2 headings (`## 1. When to use`, `## 2. Endpoints`, …, `## 7. Recovery on jentic outage`). The numbering is fixed by `TEMPLATE.md` — match that prefix exactly. Also assert the pre-commit checklist block (`## Pre-commit checklist`) is present.
4. **Recording check.** For each `resources/*.json`:
   1. Validate it parses as JSON (`jq -e .` returns 0).
   2. Required top-level keys present: `recorded_at`, `last_verified`, `verified`, `request`, `response`. Optional but conventional: `endpoint_ref`, `purpose`.
   3. `verified` is a boolean.
   4. `recorded_at` parses as ISO-8601 (`date -d` accepts it on GNU; on macOS this step is skipped with a notice).
   5. `last_verified` parses as `YYYY-MM-DD`.
   6. `request.method` is one of `GET POST PUT PATCH DELETE`.
   7. `request.url_template` is a string starting with `https://`.
   8. `response.status` is an integer in `100..599`.
   9. For each key in `request.body_inputs_schema`, that key (or its dotted path stem) exists in `request.body`. Symmetric for `query_inputs_schema` / `query`.
   10. Each `*_inputs_schema` entry has a `required` boolean; if present, `values` is an array and `default` is a scalar.
5. **Aggregate results.** Print summary; exit non-zero on any failure.

## Concrete examples

### Example 1 — passes today's `ext-github`

```
$ tests/unit/test_ext_skill_validate.sh
ext-github: SKILL.md sections OK (7/7)
ext-github: 4 recordings OK
PASSED: 1 skill, 4 recordings checked
$ echo $?
0
```

### Example 2 — catches a missing `last_verified` (the exact failure mode this script exists to prevent)

```
$ # An agent added a new recording but forgot last_verified
$ cat .claude/skills/ext-github/resources/get_repository.json
{
  "endpoint_ref": "op_abc...",
  "recorded_at": "2026-06-15T12:00:00Z",
  "verified": true,
  "request": {"method": "GET", "url_template": "https://api.github.com/repos/{owner}/{repo}", "headers": {}},
  "response": {"status": 200}
}
$ tests/unit/test_ext_skill_validate.sh
ext-github/resources/get_repository.json: missing required key 'last_verified'
FAILED: 1 problem across 1 skill
$ echo $?
1
```

The fix is one line in the recording (`"last_verified": "2026-06-15"`). The validator catches it before the commit; the alternative is a future debug session in which the agent has no idea when this endpoint was last confirmed working.

## Anti-patterns

- **Do not test the live API.** The validator is structural. It does not call jentic, it does not call GitHub. Live-fire is the meta-skill's job.
- **Do not normalize or rewrite recordings.** Read-only. If a recording is malformed, surface the diagnostic and let the human fix it.
- **Do not check `endpoint_ref` against jentic's live catalog.** Catalog membership drifts and that's not what this validator owns. The `Last verified` date is the audit signal for catalog drift.
- **Do not add a "warnings" tier.** Pass or fail. Warnings get ignored.
- **Do not couple to a specific service.** The validator inspects every `ext-*` directory it finds. Adding `ext-aws` later requires zero change to the validator.

## Acceptance criteria

1. Runs in under 1 second on a tree with 5 ext-skills × 6 recordings each.
2. Catches each of the validation rules listed in §"Workflow" step 4 with a deterministic diagnostic.
3. Returns 0 on the repo's current state (after PR #30) — i.e., today's `ext-github` is a passing case.
4. Wired into `tests/unit/run.sh` so the existing `phase=test action=test-unit` CI run exercises it.
5. Skippable in editor environments where `jq` or GNU `date` isn't available (graceful warn-and-skip on the ISO-8601 check only; the rest of the rules still run).

## Files this skill creates / modifies

- `tests/unit/test_ext_skill_validate.sh` — the validator itself. Self-contained bash + jq. ~150 lines.
- `tests/unit/run.sh` — one line added to invoke the new test.
- `.claude/skills/external-api-bridge/resources/README.md` — one line added under §"Pre-commit check" pointing at the validator script so the procedural checklist references the programmatic check.
