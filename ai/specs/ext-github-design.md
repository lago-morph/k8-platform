# External API Bridge + ext-github — Design Spec

**Status:** **ACCEPTED** (2026-05-23). All 23 risks resolved across
five review iterations. PR1 implementation unblocked. Phase E
discovery probe succeeded — see §8.

**Scope reminder.** Total dispatch volume over the project's lifetime
is expected to be 10–20 dispatches ever. The bridge only has to be
durable until platform implementation completes.

---

## Non-goals — do not build, do not resurrect

- **Do not** introduce, restore, or extend any file-commit-based CI
  trigger (e.g. `.trigger-action.json`, `agent-trigger.yml`, or
  branch-name auto-triggers like `test/**`). These mechanisms were
  removed in PR #23 because they exist *only* to work around the very
  sandbox limitation that this skill removes. If you find references
  to them in historical files or in the §HISTORICAL section at the
  bottom of this file, treat them as history, not design input.
- **Do not** preserve "fallback paths" to the old mechanisms. There
  is no fallback. `terraform-test.yml` is `workflow_dispatch`-only
  by design, and this skill is what dispatches it.
- **Do not** synthesize a hybrid design from this spec and any other
  doc. If this spec disagrees with anything else in the repo,
  **this spec wins**. Stop and ask the user before reconciling.
- **Do not** "be helpful" by harmonizing this design with patterns
  you find elsewhere in the codebase. A prior session failed
  precisely because the agent tried to merge this spec with the
  deleted trigger-file machinery.

---

## 1. Skills

### PR1 — `external-api-bridge` (parent meta-skill)

Files under `.claude/skills/external-api-bridge/`:

- `SKILL.md` — frontmatter with aggressive `description:` and trigger
  phrases; body covering when to use (§2), procedure summary,
  pointers to template and reference.
- `resources/TEMPLATE.md` — child-skill scaffold with mandatory
  headings + pre-commit checklist.
- `resources/README.md` — defines the strict JSON schema for
  `<endpoint>.json` files (§6).
- `reference/procedure.md` — long-form discovery / test-plan /
  authoring procedure, including the explicit "extend an existing
  child" sub-procedure (§3.2).

Plus one bundled workflow edit:

- `.github/workflows/terraform-test.yml` — set
  `cancel-in-progress: false` on the workflow-level `concurrency`
  block.

### PR2 — `ext-github` (child skill)

Endpoints in scope:

| Purpose | Endpoint |
|---|---|
| Trigger a CI run | `POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches` |
| List recent runs | `GET /repos/{owner}/{repo}/actions/runs` |
| Get a specific run | `GET /repos/{owner}/{repo}/actions/runs/{run_id}` |
| Get run logs on failure | `GET /repos/{owner}/{repo}/actions/runs/{run_id}/logs` |

Files under `.claude/skills/ext-github/`:

- `SKILL.md` — built from `resources/TEMPLATE.md`.
- `resources/<endpoint>.json` — one file per endpoint, conforming to
  the schema in `external-api-bridge/resources/README.md`.
- Pre-commit checklist completed.

Plus one documentation paragraph in `ai/testing-guidelines.md`
covering the handoff-fallback on jentic outage.

---

## 2. When to invoke the meta-skill

Three triggers:

1. Sandbox network policy blocks direct egress to an upstream API.
2. No MCP tool covers the desired operation.
3. An MCP tool advertises coverage but is not actually usable in the
   current sandbox.

---

## 3. Meta-skill procedure

Two flows: **create-new** and **extend-existing**.

### 3.1 Create a new `ext-{service}` (when no child exists yet)

1. **Catalog search.** Call the jentic MCP server to search for the
   endpoint(s) needed.
2. **Missing-endpoint handling.** If a needed endpoint isn't in
   jentic, ask the user to add it via the jentic web app and wait
   **exactly one user turn** for confirmation. If no confirmation
   arrives, stop; user re-invokes when ready.
3. **Endpoint-coverage prompt.** Ask the user: "Are there other
   endpoints on this service this `ext-{service}` skill should
   cover while we're here? Would you like automated assistance
   discovering them?" Act on the answer.
4. **Test-plan negotiation.** Produce a draft live-fire test plan —
   one entry per intended endpoint, with cost / side effects /
   resource impact for each. Recommend a full live test of every
   endpoint to be exposed. Ask the user to approve, modify, or veto
   each entry (free-form during negotiation). After approval the
   plan lands as a structured list in the child skill's "Test plan
   record" section (§5 item 4): one line per endpoint with status
   `approved` or `vetoed (reason)`.
5. **Live-fire execution.** Run the approved test plan. Each call
   is one-shot — no retries. On failure, stop and escalate. If the
   user vetoed any endpoint during negotiation, the meta-skill does
   not silently skip it: stop the authoring procedure and ask for
   explicit direction — skip the endpoint, ship with an unverified
   recording (and a `verified: false` note in the child SKILL.md),
   or abandon.
6. **Record verified shapes.** For each successful probe, write
   `resources/<endpoint>.json` in the child skill's tree, conforming
   to the schema in `external-api-bridge/resources/README.md` (§6).
7. **Author the child skill** using `resources/TEMPLATE.md` and
   complete the pre-commit checklist.
8. **Done.** No automatic registration in `CLAUDE.md` /
   `ai/testing-guidelines.md` — rely on aggressive frontmatter on
   the child skill itself.

### 3.2 Extend an existing `ext-{service}` (add a new endpoint)

1. **Catalog search** for the new endpoint(s) only.
2. **Missing-endpoint handling** as in §3.1 step 2 if needed.
3. **Skip the endpoint-coverage prompt** — the user is already
   invoking the skill to add a known set of endpoints.
4. **Test plan covers only the new endpoint(s).** Existing
   `resources/<endpoint>.json` files are left untouched unless the
   user explicitly requests re-verify of one or more during this
   invocation (free-form: "while you're in there, re-verify X"). If
   requested, those endpoints are added to the new test plan
   alongside the new endpoints.
5. **Live-fire execution** as in §3.1 step 5.
6. **Record verified shapes** as in §3.1 step 6, adding to (not
   replacing) the existing `resources/` directory.
7. **Update the child SKILL.md** to list the new endpoints, complete
   the pre-commit checklist for the additions.

---

## 4. Cross-cutting policies

- **Retries.** Every jentic call from any `ext-*` skill is one-shot.
  On failure, escalate.
- **CI re-dispatch after a fix.** After diagnosing a CI failure and
  applying a fix, the agent may auto-re-dispatch once if
  `terraform-ci-watch`'s failure-taxonomy classifies the failure as
  transient (network, AWS throttling, runner allocation, jentic
  5xx). Logic failures hand off. The outer 3-strike envelope from
  `terraform-ci-watch` is respected.
- **Concurrency.** `terraform-test.yml` has
  `cancel-in-progress: false` so dispatches queue. Before
  dispatching, `ext-github` lists queued/in-progress runs for the
  same `(ref, phase)`. If more than two are already queued, the
  skill **refuses the dispatch and reports verbatim** to the user
  ("N runs already queued for {ref, phase}; please intervene"). No
  automatic non-destructive diagnosis.
- **No drift detection.** Recorded shapes in
  `resources/<endpoint>.json` document the verified request
  contract. The agent does not compare live response shapes against
  a recorded shape; runtime failures are handled as ordinary
  failures.
- **Discoverability.** Aggressive `description:` frontmatter on every
  skill. No `CLAUDE.md` / `INDEX.md` / SessionStart-hook plumbing.
- **Wait state.** One-turn timeout on the meta-skill's
  wait-for-user-to-add-API step.
- **Mandatory sections.** TEMPLATE.md headings + pre-commit
  checklist; enforcement is procedural inside the meta-skill.
- **Scope creep.** Accepted. Boundary between MCP and `ext-*`
  coverage depends on host policy.
- **Jentic outage.** When an `ext-github` call fails for
  connectivity reasons, the agent writes the intended next dispatch
  to `ai/handoff.md`, commits, and stops. Human resumes via Actions
  UI.
- **Sandbox budget.** Fire-and-forget.
- **Main-branch dispatch.** No skill-level restriction; rely on repo
  branch protections.

---

## 5. TEMPLATE.md required sections

Each `ext-{service}` child must include:

1. **Frontmatter** — aggressive `description:`, trigger phrases,
   `allowed-tools` list.
2. **When to use** — the specific gap this skill fills.
3. **Endpoints** — table of `{purpose, endpoint,
   resources/<endpoint>.json}`.
4. **Test plan record** — the approved live-fire plan from the
   authoring session(s), including vetoed entries with their reason.
   Updated when the extend sub-procedure adds new endpoints.
5. **Retry policy** — one-shot per call (cross-cutting, restated).
6. **Concurrency precondition** — for endpoints that trigger queued
   work, the >2-queued refuse-and-report rule.
7. **Recorded request shape** — pointer to `resources/<endpoint>.json`
   for each endpoint.
8. **Recovery on jentic outage** — pointer to the handoff-fallback
   in `ai/testing-guidelines.md`.
9. **Pre-commit checklist** — one box per section above plus
   "shapes in `resources/<endpoint>.json` conform to the schema in
   `external-api-bridge/resources/README.md`."

---

## 6. `resources/README.md` schema

The README in `external-api-bridge/resources/` defines the strict
shape of `<endpoint>.json` files that every child skill writes:

```json
{
  "endpoint_ref": "jentic catalog identifier (optional)",
  "recorded_at": "ISO-8601 timestamp",
  "request": {
    "method": "POST | GET | ...",
    "url_template": "https://api.example.com/...",
    "headers": { "Content-Type": "application/json", "...": "..." },
    "query": { "branch": "main", "per_page": 1 },
    "query_inputs_schema": {
      "branch": { "required": true },
      "per_page": { "required": false, "default": 30 }
    },
    "body": { "...": "..." },
    "body_inputs_schema": {
      "phase":  { "required": true, "values": ["base", "management", "test"] },
      "action": { "required": true, "values": ["plan", "apply", "verify", "apply-and-verify", "destroy"] },
      "ref":    { "required": true }
    }
  },
  "response": {
    "status": 204
  }
}
```

### `*_inputs_schema` per-key shape

Each entry in `body_inputs_schema` or `query_inputs_schema` uses
this fixed shape:

| Key       | Type              | Required? | Meaning |
|-----------|-------------------|-----------|---------|
| `required`| bool              | yes       | Whether the input must be supplied at call time. |
| `values`  | array of literals | no        | Enumerated allowed values. Omit when the value space is unbounded (e.g. `ref`). |
| `default` | literal           | no        | Value to substitute when the key is absent at call time (only meaningful when `required: false`). |

Examples in the README cover three shapes: enumerated
(`action: { required: true, values: [...] }`), free-form
(`ref: { required: true }`), defaulted
(`per_page: { required: false, default: 30 }`).

### Notes on the recording

- `endpoint_ref` is **optional**; populated when jentic returns a
  stable identifier, omitted otherwise. (In practice jentic does
  return `op_*` UUIDs — see §8.)
- `recorded_at` is informational; audit only.
- `response.status` only — no response body schema.
- `request.body` / `request.query` are the verified working values
  from the live-fire test — concrete examples.
- `request.body_inputs_schema` / `request.query_inputs_schema` list
  which keys are call-time inputs vs fixed. Keys in `body` /
  `query` not listed in the corresponding schema are fixed and
  reused as-is.
- POST endpoints typically use `body` + `body_inputs_schema`; GET
  endpoints typically use `query` + `query_inputs_schema`. Either
  pair may be omitted when the method doesn't carry that section.
- `headers` are recorded literally; auth headers are NOT recorded —
  jentic supplies them at call time.
- `url_template` uses `{owner}`, `{repo}`, etc. as path placeholders.

The README also includes one fully-worked example
(`workflow_dispatch`) so child authors have a concrete model. The
worked example is populated from PR2's probe output and lands as a
follow-up commit to PR1 if PR1 ships first with a placeholder.

---

## 7. Out of scope

Not part of PR1 or PR2:

- File-commit-based CI triggers and any fallback to them.
- Drift detection.
- Non-destructive queue diagnosis.
- `CLAUDE.md` / `INDEX.md` / SessionStart-hook discoverability
  plumbing.
- CI lint of `ext-*` skill structure.
- Forbidden-surface list / per-endpoint file split / skill rename
  for scope-creep prevention.
- Sandbox-budget gating.
- `ref=main` protection at the skill level.
- Persistence of meta-skill wait state.

---

## 8. PR ordering and gating

1. PR1 lands first: meta-skill + workflow edit.
2. Discovery probe (catalog search only) confirms GitHub's
   `workflow_dispatch` endpoint is reachable via jentic.
3. PR2 lands after the probe and after the user-approved live-fire
   test plan has executed successfully and shapes are recorded.

### Phase E probe result (recorded 2026-05-23)

- `POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches`
  is present in jentic's catalog as operation `op_2acb005c9f3704ad`
  (operation_id `actions/create-workflow-dispatch`, github.com API
  version 1.1.4).
- Jentic credentials include a `STATIC_BEARER_TOKEN` for
  `api.github.com` — PR2's live-fire phase is authenticated.
- PR1 implementation is unblocked.

---
---
---

# HISTORICAL — DO NOT USE AS DESIGN INPUT

**Everything below this line is preserved for audit only.** It is
the pre-resolution form of this design plus the risk-by-risk
mitigation choices that led to the accepted spec above. The active
design is §1–§8 above. If §1–§8 conflicts with anything below,
§1–§8 wins. A future session reading this file should normally
**stop at this line** and only descend below when investigating
*why* a particular choice was made.

---

## H1. Resolutions audit trail

The table below records, for every risk surfaced during the
resolution loop, the user's selected mitigation and a one-line
reasoning. The original a/b/c options for risks 1–12 are in §H6.
Risks 13–23 were surfaced by the Phase D critique loop and resolved
inline; see commit history (`8800a07`, `fa95f6f`, `020a4fd`,
`e2976a0`, `52b1745`) for the dialogue context.

| # | Risk title                              | Selected mitigation | Reasoning |
|---|-----------------------------------------|---------------------|-----------|
| 1 | Probe has side effects                  | (d) Defer per-skill | Meta-skill (PR1) prompts the user to negotiate a test plan at child-authoring time. No one-size-fits-all probe policy baked into the template. |
| 2 | Retry cap against mutating API          | (c) No retries      | One shot per call, then escalate. Probe-time verification (negotiated per Risk #1) makes production retries unnecessary. |
| 3 | Concurrency vs cancel-in-progress       | (c)+queue-depth gate | Disable `cancel-in-progress` so dispatches queue. ext-github also checks queue depth (>2 → refuse-and-report; see Risk #14 which superseded the diagnosis attempt). Implies a workflow edit, bundled into PR1. |
| 4 | Jentic search output fidelity           | (d) Test-plan dialog | During PR1's test-plan negotiation, the meta-skill explicitly recommends a full live test of every API to be exposed. At call time, drift handling is "no detection" (see Risk #13). |
| 5 | Cross-session discoverability           | (d) Aggressive metadata | Rely on a generous `description:` frontmatter in each skill. No `CLAUDE.md`/`INDEX.md`/hook plumbing added preemptively; revisit only if discoverability problems are observed. |
| 6 | Wait-state across context compaction    | (c) One-turn timeout | Skill waits exactly one user turn for confirmation, then stops. User re-invokes if needed. No persistence machinery. |
| 7 | Mandatory sections on `ext-*` skills    | (a) TEMPLATE + checklist | TEMPLATE.md ships with required headings plus a pre-commit checklist. Procedural enforcement inside the meta-skill. No CI lint. |
| 8 | Scope creep in `ext-github`             | (d) Accept           | What is and isn't covered by an MCP server depends on the sandbox host's policy. Boundary cannot be enforced at the skill level. |
| 9 | Jentic outage mid-loop                  | (a) handoff fallback | When `ext-github` call fails (jentic 5xx, rate-limited, or unreachable), agent writes the intended next dispatch to `ai/handoff.md`, commits, stops. Human resumes via Actions UI. |
| 10| Auto-redispatch on CI failure           | (b) Class-based      | Auto-retry once on classified-transient failures (network, AWS throttling, runner allocation, jentic 5xx). Hand off on logic failures. Respects `terraform-ci-watch`'s 3-strike envelope. |
| 11| Sandbox-budget policy for long CI runs  | (a) Fire-and-forget  | Agent dispatches regardless of remaining sandbox budget. Total dispatch volume 10–20 ever — optimising for rare end-of-session case is overengineering. |
| 12| Dispatch targeting `main`               | (c) Rely on repo     | No skill-level restriction. Relies on repository branch protections / environment protection rules. |
| 13| Drift detection trigger is fuzzy        | (c) Drop drift detection | No drift detection. Runtime call failures handled as ordinary failures. |
| 14| Queue-depth gate self-vs-other          | (c) Refuse-or-queue  | No diagnosis. If >2 runs already queued for `(ref, phase)`, refuse and tell the user verbatim. |
| 15| `resources/<endpoint>.json` format      | (a) Strict JSON schema | `resources/README.md` defines required top-level keys. TEMPLATE.md checklist references the schema. |
| 16| Extending an existing ext-{service}     | (a) Explicit sub-procedure | `reference/procedure.md` defines an "extend" flow distinct from "create new". |
| 17| `request.body` not templatable          | (a) Add body_inputs_schema | Schema adds a `body_inputs_schema` field listing which body keys are call-time inputs vs fixed. |
| 18| `endpoint_ref` may not exist            | (a) Optional         | `endpoint_ref` is optional in the schema. In practice jentic returns `op_*` UUIDs (confirmed Phase E). |
| 19| `action-class` field is vestigial       | (a) Drop             | Removed from TEMPLATE.md. No current resolution depends on it. |
| 20| `body_inputs_schema` per-key shape       | (a) Fixed sub-shape  | Each entry: `required` (bool), optional `values` (array), optional `default`. |
| 21| GET query parameters not in schema      | (a) Add query parallel | Schema adds `request.query` and `request.query_inputs_schema`, parallel to body. |
| 22| Veto of a load-bearing endpoint         | (a) Stop and ask     | Meta-skill stops authoring and asks for direction (skip, ship-unverified, abandon). No silent fallbacks. |
| 23| Test-plan friction for GETs vs POSTs    | (d) Pragmatic        | No formal resolution. Agent applies sensible defaults at invocation time. |

---

## H2. Original background

This work happens inside Claude Code on the web — an ephemeral,
isolated cloud sandbox in which Claude Code executes one session at
a time. The sandbox is cloned fresh from the repository at session
start and is reclaimed when the session ends, so anything worth
keeping must be committed and pushed before the container dies. The
active deployment target during a CI run is a Pluralsight AWS
sandbox with a fixed wall clock (4 hours), an instance count cap,
and a constrained list of allowed instance types. Operational
envelope and per-phase resource budgets live in
`ai/testing-guidelines.md`.

The platform itself is built in iterative phases (0 through 6, see
`ai/handoff.md`). Phases 0 and 1 are Terraform modules (`base` and
`management`); later phases layer in Kubernetes resources,
Crossplane claims, and platform components on top of that base. The
repo's CI workflow (`.github/workflows/terraform-test.yml`) accepts
a `phase × action` dispatch matrix. A single working session fires
many dispatches, plus retries inside the inner debug loop. The
agent's intended role is to drive that loop end to end without
human intervention until a phase is green.

**The blocker driving this spec:** the GitHub MCP server attached
to the sandbox exposes pull request, issue, content, branch, and
release operations only. It does **not** expose `workflow_dispatch`.
The sandbox provides no `gh` CLI, no `hub` CLI, and no direct
GitHub REST API access — the network policy blocks the egress. The
agent therefore cannot trigger any `workflow_dispatch` CI run on
its own.

A second MCP server — **jentic** — *is* attached. Jentic is a
third-party broker for external APIs. Credentials for upstream APIs
are managed by the user inside jentic's own web app, not in this
repository and not in the sandbox environment. The strategy uses
jentic to reach GitHub's `workflow_dispatch` endpoint, bypassing
the missing MCP primitive without introducing new tokens or secrets.

(Note: an earlier draft of this background referenced `test/**`
branch auto-triggers as a workaround. Those were removed in PR #23
and must not be reintroduced — see Non-goals at the top of this
file.)

---

## H3. Original user directive (verbatim)

The user gave this direction in lieu of an earlier proposal that is
intentionally fenced out of this file. Two edits to the original
message text: the opening sentence rejecting the earlier proposal
was removed; the original skill names (`jailbreak-api`,
`jb-{service}`) were replaced with the agreed final names
(`external-api-bridge`, `ext-{service}`), shown in square brackets.

> Instead use a [bridge] with the jentic mcp server hitting GitHub api.
>
> First, create a skill for using jentic to call an api when the sandbox
> blocks direct access or you hit an auth wall. The name of this skill
> should be [`external-api-bridge`].
>
> The way you do this is you check to see if a service exposes an api
> you want to call. Then use the jentic mcp server, and search for the
> api you need. If you can't find anything, ask the user to add that
> api group to jentic, then wait for user confirmation. If user says it
> isn't available, stop. Otherwise, check again with jentic server. If
> it is still not found tell user and wait for operator. If it comes
> back found, try to set up a test so you can ensure the api does what
> you want. If it doesn't, experiment up to 5 times with variations of
> this api or other apis. If you can't figure it out, tell user and wait.
> The name for these created skills should be [`ext-{service name}`],
> for instance for GitHub it would be [`ext-github`], for aws would be
> [`ext-aws`]. If you figured it out, then enter that api and instructions
> in the ext-{servicename} skill for how to use it, what it does, and when it should be used.
> If it doesn't exist, use the template in [`external-api-bridge`]/resources
> to create. You should create this template as part of creating the external-api-bridge skill,
> explaining to the future agent user of an ext-{servicename} skill how to access a skill with jentic
> mcp, and how to add new APIs to this ext-{servicename} skill (the sequence I described
> above).
>
> Then use this to create [an `ext-github`] skill to do what you need.

---

## H4. Original design sketch (pre-resolution)

This is the initial PR1/PR2 sketch before the resolution loop. It
is **superseded** by §1 above.

**PR1 — `external-api-bridge` (parent meta-skill).** Scaffolding
only. Provides a `TEMPLATE.md`, a `resources/` directory, and
documentation explaining the discovery-and-test procedure. No API
calls of its own.

**PR2 — `ext-github` (child skill).** Narrowly scoped. Wraps
GitHub's `workflow_dispatch` endpoint and the minimum supporting
read endpoints needed to drive the inner debug loop.

The original sketch described PR1 as "scaffolding only." The
resolution loop promoted PR1 to scaffolding + meaningful runtime
procedure (catalog search, endpoint-coverage prompt, test-plan
negotiation, etc.) and bundled in a one-line workflow edit
(`cancel-in-progress: false`).

---

## H5. Original meta-skill flowchart

```mermaid
flowchart TD
    Start([Agent needs to call an external API]) --> Search{Endpoint already<br/>in jentic catalog?}
    Search -->|Yes| ProbeDef[Define a safe probe target<br/>per the child skill]
    Search -->|No| AskUser[Ask user to add the API group<br/>via the jentic web app, then wait]
    AskUser --> UserResp{User confirms<br/>added?}
    UserResp -->|User says unavailable| Stop1([Stop. No skill built.])
    UserResp -->|User confirms| RecheckCat{Endpoint<br/>now in catalog?}
    RecheckCat -->|No| StopOp([Tell user, wait for operator])
    RecheckCat -->|Yes| ProbeDef
    ProbeDef --> Probe[Run safe probe via jentic]
    Probe --> ProbeOK{Probe returns<br/>expected shape?}
    ProbeOK -->|Yes| Record["Record verified request shape<br/>ref + inputs map + content-type<br/>in child skill resources/"]
    ProbeOK -->|No| RetryGate{Action class allows<br/>another retry?}
    RetryGate -->|Yes, retry budget left| Probe
    RetryGate -->|No| StopEsc([Stop, escalate to user])
    Record --> Register[Register child skill: add pointer<br/>in CLAUDE.md and ai/testing-guidelines.md]
    Register --> Done([Child skill ready for use])
```

**Superseded.** The retry gate ("action class allows another
retry?") was removed by Resolution #2 (one-shot, no retries). The
"register in CLAUDE.md" step was removed by Resolution #5
(aggressive frontmatter, no canonical-file pointers). The active
procedure is §3 above.

---

## H6. Original §Open risks (with a/b/c mitigations)

Preserved here so the resolutions in §H1 can be traced back to the
options that were on the table. Each risk's full text including
likelihood / severity / three alternative mitigations follows the
form in the pre-resolution spec.

### 1. Probe has side effects

The discovery probe step in the meta-skill procedure cannot be a
no-op for `workflow_dispatch`. There is no dry-run mode in GitHub's
API — every dispatch is a real run.

- (a) Require every child skill to declare a "probe target" in its
  front matter, fixed to a read-only path where the upstream
  supports it.
- (b) Add a `dry_run: true` workflow input to `terraform-test.yml`
  that returns immediately after parsing inputs.
- (c) Skip the live probe entirely and verify the endpoint via
  jentic's schema/introspection response alone.

### 2. Retry cap against a mutating API

The user's directive allows up to five experimental variations
during probe setup. Five failed dispatches against a mutating
workflow action at 2–5 minutes each is 10–25 minutes of session
time plus partial AWS state churn.

- (a) Cap retries by **action class** in the meta-skill template.
- (b) Per-action configurable retry count, with a default of 1 for
  any action whose class isn't proven read-only.
- (c) Disable in-skill retries entirely — one shot, then escalate.

### 3. Concurrency vs the workflow's `cancel-in-progress`

`terraform-test.yml` uses `cancel-in-progress: true`. A second
dispatch for the same `(ref, phase)` will silently cancel the
first run mid-`apply`, leaving a held state lock and possibly
half-applied resources.

- (a) `ext-github` performs a pre-flight check; refuses to
  dispatch when a run is `in_progress` or `queued`.
- (b) Pre-flight wait up to a bounded interval before refusing.
- (c) Disable `cancel-in-progress: true` so follow-up dispatches
  queue rather than cancel.

### 4. Jentic search output fidelity

A "hit" in jentic's catalog might return only the endpoint name
and URL, without the full input schema. Wrong inputs result in a
silent HTTP 422 from GitHub, or worse, a run that proceeds with
default values that don't match the agent's intent.

- (a) The meta-skill's record step requires capturing the *exact*
  verified request shape from the successful probe.
- (b) Require a contract-test artifact (a JSON file showing a
  known-good request body) plus a re-validation script.
- (c) Use jentic's introspection API (if it has one) to fetch the
  full endpoint schema. (Unavailable in practice — jentic exposes
  no introspection API.)

### 5. Cross-session discoverability

Skills are not auto-indexed by topic. A fresh session that needs
to dispatch CI will not know `ext-github` exists unless something
points at it from the files the session reads on startup.

- (a) Add a one-line pointer in `CLAUDE.md` and in the relevant
  section of `ai/testing-guidelines.md`.
- (b) Maintain `external-api-bridge/INDEX.md` listing all `ext-*`
  children.
- (c) Add a `SessionStart` hook that scans for `ext-*` skills.

### 6. Wait-state across context compaction

The meta-skill procedure has the agent pause and wait for the user
to add a missing API to jentic. If the session compacts context,
the resume agent loses the "I'm waiting on the user" state.

- (a) Persist the wait state to a tracked file before yielding.
- (b) Encode the wait into `ai/handoff.md` as a "blocked on" entry.
- (c) Don't yield indefinitely. Set a timeout (e.g. one user turn).

### 7. Mandatory sections on `ext-*` skills

Several risks are addressed by content inside each child skill.
Without enforcement, that content drifts across new skills.

- (a) Ship a `TEMPLATE.md` with required headings plus a
  pre-commit checklist.
- (b) Add a lint script under `.github/scripts/` that validates
  required sections.
- (c) Convention only — enforcement falls to code review.

### 8. Scope creep in `ext-github`

The name `ext-github` is generic enough to invite future use for
any GitHub API call, duplicating the MCP server.

- (a) Skill description explicitly states scope plus a forbidden-
  surface list.
- (b) Split `ext-github` into per-endpoint files.
- (c) Rename the skill to `ext-github-dispatch`.

### 9. Jentic outage mid-debug-loop

If jentic returns a 5xx after `apply` has succeeded but before
`verify` is dispatched, the agent is stuck with live AWS resources
and no path forward from inside the sandbox.

- (a) Documented fallback: agent writes intended next dispatch to
  `ai/handoff.md` and stops.
- (b) Cache last known good request signature + a manual-recovery
  runbook in the skill itself.
- (c) Accept the risk and document it as a known limitation.

### 10. Auto-redispatch on CI failure

When CI fails mid-loop, the agent has to decide whether to
dispatch a fresh run automatically or hand off to the user.

- (a) Always hand off on CI failure.
- (b) Auto-retry once for transient failures, hand off on logic
  failures.
- (c) User configures a max-auto-retry value at session start.

### 11. Sandbox-budget policy for long CI runs

The 4-hour sandbox clock can elapse during a CI run. A dispatch
fired late in a session can plausibly outlive the sandbox.

- (a) Fire-and-forget. Dispatch regardless of remaining budget.
- (b) Refuse to dispatch if estimated runtime exceeds remaining
  budget; write a "blocked on time" entry to handoff.
- (c) Hybrid: fire-and-forget for read-only; refuse for mutating.

### 12. Dispatch targeting `main`

Nothing in the design prevents `ext-github` from firing a
dispatch against `ref=main`, bypassing branch-based review.

- (a) Hard refusal in `ext-github`: error if `ref` matches the
  default branch. Documented override flag required to dispatch
  against `main`.
- (b) Refuse on `main` for mutating actions only.
- (c) No skill-level restriction; rely on the workflow's own
  branch protections.

---

## H7. Original §Decisions already taken

These were pre-decided at spec authoring time and were not part of
the resolution loop:

- **Auth/credentials.** Managed exclusively by the user in the
  jentic web app. No tokens enter the repository or the sandbox
  environment.
- **Audit trail.** Each dispatch appears in the GitHub Actions run
  history and in jentic logs only. No per-dispatch git artifact.
- **Naming.** Parent skill is `external-api-bridge`. Children
  follow `ext-{service-name}` (e.g. `ext-github`, `ext-aws`).
- **Sequencing.** Parent meta-skill ships in PR1; concrete
  `ext-github` in PR2. PR2 is gated on a successful jentic
  discovery probe.

---

## H8. Original critique placeholder

The pre-resolution spec contained an empty §Critique placeholder
to be populated by the next agent. The critique loop ran across
five draft iterations and surfaced risks #13–#23, all recorded in
§H1 with their selected mitigations.
