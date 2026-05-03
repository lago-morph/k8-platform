---
name: terraform-ci-watch
description: >-
  Use immediately after running `git push` on a Terraform-on-AWS repository
  whose CI runs in GitHub Actions. Polls the triggered workflow run, fetches
  logs on failure, applies targeted fixes to .tf files, re-pushes, and
  escalates after three failed fix attempts. Trigger when the user pushes a
  branch, asks "did CI pass?", asks to "watch the build", references a
  workflow run URL, or reports a Terraform CI failure.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - mcp__github__list_commits
  - mcp__github__get_commit
  - mcp__github__pull_request_read
  - mcp__github__list_pull_requests
---

# Terraform CI Watch

Drives the loop after a `git push` to a repo whose CI runs Terraform via
GitHub Actions: locate the triggered run, poll until it terminates, fetch
logs on failure, apply a targeted fix, re-push, and escalate after three
failed fix attempts.

## When to invoke

- Immediately after a successful `git push` to a non-default branch
- When the user references a GitHub Actions run URL or asks for status
  ("did CI pass?", "watch the build", "what's the status of that run?")
- When a CI failure is reported and a Terraform repo is in scope

## Prerequisites

Verify in one step before starting Phase 1:

- The repo has at least one workflow under `.github/workflows/` that runs
  `terraform`. If not, this skill does not apply.
- Either `gh` CLI is authenticated (`gh auth status`) or the GitHub MCP
  tools are available in this session.
- Read the project's `CLAUDE.md` first — it may define branch conventions
  (e.g., `test/**` for auto-trigger), required secrets, or sandbox
  constraints that shape diagnosis.

## Phase 1 — Locate the run

```sh
SHA=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
OWNER_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
```

Then:

```sh
gh api "repos/$OWNER_REPO/actions/runs?branch=$BRANCH&per_page=1" \
  --jq '.workflow_runs[0] | {id, html_url, status, conclusion, head_sha}'
```

If GitHub MCP tools are available and `gh` is not, use
`mcp__github__list_commits` for the SHA and `mcp__github__get_commit` to
read the commit's check-runs.

Confirm the returned `head_sha` matches `$SHA`. If not, the run was
triggered by an earlier commit — wait 10s and retry up to 3 times before
treating as "no run triggered" (likely the workflow doesn't trigger on
this branch pattern).

Capture: `run_id`, `html_url`, `status`, `conclusion`. Reset attempt
counter to 0 if this is a fresh start; otherwise carry it forward.

## Phase 2 — Poll until terminal

Sleep 30s, re-query:

```sh
gh api "repos/$OWNER_REPO/actions/runs/$RUN_ID" \
  --jq '{status, conclusion}'
```

Terminal when `status == "completed"` (any conclusion) or `conclusion in
{failure, cancelled, timed_out}`. Hard cap: 30 polls (15 minutes). If still
not terminal, escalate as "stuck queued/running".

## Phase 3 — On success

Report:

- One-line confirmation
- The `html_url`
- Notable plan output. Prefer the workflow's PR/commit comment (read via
  `gh pr view --comments` or `gh api repos/$OWNER_REPO/issues/$ISSUE/comments`).
  Fall back to `gh run view $RUN_ID --log` filtered for `Plan:` /
  `No changes` lines.

Stop. Do not push further commits.

## Phase 4 — On failure

1. **Fetch logs** — see `reference/log-fetching.md` for the fallback chain.
   Default: `gh run view $RUN_ID --log-failed | tail -200`.
2. **Classify the failure** — see `reference/failure-taxonomy.md`. Match
   the log against known patterns; pick the most specific category.
3. **Apply the fix** — only edit the file the taxonomy entry says to edit.
   Never reach beyond that scope on the first attempt.
4. **Commit** with a message that names the category and root cause:
   ```
   fix(ci): <category> — <one-line cause>
   ```
5. `git push`. Increment attempt counter. Return to Phase 1.

If the taxonomy entry is marked "no — escalate" (e.g., missing-secret,
provider-bug), do not attempt a fix — go straight to Phase 5.

## Phase 5 — Three-strike escalation

After 3 consecutive failed fix attempts (or any "no — escalate" hit), STOP
and use `reference/escalation-template.md` to report. Do not push a 4th
attempt.

## Companion skill

If the failing CI step is itself running Crossplane apply / claim
verification, switch to the `crossplane-claim-verify` skill — that one
handles the `Synced`/`Ready` / cloud-side verification loop. The two skills
do not overlap and are intentionally independent.
