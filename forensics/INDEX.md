# Forensic corpus — k8s-platform project analysis

**Audience: AI agents.** This corpus is the fact base for a multi-round analysis of
how this project progressed and where it went wrong. It was commissioned by the owner
on 2026-06-10 after the project stalled (see `retrospective/2026-06-09-214-a.md`, the
"accountability retrospective"). Stance: forensic accounting — facts with evidence
pointers, no blame, no verdicts. Conclusions and remediation live in LATER rounds and
must not be back-edited into evidence files.

## Conventions (binding for anyone extending this corpus)

- Every claim is tagged `[FACT]` (with evidence pointer: commit hash, `file:line`,
  PR#, or quoted fragment), `[INFERENCE]` (with one-line reasoning), or `[OPEN]`
  (unresolved; copy into `OPEN-QUESTIONS.md`).
- Evidence files in `evidence/` are append/correct-only: fix errors with a dated
  `CORRECTION:` line, do not silently rewrite. Synthesis files may be rewritten.
- Date format: 2026-MM-DD. PR numbers are continuous 1–214+ across the whole project
  (the apparent "reset" in retro filenames is a no-PR-session fallback, see
  `retrospective/2026-06-05-01.md:4`).
- New analysis rounds: add a file `rounds/ROUND-N-<topic>.md`, link it here, and move
  any resolved `[OPEN]` items from `OPEN-QUESTIONS.md` into it with their resolution.

## Map

| File | What it holds | Status |
|---|---|---|
| `REPORT.md` | Condensed synthesis: progression, what went well, mistakes (user + agent), structural-defect introduction points | round 1 |
| `HYPOTHESES.md` | Owner's hypotheses, each scored against evidence | round 1 |
| `OPEN-QUESTIONS.md` | Consolidated unresolved questions for future rounds | living |
| `evidence/timeline.md` | Git-history reconstruction: phases, churn, rework signatures | round 1 |
| `evidence/retrospectives.md` | The 45-retro corpus: register, lesson-recurrence matrix | round 1 |
| `evidence/instruction-surface.md` | AGENTS.md / skills / hooks accretion record | round 1 |
| `evidence/spec-and-structure.md` | Spec corpus, layer-interface coverage, structure drift | round 1 |
| `evidence/testing-and-verification.md` | Test/CI timeline, done-claim audit, recurring bug classes | round 1 |
| `evidence/autonomous-runs.md` | Unattended-run register, envelope-vs-outcome drift, carry-over debt | round 1 |

## Companion human-facing documents (different rules: written for the owner, per
`human-scoped-deliverables` skill — do not mine them for facts, mine `evidence/`)

- `SUMMARY-FOR-OWNER.md` — plain-language account of what happened, good and bad
- `TURNAROUND-OUTLINE.md` — plain-language sketch of paths to project completion

## Owner feedback log (durable record of round reviews)

- **2026-06-10 (round-1 review).** (a) Design-intent clarification: the platform is
  intentionally **ephemeral** — a demonstration companion to the planned blog series
  (`ai/blog/`), NOT a production cluster; production adaptation is a possible future,
  not the objective. Defect D6 / factor E1 re-framed accordingly (rotation is design;
  durability assumptions in code/process are the defect). (b) Owner **strongly agrees**
  with the other three opinion-level recommendations in `TURNAROUND-OUTLINE.md`:
  restructure this repo in place, pause overnight runs until the clean-build gate is
  green, aggressively archive the rulebook into enforcement. Treat these as settled
  direction for round 2 unless the owner says otherwise.

## Primary exhibits elsewhere in the repo (read-only; do not reorganize during analysis)

- `retrospective/2026-06-09-214-a.md` — agent-authored accountability retro; documents
  the claimed-done-without-clean-build pattern and concludes in-band rules failed
- `AGENTS.md` + `.claude/agents-md/` (47 detail files) — the accreted rule surface
- `.claude/skills/` (~24 skills) — the accreted skill surface
- `ai/handoff.md` — cross-session state file; top banner shows end-state of auto-016
- `SUBSTRATE-READINESS.md` — the clean-build evidence gate created 2026-06-09
- `docs/open-issues.md`, `docs/testing-debt-burndown.md` — registered debt
