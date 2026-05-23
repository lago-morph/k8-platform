# Log Fetching

`SKILL.md` Phase 4 calls two abstract operations to assemble a log
bundle for diagnosis:

1. `LIST_FAILED_JOBS(run_id)` — returns the jobs whose
   `conclusion == "failure"`, with `id`, `name`, and `steps[]` per job.
2. `FETCH_JOB_LOG(job_id)` — returns the plain-text log body for one job.

The per-profile implementation of each is in `capabilities.md` §2. This
file covers what to do with the results.

## Step 1 — Identify failed jobs

Call `LIST_FAILED_JOBS(run_id)` and filter to `conclusion == "failure"`.
Each entry's `steps[]` lets you name the failing step without fetching
the log — useful for routing classification (e.g. is the failure in
`terraform plan` versus `state-bootstrap`?). Note the step name(s) per
job.

Skip jobs whose `conclusion` is `success` or `skipped`. For
`cancelled`, fetch the log only if the cancellation cause is unclear
from the run-level state.

## Step 2 — Fetch logs for each failed job

For each failed job, call `FETCH_JOB_LOG(job_id)`. Concatenate the
returned bodies in job order, tagging each block with the job name so
later steps (taxonomy match, escalation report) can route correctly:

```
=== Job: <name> (id=<job_id>) ===
<log body>
=== End job ===
```

If `terraform-test.yml`'s shape stays at one job per run, this is a
single fetch.

## Step 3 — Trim before consuming

Raw per-job logs can be megabytes. Trim before feeding into the failure
taxonomy or pasting into context:

- Keep the **last 200 lines** of each failed job's log.
- Plus the first occurrence of `Error:` / `error:` (case-insensitive)
  with **10 lines of preceding context**, if it lies outside the
  trailing 200-line window.

This is enough to classify the common failure modes documented in
`reference/failure-taxonomy.md` without flooding the conversation.

## Why not run-wide logs?

GitHub's `GET /repos/.../actions/runs/{run_id}/logs` returns a 302 to a
signed zip URL. The `gh` CLI follows the redirect; some MCP servers do;
jentic does not (returns 500). To keep the loop's behavior independent
of which client follows redirects, this skill uses per-job logs across
all profiles. `capabilities.md` §2's "Run-wide logs" note covers this.

## Common pitfalls

- **Stale logs.** GitHub buffers logs; if a run just finished, the
  per-job download may return an empty body. Wait 5–10 s and retry the
  `FETCH_JOB_LOG` call. (The retry is at the `terraform-ci-watch` level
  — `ext-github` is one-shot per call by design.)
- **Job still running.** `FETCH_JOB_LOG` returns logs only for completed
  jobs. If `LIST_FAILED_JOBS` shows `status: in_progress` for the job
  you care about, return to Phase 2 (POLL_RUN) instead.
- **Truncation.** Plain-text per-job logs are not truncated by jentic or
  the GitHub API directly, but each transport has its own size limits.
  If a body comes back suspiciously short, retry once before assuming
  truncation; if the second body matches the first, log it as truncated
  and proceed with what's available.
- **Multiple failed jobs.** Order matters for diagnosis when failures
  cascade (e.g. `state-bootstrap` fails → `plan` fails on missing state).
  Process jobs in the order returned by `LIST_FAILED_JOBS` and look at
  the first failure first.
- **Connectivity failure mid-fetch.** Treat as a profile failure and
  apply `capabilities.md` §3 mid-loop degradation. If degradation
  produces a usable profile, retry the `FETCH_JOB_LOG` under it.
