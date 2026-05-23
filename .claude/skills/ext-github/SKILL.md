---
name: ext-github
description: >-
  Reach GitHub's REST API from the Claude Code web sandbox by routing
  calls through the jentic MCP server. Use this skill to trigger CI
  runs via `workflow_dispatch`, list recent workflow runs, poll a
  specific run's status/conclusion, list the jobs in a run, and
  download per-job logs on failure — operations that the sandbox's
  attached GitHub MCP server does NOT expose and that direct egress to
  api.github.com is blocked from reaching. Drives the inner debug loop
  for `.github/workflows/terraform-test.yml` together with
  `terraform-ci-watch`. Trigger phrases: "workflow_dispatch",
  "trigger CI", "dispatch terraform-test", "list workflow runs",
  "get workflow run status", "list jobs for run", "download job logs",
  "get CI logs", "kick the build", "jentic GitHub", "the sandbox can't
  reach GitHub Actions API".
allowed-tools:
  - Read
  - Bash
  - mcp__560280ab-3faa-4706-a23f-995ec2d5256f__search_apis
  - mcp__560280ab-3faa-4706-a23f-995ec2d5256f__load_execution_info
  - mcp__560280ab-3faa-4706-a23f-995ec2d5256f__execute
---

# ext-github

Bridges the sandbox to GitHub's Actions REST API through the jentic
MCP server. Built per `ai/specs/ext-github-design.md` via the
`external-api-bridge` meta-skill. If the spec disagrees with anything
here, **the spec wins** — fix this skill, not the spec.

## 1. When to use

The sandbox's GitHub MCP server exposes PR/issue/content/branch/release
operations only; it does **not** cover the Actions API. Direct egress
to `api.github.com` is blocked. Use this skill whenever the agent
needs to drive `.github/workflows/terraform-test.yml` end-to-end:
dispatch a phase × action run, poll for completion, then on failure
fetch logs for diagnosis. Pairs with `terraform-ci-watch` (which owns
the polling loop and the 3-strike escalation envelope).

Auth: jentic holds a fine-grained PAT scoped to `lago-morph/k8-platform`
(Actions: read+write, Contents: read, Metadata: read). No tokens enter
this repo or sandbox.

## 2. Endpoints

| Purpose | Endpoint | `resources/` file | jentic op | Last verified |
|---|---|---|---|---|
| Trigger a CI run | `POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches` | `workflow_dispatch.json` | `op_2acb005c9f3704ad` | 2026-05-23 |
| List recent runs of a workflow (and substitute for single-run GET) | `GET /repos/{owner}/{repo}/actions/workflows/{workflow_id}/runs` | `list_workflow_runs.json` | `op_e5f9dfd148ed5018` | 2026-05-23 |
| List jobs in a run (step 1 of the logs workaround) | `GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs` | `list_jobs_for_workflow_run.json` | `op_2064ead94c9950bc` | 2026-05-23 |
| Download per-job logs (substitute for run-wide logs) | `GET /repos/{owner}/{repo}/actions/jobs/{job_id}/logs` | `download_job_logs.json` | `op_c08d23e5bd6966cb` | 2026-05-23 |

`Last verified` is the date the recording was last confirmed working
against the live API. If a call from this skill starts failing and the
`Last verified` date is months stale, suspect jentic catalog drift or
GitHub API changes and re-run the live-fire probe per
`external-api-bridge/reference/procedure.md` before assuming a logic
bug. After any re-verify, bump the date here AND `recorded_at` /
`last_verified` in the corresponding `resources/*.json`.

## 3. Catalog gaps & workarounds

The PR2 live-fire (2026-05-23) found two endpoints in the spec's
original list that don't work as-stated through jentic. Both have a
verified substitute baked into the recordings above. Future agents:
do **not** try to call the broken forms; use the substitute.

### 3.1 No single-run GET (`actions/get-workflow-run` missing from catalog)

- **Original (spec §1):** `GET /repos/{owner}/{repo}/actions/runs/{run_id}` —
  not present in jentic's catalog as of 2026-05-23.
- **Substitute:** Call `list_workflow_runs.json` and filter the
  returned `workflow_runs[]` by `id == run_id`. The single-run GET's
  key fields (`status`, `conclusion`, `created_at`, `html_url`,
  `run_number`) are all present on each list entry. Bandwidth cost is
  trivial for the volumes this project sees (10–20 dispatches ever per
  the spec).
- **Re-check trigger:** if jentic ever adds `actions/get-workflow-run`,
  replace the substitute with a direct call and add a new
  `get_workflow_run.json` recording.

### 3.2 Run-wide logs endpoint returns 500 from jentic

- **Original (spec §1):** `GET /repos/{owner}/{repo}/actions/runs/{run_id}/logs` —
  catalog entry exists (`op_5d341526a28301a9`) but jentic returns
  `500 Internal Server Error`. GitHub's contract is a 302 redirect to
  a short-lived signed URL pointing at a zip archive; jentic does not
  follow that redirect, so the call fails through the bridge.
- **Substitute (two calls):**
  1. `list_jobs_for_workflow_run.json` — enumerate jobs in the run.
  2. `download_job_logs.json` per job — returns plain-text logs
     directly (no redirect, no zip). Concatenate bodies if multiple
     jobs.
  For `terraform-test.yml`'s current shape (one job per run) this is a
  one-extra-call substitute, not a real cost.
- **Re-check trigger:** if jentic adds 302-follow support OR a future
  child skill needs run-wide logs across many jobs, retry the original
  endpoint and record the result.

## 4. Retry policy

One-shot per call. No automatic retries inside this skill. On any
failure — jentic 4xx, jentic 5xx, GitHub 4xx, GitHub 5xx — stop and
escalate to the user (or to `terraform-ci-watch`'s outer envelope,
which owns the classified auto-redispatch decision per spec §4).

## 5. Concurrency precondition

Applies only to `workflow_dispatch` (the one mutating endpoint).

Before dispatching, call `list_workflow_runs.json` filtered to the
same `workflow_id` and (where relevant) the same `branch`. Count runs
whose `status` is `queued` or `in_progress` and whose `inputs`
match the intended `(ref, phase)`. If that count is `> 2`, **refuse**
the dispatch and report verbatim:

> "N runs already queued for {ref, phase}; please intervene."

No automatic diagnosis. No retry. The user unblocks. `terraform-test.yml`'s
`concurrency` block has `cancel-in-progress: false` so queued
dispatches wait their turn; this gate exists to prevent the queue
from growing unboundedly.

The four read endpoints (#2–#4 in the table) are read-only — concurrency
precondition is N/A.

## 6. Recorded request shape

The `resources/*.json` files are the source of truth for call shape.
Do **not** handcraft requests from GitHub's documentation; the
recordings capture exact verified inputs (including jentic's specific
input naming, which differs from raw REST in a few places — `owner`,
`repo`, `workflow_id`, etc. appear as top-level inputs rather than
path parameters).

All four recordings have `verified: true` (live-fired 2026-05-23).
None ship with `verified: false`.

## 7. Recovery on jentic outage

If a call from this skill fails for connectivity reasons (jentic 5xx,
rate-limited, unreachable, or the upstream PAT expired/got revoked),
write the intended next action — including target `workflow_id`,
`ref`, and `inputs` — to the Current Sandbox Session block at the top
of `ai/handoff.md`, commit, and stop. A human resumes by dispatching
manually via the GitHub Actions UI. See the "Jentic outage" paragraph
in `ai/testing-guidelines.md`.

---

## Pre-commit checklist (authoring agent)

- [x] Frontmatter `description:` names every endpoint and includes
      trigger phrases.
- [x] §1 names the gap (no MCP coverage for Actions API + direct
      egress blocked) and the upstream service.
- [x] §2 every endpoint has a row pointing at an existing
      `resources/<endpoint>.json` plus a `Last verified` date.
- [x] §3 documents the two catalog/bridge gaps with substitute
      procedures.
- [x] §3 Test plan record covered below.
- [x] §4 one-shot, no retries, restated.
- [x] §5 concurrency gate set for `workflow_dispatch`; N/A noted for
      the read endpoints.
- [x] §6 recorded-shape pointer; no `verified: false` recordings ship.
- [x] §7 jentic-outage recovery present and pointing at handoff +
      testing-guidelines.
- [x] Every `resources/*.json` conforms to the schema in
      `external-api-bridge/resources/README.md`.
- [x] No aspirational scope: skill names only the four endpoints it
      can actually call.

## Test plan record

Live-fire executed 2026-05-23 against `lago-morph/k8-platform`,
`terraform-test.yml`, run id `26319698837`
(`phase=test action=test-unit` — chosen because it completes in <30s,
mutates nothing, and exercises the full dispatch → list-runs → list-jobs
→ download-logs chain). Run completed successfully.

```
workflow_dispatch         — approved, live-fired 2026-05-23 (204)
list workflow runs        — approved, live-fired 2026-05-23 (200)
get specific run          — catalog gap; substitute via list-workflow-runs filter (verified 2026-05-23)
list jobs for run         — approved, live-fired 2026-05-23 (200)
download run-wide logs    — bridge gap (jentic 500); substitute via list-jobs + download-job-logs (verified 2026-05-23)
download per-job logs     — approved, live-fired 2026-05-23 (200, plain text)
```
