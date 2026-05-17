# Spec: `tell-me-about-this-repo`

## Intent

Implements [`lago-morph/idea-pipeline#16`](https://github.com/lago-morph/idea-pipeline/issues/16) in this repository as a single user-facing skill. The skill answers the broad question "tell me about this repo" by dispatching two sub-skills in parallel — `tell-me-what-this-does` (a conceptual / functionality overview) and `tell-me-where-we-are` (a status / blocker / next-steps report). It also routes single-kind requests to a single sub-skill, and runs a **fresh-context consistency review loop** whenever a request would result in the two summary files being out of step.

The skill exists because the session that produced `summary/functionality-2026-05-17.md` and `summary/status-2026-05-17.md` proved that:

1. Parallel research subagents in isolated worktrees produce useful, distinct artifacts in ≈6 minutes.
2. A serial fresh-context review loop catches 4 major errors a single author would ship — and terminates in 2–3 rounds.
3. The two artifacts must stay consistent or they mislead. Letting them drift over time (different commits, different reviewers) is the fastest way to lose trust in them.

## Trigger

### Direct triggers

- "Tell me what this repo does."
- "Tell me where we are."
- "Give me a summary of this repo."
- "Summarize the repo."
- "What's the status of this project?"
- "How's the project going?"
- `/tell-me-about-this-repo` and the per-sub-skill aliases `/tell-me-what-this-does`, `/tell-me-where-we-are`.

### Routing rules (mandatory)

| User intent | Action |
|---|---|
| Generic summary ("give me a summary", "tell me about this repo") | Dispatch BOTH sub-skills in parallel (worktree-isolated). Then run consistency loop. |
| Functionality-only ("what does this do", "what is this repo") | Dispatch only `tell-me-what-this-does`. If `summary/status-*-<same-hash>.md` exists, run consistency loop after generation. |
| Status-only ("where are we", "what's left to ship", "project status") | Dispatch only `tell-me-where-we-are`. If `summary/functionality-*-<same-hash>.md` exists, run consistency loop after generation. |

### Negative triggers

- Do NOT trigger on narrow questions about a single file or function ("what does `cognito.tf` do?"). Those are normal codebase questions.
- Do NOT trigger on PR-specific questions ("summarize PR #42"). Use a normal subagent.

## Inputs

- The current working repository (read-only access via Read/Bash/grep + GitHub MCP tools restricted to the repo).
- The current `HEAD` commit hash (short form via `git rev-parse --short HEAD`).
- The user's invocation phrasing (used to classify intent per the routing table above).

## Outputs

Files written under `summary/` at repo root. **Filename pattern** (per the upstream issue):

```
summary/{functionality|status}-YYYY-MM-DD-{short-hash}.md
```

Where `YYYY-MM-DD` is the verified UTC date and `{short-hash}` is `git rev-parse --short HEAD` evaluated **at the moment the skill is invoked**. If `HEAD` advances during the run, the filename hash is **not** updated — the hash on disk is the commit the docs describe.

Additionally:

- A `summary/run-log-YYYY-MM-DD-{short-hash}.md` is appended-to (or created) whenever the consistency review loop runs, recording each round's findings and resolution.
- All files are committed and pushed on the active branch. A PR is opened (draft if the harness defaults; finalized if the user requested).

## Workflow

### Step 0 — Verify date and capture commit hash (mandatory)

```bash
UTC_DATE=$(date -u +%Y-%m-%d)
HASH=$(git rev-parse --short HEAD)
```

Verify with a second tool (Python `datetime.UTC` or Node `new Date().toISOString().slice(0,10)`). Both must agree. Record the verification method in the run-log.

### Step 1 — Classify intent

Apply the routing table from the Trigger section. Set `MODE` to one of: `both`, `functionality_only`, `status_only`.

### Step 2 — Check for pre-existing artifacts at the same commit hash

```bash
F="summary/functionality-${UTC_DATE}-${HASH}.md"
S="summary/status-${UTC_DATE}-${HASH}.md"
```

Note: the date in the existing-file pattern is the date the file was written, not necessarily `${UTC_DATE}`. So the existence check globs by hash:

```bash
ls summary/functionality-*-${HASH}.md 2>/dev/null
ls summary/status-*-${HASH}.md 2>/dev/null
```

Set flags `FUNC_EXISTS` and `STATUS_EXISTS` accordingly.

### Step 3 — Generation

- **MODE = `both`**: dispatch `tell-me-what-this-does` and `tell-me-where-we-are` **in parallel** as subagents with `isolation: "worktree"` (one tool call, two `Agent` invocations in the same message). Wait for both, then copy their files into the main worktree's `summary/`.
- **MODE = `functionality_only`**: dispatch `tell-me-what-this-does` only.
- **MODE = `status_only`**: dispatch `tell-me-where-we-are` only.

Sub-skill specs live in `.claude/skills/tell-me-about-this-repo/tell-me-what-this-does/` and `…/tell-me-where-we-are/`.

### Step 4 — Determine if the consistency review loop must run

Run the loop **if and only if both files now exist for the same commit hash** — i.e. either:

- MODE = `both` (always — both were just generated), OR
- MODE = `functionality_only` AND `STATUS_EXISTS` was true at Step 2, OR
- MODE = `status_only` AND `FUNC_EXISTS` was true at Step 2.

If only one file exists for this hash, **skip the loop**. Append a one-line note to the run-log explaining why.

### Step 5 — Fresh-context consistency review loop

Run rounds 1..N until verdict is `clean`. Each round is a **brand-new subagent** (a fresh `Agent` call, not a `SendMessage` continuation).

Per round:

1. Brief the reviewer with: paths of both files, the GitHub MCP tools available, source-of-truth artifacts (the repo, the GitHub API), and the rules.
2. Force severity labels: `major` (wrong claim that would mislead), `minor_factual` (small wrong detail), `cosmetic` (style/formatting).
3. Round 1 may flag cosmetics. **Round 2+ must skip cosmetics entirely.**
4. Reviewer returns a single JSON object with `verdict`, `findings`, `summary`.
5. Orchestrator **independently verifies every `major` finding** before editing (e.g., `grep`, `wc -l`, `ls`, or a GitHub MCP call). If a reviewer is wrong, log it and do not edit.
6. Apply verified fixes to *either* file (or both). Commit with a per-round message like `docs(summary): apply round-N fact-check fixes`.
7. Append the round's findings + resolutions to `summary/run-log-${UTC_DATE}-${HASH}.md`.
8. Terminate when verdict is `clean` AND there are zero `major` and zero `minor_factual` findings.

**Hard limit**: 5 rounds. If round 5 is still not clean, write a `STUCK` block to the run-log naming the unresolved findings and stop. The user decides whether to continue.

### Step 6 — Render verification (mandatory)

Before opening the PR, run a render check on every mermaid block in both files. This is the lesson from PR #13. At minimum:

```bash
# Find pipes inside node labels (mermaid reserves | for edge labels)
awk '/^```mermaid/,/^```$/' summary/*.md \
  | grep -nE '\[[^][]*\|[^][]*\]' && echo "WARN: literal | inside [] node label" || true
```

If a warning fires, fix or escape (replace `|` with `/` or `&#124;`) before pushing.

### Step 7 — Commit, push, PR

Single commit (or multiple, if the loop committed per round) on a feature branch. Push. Open a PR (draft per harness default unless the user said "finalized"). Mention both summary files and the run-log in the PR body. Subscribe to the PR if the user asked.

## Concrete examples

### Example 1 — Generic summary on a fresh repo state

User: "Give me a summary of this repo."

1. `date -u` → `2026-06-01`. `git rev-parse --short HEAD` → `ab12cd3`.
2. MODE = `both`. Neither `summary/functionality-*-ab12cd3.md` nor `summary/status-*-ab12cd3.md` exists.
3. Dispatch both sub-skills in parallel, worktree-isolated. ≈6 min later: two files produced.
4. Step 4 says run the loop (MODE = `both`).
5. Round 1: 12 findings (3 major). Orchestrator verifies majors, edits both files. Round 2: 4 minor. Round 3: clean.
6. Render check: no warnings.
7. PR opened with the three files (two summaries + run-log).

### Example 2 — Status request when functionality already exists for the same hash

User: "Where are we on the project?"

1. `git rev-parse --short HEAD` → `ab12cd3`.
2. MODE = `status_only`. `ls summary/functionality-*-ab12cd3.md` returns `summary/functionality-2026-06-01-ab12cd3.md`.
3. Dispatch only `tell-me-where-we-are`. Generates `summary/status-2026-06-02-ab12cd3.md`.
4. Step 4: `FUNC_EXISTS` was true → run loop.
5. Loop runs 2 rounds, both files get edits, run-log appended.
6. PR opens with status (new) + functionality (edited) + run-log.

### Example 3 — Status request on a hash where no functionality exists

User: "Tell me the status."

1. `ab12cd3`. MODE = `status_only`. `FUNC_EXISTS` = false.
2. Generate status only.
3. Skip the loop (only one file exists for this hash). Append note to run-log: "Loop skipped: only `status` exists for ab12cd3 at 2026-06-03."
4. PR opens with status + run-log.

## Anti-patterns

- **Editing summary files in place for a different commit hash.** The hash in the filename pins the artifact to a moment in repo history. New hash → new file. Never silently update an existing file to "be about" a later commit.
- **Skipping render verification.** PR #13 in this repo's history exists solely because the previous run skipped this step. Mermaid render failures are invisible to fact-checking reviewers — they read the source markdown, not the rendered diagram.
- **Letting the review loop raise cosmetic findings past round 1.** A reviewer can always find one more wording preference. Without severity discipline the loop never terminates.
- **Trusting a reviewer's `major` finding without verifying it.** Reviewers can be confidently wrong. Always run the one-line verification (`grep`, `ls`, `wc`, or an API call) before letting a finding mutate the doc.
- **Squashing the loop into a single commit on merge before reading the run-log.** The audit trail of per-round changes is in `summary/run-log-*.md`, not in git history once squash-merged.
- **Dispatching sub-skills sequentially when the user wanted "a summary".** The point of two sub-skills is parallel execution. Dispatch them in the same tool-use message.

## Acceptance criteria

1. Invoking the parent skill with a generic-summary phrase produces both summary files for `HEAD`'s hash, plus a run-log, plus a PR — within ≈15 minutes of wall-clock.
2. Invoking only the status sub-skill, when the functionality file already exists for the same hash, triggers the consistency loop. Both files end up edited and committed.
3. The review loop terminates with verdict `clean` in ≤5 rounds, OR writes a `STUCK` block to the run-log.
4. Every `major` finding committed has a one-line orchestrator verification in the run-log.
5. The render-verification step rejects mermaid node labels containing literal `|`.

## Files this skill creates / modifies

- `summary/functionality-{date}-{hash}.md` — created or edited.
- `summary/status-{date}-{hash}.md` — created or edited.
- `summary/run-log-{date}-{hash}.md` — created if missing, appended to per round.
- `.claude/skills/tell-me-about-this-repo/SKILL.md` — the skill itself (when installed).
- `.claude/skills/tell-me-about-this-repo/tell-me-what-this-does/SKILL.md` — sub-skill spec (functionality).
- `.claude/skills/tell-me-about-this-repo/tell-me-where-we-are/SKILL.md` — sub-skill spec (status).
