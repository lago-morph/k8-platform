# Log Fetching

Inside the Claude Code web sandbox there is no `gh` CLI, no `gh api`, and
direct egress to `api.github.com` is blocked. The GitHub MCP server attached
to the sandbox covers PRs / issues / content / branches / releases — it does
**not** expose the Actions API. The only working path to workflow logs is the
`ext-github` skill, which routes through the jentic MCP server.

## Primary path: `ext-github`

GitHub's run-wide logs endpoint (`/actions/runs/{run_id}/logs`) returns a 302
to a signed zip URL. Jentic does not follow that redirect, so the run-wide
call comes back as a 500. `ext-github` documents the workaround: list the
jobs in the run, then fetch logs per job (plain text, no zip, no redirect).

Two calls:

1. **List jobs in the run** — `ext-github` operation
   `list_jobs_for_workflow_run` (resource:
   `.claude/skills/ext-github/resources/list_jobs_for_workflow_run.json`).
   Inputs: `owner`, `repo`, `run_id`. Returns `jobs[]` with each job's `id`,
   `name`, `status`, `conclusion`, and `steps[]`.

2. **Download each job's logs** — `ext-github` operation
   `download_job_logs` (resource:
   `.claude/skills/ext-github/resources/download_job_logs.json`).
   Inputs: `owner`, `repo`, `job_id`. Returns plain-text logs as the
   response body. Concatenate bodies if multiple jobs failed.

For `terraform-test.yml`'s current shape there is one job per run, so the
sequence is one list + one download.

### Identifying the failing job(s) without reading every log

After `list_jobs_for_workflow_run`, filter the returned `jobs[]` on
`conclusion == "failure"`. Each job entry already carries `steps[]`, so the
failed step name is available without fetching logs — useful for routing
classification (e.g. is the failure in `terraform plan` versus
`state-bootstrap`?).

Pull logs only for jobs whose `conclusion` is `failure` or `cancelled`. Skip
successful jobs unless the failure cause is suspected to be a cross-job
ordering issue.

### What to keep from the log body

`ext-github` returns the full per-job log. For diagnosis, keep the last
200 lines plus the first occurrence of `Error:` / `error:` with 10 lines of
preceding context. This is enough to feed into the failure taxonomy without
flooding context.

## Why `gh` paths are not listed

Previous versions of this document listed `gh run view --log-failed`,
`gh api .../runs/{id}/logs`, `gh api .../jobs`, and MCP check-run
annotations as a fallback chain. None of those work inside the sandbox:

- `gh` and `gh api` — binary not present, egress blocked.
- MCP `get_commit` `check_runs[].output` — annotations are not populated by
  this project's workflow; the `post-comment.py` summary lives in PR/commit
  comments, not check-run output.

If a future contributor uses `terraform-ci-watch` from a workstation that
*does* have `gh` authenticated, they can read `gh run view "$RUN_ID"
--log-failed` directly — but that path is out of scope for this skill as
invoked from the sandbox.

## Concurrency precondition before re-dispatching

Before re-dispatching after a fix (Phase 4 in `SKILL.md`), `ext-github`'s
own concurrency gate (`workflow_dispatch` precondition) lists queued /
in-progress runs for the same `(ref, phase)` and refuses if more than two
are already queued. The terraform-ci-watch loop relies on that gate; it
does not need to duplicate the check.

## Common pitfalls

- **Stale logs** — GitHub buffers logs; if a run just finished, the per-job
  download may return an empty body. Wait 5–10 s and retry. `ext-github`
  itself is one-shot, so the retry is at the terraform-ci-watch level.
- **Job still running** — `download_job_logs` only returns logs for
  completed jobs. If `list_jobs_for_workflow_run` shows `status: in_progress`
  for the job you care about, return to Phase 2 polling instead.
- **Truncation** — plain-text per-job logs are not truncated by jentic, but
  context-window cost can be significant for long Terraform plans. Trim to
  the relevant section before pasting into context (last 200 lines + first
  `Error:` block).
- **Multiple failed jobs** — concatenate bodies in job order; tag each block
  with the job name so the taxonomy step can route correctly.
