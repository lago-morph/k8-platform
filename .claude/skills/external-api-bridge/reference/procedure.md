# Long-form Procedure — external-api-bridge

This is the step-by-step the meta-skill executes. Two flows:
**create-new** (no `ext-{service}` exists yet for the target service)
and **extend-existing** (a child already exists; user wants a new
endpoint added). The flows share most steps; differences are called
out.

Authority: `ai/specs/ext-github-design.md` §3. If a step here
disagrees with that spec, the spec wins.

---

## Pre-step — figure out which flow

Look under `.claude/skills/`. If a directory matching
`ext-{service}` already exists for the target service, you are in
**extend-existing**. Otherwise you are in **create-new**.

Tell the user which flow you've entered before proceeding. This is
a single sentence, not a question — the user will redirect if
wrong.

---

## Create-new flow

### Step 1 — Catalog search

Use the jentic MCP server to search the catalog for the endpoint(s)
you need. The `search_apis` tool takes a free-text query and a
`max_results` cap; rerun with refined queries until you've covered
every endpoint the new skill is meant to wrap.

Capture every relevant hit:
- Operation ID (`op_...`) — this is what jentic returns; record it
  for the `endpoint_ref` field of each recording.
- Method + path.
- Summary.

Also call `list_credentials` to confirm credentials for the
service are configured. If they're missing, the live-fire step will
fail later — surface the gap now and ask the user to configure them
in the jentic web app before continuing.

### Step 2 — Missing-endpoint handling

If any needed endpoint isn't returned by `search_apis` (even after
refined queries), tell the user which endpoint is missing and ask
them to add the API group via the jentic web app. Then wait
**exactly one user turn**.

A "user turn" is the user's next message, **regardless of content**.
If the next message confirms the addition, re-run `search_apis` and
proceed. If it confirms the API group is unavailable, stop. If it
goes off on a tangent or doesn't address the request, stop the
skill — the user can re-invoke when they're ready.

Do not write a "pending request" to disk. Do not yield indefinitely.

### Step 3 — Endpoint-coverage prompt (create-new only)

Once all needed endpoints are confirmed in jentic's catalog, ask
the user:

> "Are there other endpoints on this service the `ext-{service}`
> skill should also cover while we're here? Would you like
> automated assistance discovering them (search jentic's catalog
> for related endpoints, scan the upstream API surface, etc.)?"

Act on the answer. If they want help discovering, re-run
`search_apis` with broader queries. If they name additional
endpoints, fold those into the next step's test plan. If they say
"just the ones we have," proceed.

### Step 4 — Test-plan negotiation

Produce a draft live-fire test plan. One entry per intended
endpoint. For each entry, spell out plainly:
- **Cost** — what the call does to upstream state (e.g. "starts a
  real CI run" / "read-only — lists existing resources").
- **Side effects** — what changes (resources created, files
  modified, state written, etc.).
- **Resource impact** — sandbox-relevant: runner minutes, AWS state,
  rate limits.
- **Whether you recommend live-firing** — for safe reads, you
  should default to "yes, recommend." For destructive endpoints,
  state the risk in full and let the user decide.

Recommend a **full** live test of every endpoint to be exposed.
This is the project's only defense against schema mismatches
between jentic's catalog and the live API.

Ask the user to approve, modify, or veto each entry. Negotiation
is free-form during this exchange. After approval, the agreed plan
lands in the child skill's "Test plan record" section as a
structured list — one line per endpoint, status `approved` or
`vetoed (reason)`.

### Step 5 — Live-fire execution

Run the approved test plan in the order it appears. For each
endpoint:

1. Use `load_execution_info` on the operation UUID to confirm
   inputs and required parameters.
2. Use `execute` with concrete values for the call.
3. **One shot per call.** If the call fails for any reason, stop
   and escalate to the user — do not retry, do not adjust and
   re-call. Capture the error and report.

If the user vetoed any endpoint during negotiation:
- **Stop the authoring procedure** at this step.
- Report which endpoint was vetoed.
- Ask for explicit direction: (a) skip the endpoint entirely
  (child ships without it), (b) ship with an unverified recording
  (`verified: false`, warning in child SKILL.md), or (c) abandon
  the skill.
- Do **not** silently choose any of these. The user picks.

### Step 6 — Record verified shapes

For each successfully live-fired endpoint:
1. Construct a `<endpoint>.json` file conforming to
   `external-api-bridge/resources/README.md`.
2. Write it to `.claude/skills/ext-{service}/resources/<endpoint>.json`.
3. Set `verified: true`.
4. Populate `endpoint_ref` with the operation UUID jentic returned.
5. Populate `recorded_at` with the current ISO-8601 timestamp.

For any endpoint approved at step 5 as "ship-unverified," construct
the recording from documentation; set `verified: false`; do
**not** invent values that weren't validated.

### Step 7 — Author the child SKILL.md

Copy `external-api-bridge/resources/TEMPLATE.md` to
`.claude/skills/ext-{service}/SKILL.md` and fill in every required
section per the template:
- Aggressive `description:` frontmatter with trigger phrases.
- §1 When to use.
- §2 Endpoints table referencing each `resources/<endpoint>.json`.
- §3 Test plan record (the structured form of the agreed plan from
  step 4).
- §4 Retry policy (one-shot, restated).
- §5 Concurrency precondition (refuse-or-queue for endpoints that
  trigger queued work; "N/A — read-only" for pure reads).
- §6 Recorded request shape (pointer per endpoint + `verified:
  false` warning where applicable).
- §7 Recovery on jentic outage (pointer to the fallback in
  `ai/testing-guidelines.md`).

### Step 8 — Pre-commit checklist

Walk every box in `TEMPLATE.md`'s checklist and confirm it ticks.
This is the meta-skill's enforcement mechanism for Resolution #7 —
do not skip.

If any box doesn't tick, fix the child skill before committing.

### Step 9 — Commit & push

Commit the child skill in logical units (CLAUDE.md commit
standards apply). Push to the working branch. Don't open a PR
automatically unless the user asks — the meta-skill is in the
middle of an authoring session and the user will decide when the
work is PR-ready.

The child skill is now usable. Do **not** add a pointer in
`CLAUDE.md` or `ai/testing-guidelines.md` — discoverability comes
from the aggressive `description:` frontmatter on the child itself
(Resolution #5).

---

## Extend-existing flow

Same as create-new with these differences:

- **Step 1 — Catalog search:** search only for the new endpoint(s)
  the user named. Don't re-search what's already wrapped unless
  asked.
- **Step 3 — Endpoint-coverage prompt: SKIPPED.** The user is
  invoking the skill to add a specific known set. Don't pre-empt
  with "while we're here, want anything else?" — this is the
  extend flow, not a fresh authoring session.
- **Step 4 — Test plan:** covers only the new endpoint(s). Existing
  `<endpoint>.json` files are left untouched **unless** the user
  explicitly asks (during this invocation) for one or more to be
  re-verified. Phrasing might be: "while you're in there, re-verify
  workflow_dispatch." If they ask, add the named existing endpoints
  to the new test plan alongside the new endpoints.
- **Step 6 — Record:** add the new files to the existing
  `resources/` directory. Do not replace files for endpoints not
  explicitly re-verified.
- **Step 7 — Update the child SKILL.md:** add rows to §2 Endpoints
  table, add entries to §3 Test plan record (mark them with a date
  if helpful), update §5 concurrency precondition if the new
  endpoint changes the picture, update §6 to point at the new
  recordings.
- **Step 8 — Checklist:** the checklist covers the whole child
  skill — tick every box, including ones that were already ticked
  in a prior session. If something has rotted (e.g. an old endpoint
  no longer matches the schema in `resources/README.md`), fix it
  before commit.

---

## Failure modes & escalations

These are the explicit stop conditions. The skill **stops** and
**asks the user** in any of these cases — it does not retry, does
not invent, does not paper over.

| Trigger | Action |
|---|---|
| Required endpoint missing from jentic and user can't add it | Stop. Skill not built. |
| One-turn wait elapses with no actionable response | Stop. Re-invocation needed. |
| Live-fire call fails | Stop. Capture error. Escalate. |
| User vetoes an endpoint during negotiation | Stop authoring; ask for direction (skip / ship-unverified / abandon). |
| Pre-commit checklist has any unchecked box | Don't commit. Fix or escalate. |
| Jentic 5xx / rate-limit / unreachable mid-flow | Stop. If this is happening during a *live debug loop* of an existing skill (not authoring), apply the handoff fallback: write the intended next dispatch to `ai/handoff.md`, commit, stop. |

---

## What this skill never does

- Never registers a pointer in `CLAUDE.md` or
  `ai/testing-guidelines.md` — Resolution #5.
- Never adds drift-detection logic — Resolution #13. The recording
  is the verified shape; runtime failures are ordinary failures.
- Never retries a jentic call — Resolution #2.
- Never refuses dispatch against `main` — Resolution #12 (rely on
  repo branch protections).
- Never refuses dispatch on remaining-sandbox-budget grounds —
  Resolution #11 (fire-and-forget).
- Never silently accepts an unverified recording without an
  explicit user decision and a `verified: false` flag.
