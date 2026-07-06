# Spec: `docs-blindness-l1-review`

- **ID**: SKILL-SPEC-81defdbfbe
- **Source retrospective**: ../2026-07-06-256.md

## Intent

Before pointing real, expensive downstream sessions (scenario authors,
integrators, new users) at a published documentation site, prove the
docs are sufficient by *simulating the downstream reader under the same
blindness they will have*. Dispatch several independent subagents, each
given ONLY the published site URL and a concrete task, each forbidden
from reading the source repository, and have each attempt to author the
task to a defined bar. The convergence of independent agents on the
same missing facts is the signal. In this session the method found
defects the doc author could not see from inside the repo — a
cross-page capability contradiction and a resource-count mismatch
between two pages — before a single real scenario session was wasted on
them.

## Trigger

**Direct:** "can the docs actually be used for X?", "test the docs
against the scenarios", "are the docs sufficient", "docs-blindness
check", "would a reader be able to do X from the site alone".

**Proactive — offer when:** a documentation site (or a self-contained
doc set) has just been published or substantially expanded, AND there
is a defined downstream consumer with a defined bar (an L1 scenario, a
getting-started completion, an API integration). Especially offer when
the author claims a wave/section is "complete" — completeness claims
from inside the repo are exactly what this catches.

**Negative:** do not run for internal design docs with no external
consumer; do not run when the "bar" is undefined (you cannot judge
writable vs. blocked without one); do not substitute for the doc author
reading their own pages (this is a second, adversarial pass, not the
first).

## Inputs

- The **published site URL** (the exact surface the downstream reader
  gets — not the repo, not a local build).
- The **list of tasks** the downstream reader must accomplish, verbatim
  (e.g. a scenario catalog).
- The **bar definition** each task is judged against (e.g. the charter's
  L1 definition: actor, preconditions, page-cited steps, oracle).
- Any **role/persona vocabulary** the reader is allowed (so agents flag
  actor-mapping mismatches rather than silently inventing).

## Outputs

- A **verdict per task**: WRITABLE / PARTIAL / NOT WRITABLE against the
  bar, from the site alone.
- A **skeleton per task** as far as the docs support it, with **every
  step citing the site page (by URL path)** it came from.
- A **missing-facts list per task**: each fact the agent needed but
  could not find, why the task needs it, and where it would naturally
  live.
- A **synthesis**: the cross-cutting defects (facts missing across many
  tasks, contradictions between pages), a verdict tally, and a
  disposition for each defect (docs-fix / open-issue / catalog
  correction).

## Workflow

1. **Fix the bar and the vocabulary.** Read the downstream bar
   definition and the allowed persona list. Without these the verdicts
   are unanchored.
2. **Partition the task list across agents** so each agent owns a small
   contiguous block (2–5 tasks) and the union covers everything. Small
   blocks keep each agent's context focused and let them fetch deeply.
3. **Write one hard-boundary prompt**, reused per block. It MUST: name
   the site URL as the ONLY permitted source; forbid Read/Grep/Glob on
   the repo and forbid Bash except `curl` to the site host; forbid prior
   knowledge of *this* platform's internals ("if the site doesn't say
   it, you don't know it"); give the bar definition verbatim; demand the
   three outputs (verdict, page-cited skeleton, missing-facts) in a
   fixed shape; and instruct strictness ("a step you could only write
   from general knowledge plus a guess counts as MISSING, not
   writable").
4. **Dispatch all blocks in parallel**, in the background. They are
   independent; there is no ordering.
5. **Collect and synthesize from the lead's own reading** of the
   returns — do not delegate synthesis. Look specifically for: facts
   missing across multiple blocks (systemic gaps), and any two agents
   independently reporting the same contradiction (the highest-signal
   finding — independent convergence cannot be an artifact of one
   agent's confusion).
6. **Disposition each gap**: a docs-fixable gap → a docs edit; a
   product/implementation gap → an open-issue entry; a task whose
   framing conflicts with reality → a proposed correction to the task
   catalog (do not edit the catalog unilaterally — propose it).
7. **Record the whole thing** in a durable review doc so the verdicts
   outlive the session and seed the downstream backlog.

## Concrete examples

### Example 1 — the cross-page contradiction (this session)

Two of six agents, with no shared context, independently reported: the
tutorial and health-surfaces pages require tenant `kubectl` access, but
the onboarding page states tenant `kubectl` access does not exist, and
no page documents how anyone obtains a kubeconfig. One agent phrased it
as a "cross-cutting docs defect"; the other listed it under missing
facts for three separate scenarios. Because the finding arrived twice
independently, it was certainly real, not one agent's misreading. It
became OI-2026-07-06-5 and drove edits to three pages. A single
self-review by the author would very likely have missed it — the author
knows the access is "obviously" operator-granted and reads past the
contradiction.

### Example 2 — the "not writable as cataloged" verdict

Scenario 16 ("tenant A reads tenant B's secrets; isolation boundaries
hold and denials are observable") came back NOT WRITABLE. The agent's
reasoning: the docs affirmatively document that the isolation boundary
does **not** exist, so there is no denial oracle to author against; the
honest scenario is the inverse (an expected finding that isolation is
missing). This is the method working at its best — it did not just find
a missing page, it found that the *task's own premise* contradicted the
documented (and actual) platform, and proposed re-casting the task.
Disposition: a catalog correction, proposed to the owner, not a docs
edit.

## Anti-patterns

- **Letting an agent peek at the repo "just to check."** The entire
  value is the blindness. One repo read and the agent is no longer
  simulating the downstream reader; it papers the gap the reader would
  hit.
- **Delegating the synthesis.** The convergence signal ("two agents
  found the same contradiction") is only visible to whoever reads all
  the returns together. A synthesizing subagent works from a brief and
  loses it.
- **Running without a bar.** "Are the docs good?" is unfalsifiable.
  "Can this task be written to L1 from the site alone?" is a verdict.
- **Treating every gap as a docs bug.** Some gaps are product defects
  (the feature genuinely doesn't exist) and some are task-framing
  errors. Mis-disposition sends the wrong fix to the wrong place.
- **Editing the downstream task catalog unilaterally** when a task's
  premise is wrong. Propose the correction; the catalog owner ratifies.

## Acceptance criteria

1. Every task in the input list has a verdict and, unless NOT WRITABLE,
   a page-cited skeleton.
2. Every missing fact names where it would live (an existing page or a
   named new one), so the gap is directly actionable.
3. The synthesis separates systemic gaps (multi-task) from one-off gaps,
   and flags every independently-converged finding.
4. Each gap has a disposition (docs-fix / open-issue / catalog
   correction).
5. A durable review artifact is written and survives the session.

## Files this skill creates / modifies

- `planning/<corpus>/l1-readiness-review.md` (or equivalent) — the
  verdict record, cross-cutting defects, and proposed catalog
  corrections. The primary durable output.
- `docs/open-issues.md` (or the project's finding register) — one entry
  per product/implementation gap the review surfaced.
- Docs pages under the doc source tree — the docs-fixable gaps.
