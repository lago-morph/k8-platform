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

## Execution environment

Inside the Claude Code web sandbox there is no `gh` CLI, no `gh api`, and
direct egress to `api.github.com` is blocked. All Actions-API operations
(`workflow_dispatch`, list runs, list jobs, download per-job logs) go
through the **`ext-github`** skill, which routes via the jentic MCP server.
Phases 1, 2, and 4 below name the specific `ext-github` operations to call.

If running outside the sandbox (e.g. a workstation with `gh` authenticated),
the same logical phases apply — substitute equivalent `gh` commands. The
phase structure does not change.

## When to invoke

- Immediately after a successful `git push` to a non-default branch
- When the user references a GitHub Actions run URL or asks for status
  ("did CI pass?", "watch the build", "what's the status of that run?")
- When a CI failure is reported and a Terraform repo is in scope

## Prerequisites

Verify in one step before starting Phase 1:

- The repo has at least one workflow under `.github/workflows/` that runs
  `terraform`. If not, this skill does not apply.
- The `ext-github` skill is present at `.claude/skills/ext-github/` and its
  recordings under `resources/` are dated as `verified` (see that skill's
  §2 table). If `ext-github` is missing for this repo, escalate — the
  sandbox cannot reach the Actions API any other way.
- Read the project's `CLAUDE.md` first — it may define branch conventions,
  required secrets, or sandbox constraints that shape diagnosis.

## Phase 1 — Locate the run

Capture context from local git:

```sh
SHA=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

Owner / repo come from the project (e.g. `lago-morph/k8-platform`); the
sandbox does not have `gh repo view`.

Call `ext-github` `list_workflow_runs` (resource:
`.claude/skills/ext-github/resources/list_workflow_runs.json`). Inputs:
`owner`, `repo`, `workflow_id` (the workflow filename, e.g.
`terraform-test.yml`), `branch=$BRANCH`, `per_page=1`. From the response
take the first entry of `workflow_runs[]`.

Confirm the returned `head_sha` matches `$SHA`. If not, the run was
triggered by an earlier commit — wait 10 s and retry up to 3 times before
treating as "no run triggered". For this repo specifically,
`terraform-test.yml` is `workflow_dispatch`-only, so a fresh `git push` does
**not** trigger a run on its own. The agent dispatches it explicitly via
`ext-github` `workflow_dispatch` (see `ext-github` §2 and the project's
`ai/testing-guidelines.md` §3 / §4).

Capture: `run_id`, `html_url`, `status`, `conclusion`. Reset attempt
counter to 0 if this is a fresh start; otherwise carry it forward.

## Phase 2 — Poll until terminal

Re-call `list_workflow_runs` (same inputs, plus filter for the captured
`run_id` in the returned list — see `ext-github` §3.1 on the single-run-GET
substitute). Read `status` and `conclusion` off the matching entry.

Wait 30 s between polls. Terminal when `status == "completed"` (any
conclusion) or `conclusion in {failure, cancelled, timed_out}`. Hard cap:
30 polls (15 minutes). If still not terminal, escalate as "stuck
queued/running".

## Phase 3 — On success

Report:

- One-line confirmation
- The `html_url`
- Notable plan output from the workflow's summary comment.

**How this repo posts CI results:** `post-comment.py` posts a Markdown
summary as a **PR comment** if an open PR exists, or as a **commit
comment** if there is no PR. Check runs / commit statuses do NOT carry the
result body — you must read the comment.

To read the comment via GitHub MCP tools (available in the sandbox):

- If a PR exists for the branch:
  - `mcp__github__list_pull_requests` (filter `state=open`, `head=<branch>`)
  - `mcp__github__pull_request_read` with `method=get_comments` on the PR
    number.
- If no PR (commit comment): `mcp__github__get_commit` for the SHA — the
  response includes the commit's comments URL. The GitHub MCP server in
  the sandbox does not expose a direct "list commit comments" tool, so if
  the comment isn't reachable that way, fall back to the workflow run's
  summary (visible at `html_url` in a browser) or escalate.

Stop. Do not push further commits.

## Phase 4 — On failure

1. **Fetch logs** — see `reference/log-fetching.md`. The working path in the
   sandbox is `ext-github` `list_jobs_for_workflow_run` + `download_job_logs`
   per failed job. (Run-wide logs returns 500 from jentic — do not call it.)
2. **Classify the failure** — see `reference/failure-taxonomy.md`. Match
   the log against known patterns; pick the most specific category.
3. **Apply the fix** — only edit the file the taxonomy entry says to edit.
   Never reach beyond that scope on the first attempt.
4. **Commit** with a message that names the category and root cause:
   ```
   fix(ci): <category> — <one-line cause>
   ```
5. `git push`. If `terraform-test.yml` is `workflow_dispatch`-only (this
   repo is), the push alone does not trigger a run — re-dispatch via
   `ext-github` `workflow_dispatch` with the same `(phase, action)` as the
   failing run. The skill's concurrency precondition refuses if more than
   two runs are already queued for the same `(ref, phase)`; on refusal,
   escalate. Increment attempt counter. Return to Phase 1.

If the taxonomy entry is marked "no — escalate" (e.g., missing-secret,
provider-bug), do not attempt a fix — go straight to Phase 5.

## Phase 5 — Three-strike escalation

After 3 consecutive failed fix attempts (or any "no — escalate" hit), STOP
and use `reference/escalation-template.md` to report. Do not push a 4th
attempt.

## Jentic outage

If any `ext-github` call fails for connectivity reasons (jentic 5xx,
rate-limited, or PAT expired), `ext-github` is one-shot — it does not
retry. Per `ai/testing-guidelines.md` §9, write the intended next action
(`workflow_id`, `ref`, full `inputs` map, reason) into the Current Sandbox
Session block at the top of `ai/handoff.md`, commit, and stop. A human
resumes via the GitHub Actions UI.

## Companion skill

If the failing CI step is itself running Crossplane apply / claim
verification, switch to the `crossplane-claim-verify` skill — that one
handles the `Synced`/`Ready` / cloud-side verification loop. The two skills
do not overlap and are intentionally independent.
