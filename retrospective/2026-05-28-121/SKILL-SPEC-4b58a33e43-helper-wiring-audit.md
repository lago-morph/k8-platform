# Spec: `helper-wiring-audit`

- **ID**: SKILL-SPEC-4b58a33e43
- **Source retrospective**: ../2026-05-28-121.md

## Intent

Audit the project's accumulated helper scripts, unit tests, skills, and pre-commit hooks to confirm each is either auto-triggered or sufficiently advertised, and recommend wiring fixes for the under-advertised ones. Inspired by the 2026-05-28 session where four chainsaw rounds re-discovered bug classes that `scripts/pre-chainsaw-audit.sh` would have caught in seconds — the script existed and was even mandated by AGENTS.md §6.13, but its `pre-dispatch-static-audit` skill's trigger phrases were user-facing only and the agent never invoked it. The skill produces a classification table (auto-used / advertised / under-advertised) and a per-helper remediation recommendation.

## Trigger

**Direct user phrases:**

- "Audit our helpers"
- "Are all the helpers being used?"
- "Find unused / under-advertised helpers"
- "Wiring audit"

**Proactive triggers** (offer when):

- A retrospective notes a bug class that an existing helper could have caught but wasn't fired.
- A new wave of helpers / scripts / unit tests / skills has landed in the last N PRs and nobody has re-audited.
- An AGENTS.md section is added mandating use of a helper (good time to check the helper is wired into something that mechanically enforces the mandate).

**Negative triggers** (don't fire when):

- The repo has fewer than ~10 helpers total — the manual reading cost is lower than the skill's overhead.
- The user is asking about a single specific helper — that's a normal Read + grep task, not an audit.

## Inputs

- The project's `scripts/`, `tests/unit/`, `.claude/skills/`, `.github/workflows/`, `.pre-commit-config.yaml`, and `AGENTS.md` paths.
- A scope window — typically "everything added since date X" or "everything added in the last N PRs". Default: since `origin/main`'s last retrospective commit.
- Optional: an "expected gate type" override map (e.g., "scripts/*.py is auto-used if it has a pre-commit hook OR a workflow step matching its filename").

## Outputs

- One markdown file at `handoff-followups-<date>.md` (or a section in an existing handoff file) containing:
  - Per-category audit table: helper / classification / trigger or wiring / gap.
  - Concrete recommended fixes per under-advertised helper (which gate to wire into; the exact one-line addition).
  - A "newly-discovered orphans" list for helpers that have NO trigger AND NO advertisement.

- A short inline summary in chat (≤20 lines): N helpers audited, M auto-used, K advertised, U under-advertised, O orphans, plus the top-3 recommended-action items.

- **No** code changes. The skill produces a recommendation, not the wiring fix. The user (or a follow-up session) implements the fix.

## Workflow

1. Compute the scope window. Default: `git log origin/main --since "<date>"` filtered to `tests/unit/ scripts/ .claude/skills/ .github/workflows/ AGENTS.md .pre-commit-config.yaml`. If the user specifies a different scope, use it verbatim.
2. Enumerate helpers in scope:
   - `scripts/` — every `*.sh` / `*.py` file (excluding `_lib/` if those are internal).
   - `tests/unit/` — every `test_*.sh`.
   - `.claude/skills/` — every immediate subdirectory.
   - `.github/workflows/` — every `*.yml`.
   - `AGENTS.md` rules added in the window (parse §X headings).
3. For each helper, run the classification probe:
   - **Auto-used**: appears as a step in any CI workflow, OR is the `entry:` of a `.pre-commit-config.yaml` hook, OR is mandated by a hard AGENTS.md rule that the agent's normal session start re-reads (§§ 8.1, 6.3, 6.10 — the "mandatory" sections), OR is invoked by a skill whose trigger language matches the agent's normal working text.
   - **Advertised**: referenced by name in AGENTS.md / `scripts/README.md` / `ai/` docs / a skill description, but no mechanical enforcement.
   - **Under-advertised**: exists, may be referenced once in passing, but no trigger / hook / CI step / skill match positions it where the agent would notice it in the relevant workflow.
   - **Orphan**: not referenced anywhere outside its own file header.
4. For each under-advertised or orphan helper, propose ONE concrete wiring fix. Anchor the recommendation in one of: a hook in `.pre-commit-config.yaml`; a step in a workflow; a tighter trigger in an existing skill; a new AGENTS.md rule (with the exact rule text); a `PreToolUse` hook in `.claude/settings.json`.
5. Write the audit table + recommendations to the output file (typically a section in `handoff-followups-<date>.md`).
6. Print the inline summary.
7. Stop. Do not implement fixes.

## Concrete examples

### Example 1: PR #121 audit (2026-05-28)

Scope: helpers added since `dc333b7` (the prior session's last retrospective commit).

Input: `scripts/` (12 helpers), `tests/unit/` (39 tests), `.claude/skills/` (17 skills), `.github/workflows/` (5 workflows), `.pre-commit-config.yaml` (1 hook).

Probe output:

- `scripts/pre-chainsaw-audit.sh` — under-advertised. Has a skill (`pre-dispatch-static-audit`) and an AGENTS.md rule (§6.13), but the skill's trigger phrases are user-facing ("dispatch chainsaw") and don't match the agent's working text when it issues `mcp__*__execute` directly. **Recommendation:** add a `PreToolUse` hook in `.claude/settings.json` matching `mcp__*__execute` calls with `workflow_id=chainsaw.yml`; block on non-zero exit of `scripts/pre-chainsaw-audit.sh`.
- 17 of 39 `tests/unit/test_*.sh` — under-advertised. In `run.sh` but not in `.github/workflows/unit-tests.yml`'s per-step list. **Recommendation:** append a final `run.sh` catch-all step to `unit-tests.yml`.
- `scripts/aws-creds-check.sh` — advertised (in `scripts/README.md` and `ai/TESTING-PLAN.md`) but no auto-trigger. Multiple retros propose either collapsing it into runbook or promoting it to a hard pre-flight gate. **Recommendation:** decide retain-and-promote vs collapse-into-runbook; document the choice as an ADR.

Output file: `handoff-followups-2026-05-28.md` Section 2 (the audit table itself).

### Example 2: bare-helper-no-skill case

A skill author lands `scripts/composition-render.sh` and a matching `.pre-commit-config.yaml` hook for it. They do NOT author a skill, and they do NOT add an AGENTS.md reference. The next session sees the file via `ls scripts/` but doesn't know when to invoke it.

Probe output: classification = **auto-used** (because the pre-commit hook fires on every staged composition). No recommendation needed — the hook is the auto-trigger. Audit table marks it green.

This example illustrates that a pre-commit hook IS enough wiring for the auto-used category; an additional skill is over-engineering.

## Anti-patterns

- **Treating every helper as needing a skill.** A pre-commit hook is sufficient wiring; a CI step is sufficient wiring. Skills are appropriate for agent-decision-time interventions, not for every helper.
- **Recommending more than one fix per helper.** Pick the single best wiring location and recommend that. Multiple options confuses the implementer.
- **Implementing fixes inside this skill.** The audit and the wiring fix are separate sessions. The user reads the audit, decides which fixes to take, then dispatches.
- **Auditing without a scope window.** A full-repo audit of mature projects produces 200+ items and is unreadable. Always narrow to "what changed in the last N PRs" by default.
- **Classifying as "advertised" just because a file mentions the helper in passing.** "Advertised" means there's a reference positioned where an agent will see it in the relevant workflow — not "exists in any markdown file anywhere".

## Acceptance criteria

- [ ] Every helper in scope is in exactly one classification (auto-used, advertised, under-advertised, orphan).
- [ ] Every under-advertised / orphan helper has exactly one concrete recommended wiring fix with the file path and one-line example diff.
- [ ] The skill produces no code changes, only a markdown audit + inline summary.
- [ ] The inline summary fits in ≤20 lines.
- [ ] Re-running the skill on the same scope window produces identical output (deterministic classification).

## Files this skill creates / modifies

- `handoff-followups-<UTC_DATE>.md` (or appends a new section to an existing handoff file) — the audit output. Path is user-overridable.
- No other writes.
