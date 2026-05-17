---
name: tell-me-about-this-repo
description: |
  Generates a summary of the repository — either a "what this does"
  (functionality / workflow / CI) document, a "where we are" (project status,
  blockers, next steps) document, or both in parallel. Both outputs are
  diagram-heavy Markdown files committed under `summary/` with the short
  commit hash baked into the filename. When the OTHER kind of summary
  already exists for the SAME commit hash, runs a fresh-context consistency
  review loop and edits both files until they agree.

  Trigger when the user asks: "tell me about this repo", "give me a summary
  of this repo", "summarize the repo", "what does this repo do", "what is
  this repo", "tell me where we are", "what's the project status", "how's
  the project going", "what's left to ship", or invokes
  /tell-me-about-this-repo, /tell-me-what-this-does, /tell-me-where-we-are.

  Do NOT trigger on narrow per-file questions ("what does cognito.tf do") or
  PR-specific summaries — use a normal subagent for those.
---

# Skill: `tell-me-about-this-repo`

Implements the spec at
[`lago-morph/idea-pipeline#16`](https://github.com/lago-morph/idea-pipeline/issues/16)
plus the orchestration rules established in PR #12 of this repo (parallel
subagent research + fresh-context fact-check loop with severity discipline).

## Routing

Apply these rules before doing anything else:

| User intent | `MODE` | Sub-skill(s) dispatched |
|---|---|---|
| Generic — "summary of this repo", "tell me about this repo" | `both` | Both, in parallel |
| Functionality-only — "what does this repo do", "what is this repo" | `functionality_only` | `tell-me-what-this-does` only |
| Status-only — "where are we", "what's left", "project status" | `status_only` | `tell-me-where-we-are` only |

If the phrasing is ambiguous and both interpretations are plausible, ask
the user once via `AskUserQuestion` (`"summary"` vs `"functionality only"`
vs `"status only"`).

## Workflow

### Step 0 — Verify date and capture commit hash

```bash
UTC_DATE=$(date -u +%Y-%m-%d)
HASH=$(git rev-parse --short HEAD)
```

Cross-check the date with a second tool (`python3 -c "import datetime; print(datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%d'))"`). Both must agree. Record the verification in the run-log.

### Step 1 — Detect pre-existing same-hash artifacts

```bash
FUNC_EXISTING=$(ls summary/functionality-*-${HASH}.md 2>/dev/null | head -1)
STATUS_EXISTING=$(ls summary/status-*-${HASH}.md 2>/dev/null | head -1)
```

Decide whether the consistency review loop will need to run after generation (Step 4). It will, if and only if at the end of Step 3 both files exist for `${HASH}`.

### Step 2 — Generation dispatch

Single message containing **both** Agent tool calls when `MODE=both`. Each Agent uses `isolation: "worktree"` and `subagent_type: "general-purpose"`. Pass each sub-skill the inputs `UTC_DATE`, `HASH`, and the sub-skill SKILL.md path.

| `MODE` | Dispatch |
|---|---|
| `both` | `tell-me-what-this-does` + `tell-me-where-we-are` in parallel |
| `functionality_only` | `tell-me-what-this-does` |
| `status_only` | `tell-me-where-we-are` |

When sub-agents return, copy their produced files out of their worktrees into the orchestrator's `summary/` directory.

### Step 3 — Render-verification preflight (mandatory)

For every Mermaid block in every file just written or about to be written:

```bash
awk '/^```mermaid/,/^```$/' summary/{functionality,status}-${UTC_DATE}-${HASH}.md 2>/dev/null \
  | grep -nE '\[[^][]*\|[^][]*\]'
```

If anything matches, fix it (replace `|` with `/` or `&#124;` inside node labels) before proceeding. The `-->|edge label|` arrow syntax is fine — only node labels are checked.

### Step 4 — Consistency review loop (conditional)

Run the loop **if and only if both files now exist for `${HASH}`**:

- `MODE=both` → always run
- `MODE=functionality_only` AND `STATUS_EXISTING` was non-empty in Step 1 → run
- `MODE=status_only` AND `FUNC_EXISTING` was non-empty in Step 1 → run
- Otherwise → skip; note "Loop skipped: only one summary exists for `${HASH}`" in the run-log

Loop mechanics (see [`review-loop.md`](review-loop.md) for the full procedure):

1. Each round dispatches a **brand-new `Agent` call** (never `SendMessage` — fresh context is the whole point).
2. Force severity labels `major` / `minor_factual` / `cosmetic`.
3. Round 1 may include cosmetic findings; round 2+ **must skip cosmetics**.
4. Orchestrator **independently verifies every `major` finding** before editing (record verification command + result in run-log).
5. Apply verified fixes to either or both files. Commit per round: `docs(summary): apply round-N fact-check fixes`.
6. Append round results to `summary/run-log-${UTC_DATE}-${HASH}.md`.
7. Terminate when verdict is `clean` AND zero `major`/`minor_factual` findings.
8. Hard cap: 5 rounds. On hitting it, write a `STUCK` block to the run-log and stop.

### Step 5 — Commit, push, open PR

- Branch should already be a feature branch (not `main`); create one if not. Naming: `docs/summary-${UTC_DATE}-${HASH}` is the default.
- Final commit if uncommitted work remains.
- `git push -u origin <branch>`.
- Open a PR. Default is draft; set `draft: false` only if the user explicitly requested a finalized PR.
- PR body lists the three files (functionality, status, run-log) and embeds a one-paragraph summary plus the round count.

## Outputs

- `summary/functionality-${UTC_DATE}-${HASH}.md` — created/edited
- `summary/status-${UTC_DATE}-${HASH}.md` — created/edited
- `summary/run-log-${UTC_DATE}-${HASH}.md` — created, appended per round

## Anti-patterns

- **Don't overwrite a file with a different hash.** Different hash → different artifact → new filename. The hash anchors the doc to a commit.
- **Don't skip the render-verification preflight.** PR #13 in this repo's history is the entire reason this step exists.
- **Don't let the loop raise cosmetic findings past round 1.** It will never terminate.
- **Don't apply a major-finding edit without independent verification.** Reviewers can be confidently wrong.
- **Don't `SendMessage` to continue a previous reviewer.** Each round needs a brand-new context. Use a fresh `Agent` call every time.
- **Don't dispatch sub-skills serially when both are wanted.** One message, two Agent calls — that's the wall-clock win.

## See also

- [`tell-me-what-this-does/SKILL.md`](tell-me-what-this-does/SKILL.md) — functionality sub-skill.
- [`tell-me-where-we-are/SKILL.md`](tell-me-where-we-are/SKILL.md) — status sub-skill.
- [`review-loop.md`](review-loop.md) — full procedure for the fresh-context consistency loop.
- `retrospective/2026-05-17-13.md` — origin story and design rationale.
- Issue [`lago-morph/idea-pipeline#16`](https://github.com/lago-morph/idea-pipeline/issues/16) — the upstream spec.
