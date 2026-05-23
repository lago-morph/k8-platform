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
  - mcp__560280ab-3faa-4706-a23f-995ec2d5256f__execute
  - mcp__560280ab-3faa-4706-a23f-995ec2d5256f__load_execution_info
---

# Terraform CI Watch

Drives the loop after a `git push` to a repo whose CI runs Terraform via
GitHub Actions: locate the triggered run, poll until it terminates, fetch
logs on failure, apply a targeted fix, re-push, and escalate after three
failed fix attempts.

## Capability profile

This skill routes its GitHub Actions API calls through whichever path is
available in the current environment. Three profiles are supported,
ranked by preference: **`gh`** CLI, **`github-mcp`** server with Actions
coverage, **`ext-github`** via jentic. Detection and the per-profile
implementation of each abstract operation (LOCATE_RUN, POLL_RUN,
LIST_FAILED_JOBS, FETCH_JOB_LOG, DISPATCH) live in
`reference/capabilities.md`.

The phases below reference operations abstractly. Read
`reference/capabilities.md` once at the start, pick the active profile,
and resolve each operation through §2 of that file.

## When to invoke

- Immediately after a successful `git push` to a non-default branch
- When the user references a GitHub Actions run URL or asks for status
  ("did CI pass?", "watch the build", "what's the status of that run?")
- When a CI failure is reported and a Terraform repo is in scope

## Prerequisites

Verify in one step before starting Phase 1:

- The repo has at least one workflow under `.github/workflows/` that runs
  `terraform`. If not, this skill does not apply.
- Read the project's `CLAUDE.md` first — it may define branch conventions,
  required secrets, or sandbox constraints that shape diagnosis.

## Detect capability profile

Before Phase 1, run the detection sequence in `reference/capabilities.md`
§1. Capture the active profile (`gh` / `github-mcp` / `ext-github`).

If detection returns "none," escalate per `capabilities.md` §1 Step 4 —
no further phases run.

All operation references below (LOCATE_RUN, POLL_RUN, LIST_FAILED_JOBS,
FETCH_JOB_LOG, DISPATCH) resolve via `capabilities.md` §2 under the
active profile.

## Phase 1 — Locate the run

Capture context from local git:

```sh
SHA=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

Call **LOCATE_RUN**(`workflow_id`, `BRANCH`) and take the entry whose
`head_sha` matches `$SHA`. If no entry matches, the run may have been
triggered by an earlier commit, or the workflow does not auto-trigger
on push — wait 10 s and retry up to 3 times before treating as "no run
triggered."

For workflows that are `workflow_dispatch`-only (this repo's
`terraform-test.yml` is), a fresh `git push` does **not** trigger a run.
The agent must DISPATCH explicitly. The project's
`ai/testing-guidelines.md` §3 / §4 says which `(phase, action)` to
dispatch for the current intent.

Capture: `run_id`, `html_url`, `status`, `conclusion`. Reset attempt
counter to 0 if this is a fresh start; otherwise carry it forward.

## Phase 2 — Poll until terminal

Call **POLL_RUN**(`run_id`, `workflow_id`, `BRANCH`) every 30 s. Read
`status` and `conclusion` off the response.

Terminal when `status == "completed"` (any conclusion) or `conclusion in
{failure, cancelled, timed_out}`. Hard cap: 30 polls (15 minutes). If
still not terminal, escalate as "stuck queued/running".

## Phase 3 — On success

Report:

- One-line confirmation
- The `html_url`
- Notable plan output from the workflow's summary comment.

**How this repo posts CI results:** `post-comment.py` posts a Markdown
summary as a **PR comment** if an open PR exists, or as a **commit
comment** if there is no PR. Check runs / commit statuses do NOT carry
the result body — you must read the comment.

These are PR/commit reads (not Actions API), so they don't go through
the capability profile. Use whichever path the environment provides:

- If a PR exists for the branch:
  - `gh pr view <number> --comments` (when `gh` is available); else
  - `mcp__github__list_pull_requests` + `mcp__github__pull_request_read`
    with `method=get_comments`.
- If no PR (commit comment):
  - `gh api "repos/$OWNER_REPO/commits/$SHA/comments"` (when `gh`); else
  - `mcp__github__get_commit` for the SHA — the response includes a
    comments URL. If the MCP server in this sandbox doesn't expose a
    direct commit-comments tool, fall back to the workflow run's summary
    at `html_url` or escalate.

Stop. Do not push further commits.

## Phase 4 — On failure

1. **Fetch logs** — call **LIST_FAILED_JOBS**(`run_id`), then
   **FETCH_JOB_LOG**(`job_id`) for each failed job. See
   `reference/log-fetching.md` for the trimming/processing guidance.
2. **Classify the failure** — see `reference/failure-taxonomy.md`. Match
   the log against known patterns; pick the most specific category.
3. **Apply the fix** — only edit the file the taxonomy entry says to edit.
   Never reach beyond that scope on the first attempt.
4. **Commit** with a message that names the category and root cause:
   ```
   fix(ci): <category> — <one-line cause>
   ```
5. `git push`. If the workflow is `workflow_dispatch`-only, the push
   alone does not trigger a run — call **DISPATCH**(`workflow_id`, `ref`,
   `inputs`) with the same `(phase, action)` as the failing run. The
   concurrency precondition in `capabilities.md` §4 applies: if >2 runs
   are already queued for the same `(ref, phase)`, refuse and escalate.
   Increment attempt counter. Return to Phase 1.

If the taxonomy entry is marked "no — escalate" (e.g., missing-secret,
provider-bug), do not attempt a fix — go straight to Phase 5.

## Phase 5 — Three-strike escalation

After 3 consecutive failed fix attempts (or any "no — escalate" hit), STOP
and use `reference/escalation-template.md` to report. Do not push a 4th
attempt.

## Connectivity failures and profile degradation

If any operation call fails for a connectivity reason (not an
application-level error from GitHub), follow the mid-loop degradation
procedure in `capabilities.md` §3. If degradation lands on `ext-github`
and a subsequent `ext-github` call also fails for connectivity, write
the intended next action into the Current Sandbox Session block in
`ai/handoff.md` per `ai/testing-guidelines.md` §9, commit, and stop.

## Companion skill

If the failing CI step is itself running Crossplane apply / claim
verification, switch to the `crossplane-claim-verify` skill — that one
handles the `Synced`/`Ready` / cloud-side verification loop. The two skills
do not overlap and are intentionally independent.
