# Capability Profile Detection

This skill drives operations against GitHub's Actions API. The sandbox or
host environment determines which path actually reaches the API. Three
profiles are supported, ranked by preference:

1. **`gh`** — local `gh` CLI, authenticated. Fastest path, no broker.
2. **`github-mcp`** — the attached GitHub MCP server exposes the Actions
   API endpoints needed. Varies by sandbox configuration.
3. **`ext-github`** — jentic-mediated, via `.claude/skills/ext-github/`.
   Last-resort path used when neither of the above is available.

Detect once at the start of each invocation (see `SKILL.md` "Detect
capability profile"). The selected profile is the *active profile* for
the duration of that invocation. If a call fails for connectivity
reasons mid-loop, re-detect once — see §3.

## 1. Detection sequence

Run these checks **in order**; first hit wins.

### Step 1 — `gh`

```sh
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
```

Exit 0 → `PROFILE=gh`. Stop.

### Step 2 — `github-mcp`

Inspect the available tools list for the GitHub MCP server's Actions-API
coverage. Look for tools whose names indicate the five required
operations. Common names (case may vary across MCP server versions):

| Operation needed | Likely tool name(s) |
|---|---|
| LIST_RUNS / LOCATE_RUN | `mcp__github__list_workflow_runs`, `mcp__github__list_workflow_run` |
| GET_RUN / POLL_RUN | `mcp__github__get_workflow_run` |
| LIST_JOBS | `mcp__github__list_workflow_jobs`, `mcp__github__list_jobs_for_workflow_run` |
| FETCH_JOB_LOG | `mcp__github__download_workflow_run_logs`, `mcp__github__get_workflow_run_job_logs`, `mcp__github__get_job_logs` |
| DISPATCH | `mcp__github__create_workflow_dispatch`, `mcp__github__run_workflow` |

Require **all five** operations to be covered (under any name) → `PROFILE=github-mcp`.

Partial coverage (e.g. dispatch present but logs missing) → treat as
**not covered** and move on. Partial coverage produces brittle loops
that fall halfway down to a different profile mid-call; the fully-jentic
path is safer than that.

### Step 3 — `ext-github`

All three must hold:

- `.claude/skills/ext-github/SKILL.md` exists.
- At least one `.claude/skills/ext-github/resources/*.json` carries a
  `Last verified` date in `ext-github` §2's endpoint table.
- A jentic execute tool (`mcp__<jentic-server-id>__execute`) is in the
  available tools list.

All three → `PROFILE=ext-github`. Stop.

### Step 4 — None

If no profile matches, **escalate**. Write the situation into the
Current Sandbox Session block in `ai/handoff.md`, commit, and stop. No
path to the Actions API is available.

## 2. Operation × profile dispatch table

All phases in `SKILL.md` (and `log-fetching.md`, `escalation-template.md`)
reference operations by name. This table tells the agent what to call
under the active profile.

`$OWNER_REPO` is the upstream slug (e.g. `lago-morph/k8-platform`).
`$WORKFLOW_ID` is the workflow filename (e.g. `terraform-test.yml`).

### LOCATE_RUN(workflow_id, branch)

Find recent runs of `$workflow_id` on `$branch`. Returns a list; the
caller picks the entry matching `head_sha` (or the most recent).

| Profile | Implementation |
|---|---|
| `gh` | `gh api "repos/$OWNER_REPO/actions/workflows/$workflow_id/runs?branch=$branch&per_page=10"` |
| `github-mcp` | `mcp__github__list_workflow_runs` with `workflow_id`, `branch`, `per_page=10` |
| `ext-github` | `ext-github list_workflow_runs` (resource: `resources/list_workflow_runs.json`) |

### POLL_RUN(run_id, workflow_id, branch)

Read the run's `status` and `conclusion`. Used in a polling loop.

| Profile | Implementation |
|---|---|
| `gh` | `gh api "repos/$OWNER_REPO/actions/runs/$run_id" --jq '{status, conclusion}'` |
| `github-mcp` | `mcp__github__get_workflow_run` if present; else LIST_RUNS + client-side filter on `id == run_id` |
| `ext-github` | LOCATE_RUN-style `list_workflow_runs` + client-side filter on `id == run_id` (single-run-GET catalog gap — see `ext-github` §3.1) |

### LIST_FAILED_JOBS(run_id)

Return jobs in the run whose `conclusion == "failure"`. Each entry has
`id`, `name`, and `steps[]`.

| Profile | Implementation |
|---|---|
| `gh` | `gh api "repos/$OWNER_REPO/actions/runs/$run_id/jobs" --jq '.jobs[] \| select(.conclusion=="failure")'` |
| `github-mcp` | `mcp__github__list_workflow_jobs` (or `list_jobs_for_workflow_run`), filter `conclusion=="failure"` client-side |
| `ext-github` | `ext-github list_jobs_for_workflow_run`, filter `conclusion=="failure"` client-side |

### FETCH_JOB_LOG(job_id)

Return plain-text log body for one job. Per-job, not run-wide — see the
"Run-wide logs" note below.

| Profile | Implementation |
|---|---|
| `gh` | `gh run view --log --job "$job_id"` (or `gh api -H "Accept: application/vnd.github.raw" "repos/$OWNER_REPO/actions/jobs/$job_id/logs"`) |
| `github-mcp` | `mcp__github__download_workflow_run_logs` or `mcp__github__get_job_logs` — whichever the MCP exposes per-job |
| `ext-github` | `ext-github download_job_logs` (resource: `resources/download_job_logs.json`) |

### DISPATCH(workflow_id, ref, inputs)

Trigger a `workflow_dispatch` run. Fire-and-forget (no return value
beyond success/failure of the dispatch itself). Concurrency precondition
in §4 applies to all profiles.

| Profile | Implementation |
|---|---|
| `gh` | `gh api -X POST "repos/$OWNER_REPO/actions/workflows/$workflow_id/dispatches" -f "ref=$ref" -f "inputs[phase]=$phase" -f "inputs[action]=$action"` (one `-f` per input key) |
| `github-mcp` | `mcp__github__create_workflow_dispatch` (or `run_workflow`) with `workflow_id`, `ref`, `inputs` |
| `ext-github` | `ext-github workflow_dispatch` (resource: `resources/workflow_dispatch.json`) |

### Run-wide logs (deliberately not an operation)

GitHub's `GET /repos/.../actions/runs/{run_id}/logs` returns a 302 to a
signed zip. The `gh` CLI follows the redirect; MCP servers vary; jentic
does not (returns 500 — see `ext-github` §3.2). To avoid making the loop
depend on which client follows redirects, all profiles use **per-job
logs**. `FETCH_JOB_LOG` is intentionally per-job. If multiple jobs
failed, call `FETCH_JOB_LOG` once per job and concatenate, tagging each
block with the job name.

## 3. Mid-loop degradation

If a call on the active profile fails for a **connectivity** reason —
not an application-level failure (4xx/5xx from GitHub itself routes to
the failure taxonomy, not here) — re-run the detection sequence once.

| Active profile | Connectivity signal | Likely outcome of re-detect |
|---|---|---|
| `gh` | `command not found` / 401 / `gh auth status` now failing | Demote to `github-mcp` or `ext-github` |
| `github-mcp` | MCP server returns "tool unavailable" / 5xx | Demote to `ext-github` |
| `ext-github` | jentic 5xx / rate-limited / PAT expired | No further demotion possible — escalate via `ai/handoff.md` (see `ai/testing-guidelines.md` §9) |

If re-detection picks the **same** profile and the call still fails,
treat it as an irrecoverable profile failure and escalate. Do not
ping-pong between profiles.

## 4. Concurrency precondition (DISPATCH only)

`terraform-test.yml` has `concurrency: cancel-in-progress: false`, so
dispatches queue rather than cancel each other. Every profile must
implement this precondition before DISPATCH:

> Before DISPATCH, call LOCATE_RUN for `(workflow_id, branch)` and count
> runs whose `status` is `queued` or `in_progress` and whose
> `inputs.phase` matches the intended phase. If that count is `> 2`,
> refuse the dispatch and report verbatim:
>
> > "N runs already queued for {ref, phase}; please intervene."

`ext-github` enforces this internally (see `ext-github` §5). For `gh`
and `github-mcp` the agent applies the gate explicitly around DISPATCH.

The four read operations (LOCATE_RUN, POLL_RUN, LIST_FAILED_JOBS,
FETCH_JOB_LOG) have no concurrency precondition.

## 5. Profile-independent notes

- **Owner / repo / workflow_id** come from the project, not the active
  profile. For `k8-platform`: `owner=lago-morph`, `repo=k8-platform`,
  `workflow_id=terraform-test.yml`.
- **Auth** is handled by each profile's own credential mechanism (`gh
  auth status` for `gh`; the MCP server's configured PAT for
  `github-mcp`; jentic's stored PAT for `ext-github`). No tokens enter
  this repo or the sandbox environment under any profile.
- **Detection is per-invocation, not persisted.** The next invocation
  re-detects from scratch.
