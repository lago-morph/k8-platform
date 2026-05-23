# Resolved Design — external-api-bridge + ext-github

**Status:** **ACCEPTED** (iteration 5). Folds §Resolutions from
`ai/specs/ext-github-design.md` (rows 1–23) into the design itself.
This is the resolved design that PR1 and PR2 will implement.

**Scope reminder.** Total dispatch volume over the project's lifetime
is expected to be 10–20 dispatches ever. The bridge only has to be
durable until platform implementation completes.

---

## 1. Skills

### PR1 — `external-api-bridge` (parent meta-skill)

Files under `.claude/skills/external-api-bridge/`:

- `SKILL.md` — frontmatter with aggressive `description:` and trigger
  phrases (Res #5); body covering when to use (§3), procedure summary,
  pointers to template and reference.
- `resources/TEMPLATE.md` — child-skill scaffold with mandatory
  headings + pre-commit checklist (Res #7).
- `resources/README.md` — defines the strict JSON schema for
  `<endpoint>.json` files (Res #15).
- `reference/procedure.md` — long-form discovery / test-plan /
  authoring procedure, including the explicit "extend an existing
  child" sub-procedure (Res #16).

Plus one bundled workflow edit (Res #3):

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
  the schema in `external-api-bridge/resources/README.md` (Res #15).
- Pre-commit checklist completed.

Plus one documentation paragraph (Res #9) in `ai/testing-guidelines.md`
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

Two flows: **create-new** and **extend-existing** (Res #16).

### 3.1 Create a new `ext-{service}` (when no child exists yet)

1. **Catalog search.** Call the jentic MCP server to search for the
   endpoint(s) needed.
2. **Missing-endpoint handling.** If a needed endpoint isn't in
   jentic, ask the user to add it via the jentic web app and wait
   **exactly one user turn** for confirmation (Res #6). If no
   confirmation arrives, stop; user re-invokes when ready.
3. **Endpoint-coverage prompt.** Ask the user: "Are there other
   endpoints on this service this `ext-{service}` skill should
   cover while we're here? Would you like automated assistance
   discovering them?" Act on the answer.
4. **Test-plan negotiation.** Produce a draft live-fire test plan —
   one entry per intended endpoint, with cost / side effects / resource
   impact for each. Recommend a full live test of every endpoint to
   be exposed. Ask the user to approve, modify, or veto each entry
   (free-form during negotiation). After approval the plan lands as
   a structured list in the child skill's "Test plan record" section
   (§5 item 4): one line per endpoint with status `approved` or
   `vetoed (reason)`.
5. **Live-fire execution.** Run the approved test plan. Each call is
   one-shot — no retries (Res #2). On failure, stop and escalate.
   If the user vetoed any endpoint during negotiation, the meta-skill
   does not silently skip it: stop the authoring procedure and ask
   for explicit direction — skip the endpoint, ship with an
   unverified recording (and a `verified: false` note in the child
   SKILL.md), or abandon (Res #22).
6. **Record verified shapes.** For each successful probe, write
   `resources/<endpoint>.json` in the child skill's tree, conforming
   to the schema in `external-api-bridge/resources/README.md`
   (Res #15).
7. **Author the child skill** using `resources/TEMPLATE.md` and
   complete the pre-commit checklist.
8. **Done.** No automatic registration in `CLAUDE.md` /
   `ai/testing-guidelines.md` (Res #5).

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

- **Retries (Res #2).** Every jentic call from any `ext-*` skill is
  one-shot. On failure, escalate.
- **CI re-dispatch after a fix (Res #10).** After diagnosing a CI
  failure and applying a fix, the agent may auto-re-dispatch once
  if `terraform-ci-watch`'s failure-taxonomy classifies the failure
  as transient (network, AWS throttling, runner allocation, jentic
  5xx). Logic failures hand off. The outer 3-strike envelope from
  `terraform-ci-watch` is respected.
- **Concurrency (Res #3 + #14).** `terraform-test.yml` has
  `cancel-in-progress: false` so dispatches queue. Before
  dispatching, `ext-github` lists queued/in-progress runs for the
  same `(ref, phase)`. If more than two are already queued, the
  skill **refuses the dispatch and reports verbatim** to the user
  ("N runs already queued for {ref, phase}; please intervene").
  No automatic non-destructive diagnosis (Res #14 superseded the
  earlier diagnosis attempt).
- **No drift detection (Res #13).** Recorded shapes in
  `resources/<endpoint>.json` document the verified request
  contract. The agent does not compare live response shapes
  against a recorded shape; runtime failures are handled as
  ordinary failures.
- **Discoverability (Res #5).** Aggressive `description:` frontmatter
  on every skill. No `CLAUDE.md` / `INDEX.md` / SessionStart-hook
  plumbing.
- **Wait state (Res #6).** One-turn timeout on the meta-skill's
  wait-for-user-to-add-API step.
- **Mandatory sections (Res #7).** TEMPLATE.md headings + pre-commit
  checklist; enforcement is procedural inside the meta-skill.
- **Scope creep (Res #8).** Accepted. Boundary between MCP and
  `ext-*` coverage depends on host policy.
- **Jentic outage (Res #9).** When an `ext-github` call fails for
  connectivity reasons, the agent writes the intended next
  dispatch to `ai/handoff.md`, commits, and stops. Human resumes
  via Actions UI.
- **Sandbox budget (Res #11).** Fire-and-forget.
- **Main-branch dispatch (Res #12).** No skill-level restriction;
  rely on repo branch protections.

---

## 5. TEMPLATE.md required sections

Each `ext-{service}` child must include:

1. **Frontmatter** — aggressive `description:`, trigger phrases,
   `allowed-tools` list.
2. **When to use** — the specific gap this skill fills.
3. **Endpoints** — table of `{purpose, endpoint,
   resources/<endpoint>.json}`. (No `action-class` field — Res #19
   dropped it as vestigial.)
4. **Test plan record** — the approved live-fire plan from the
   authoring session(s), including vetoed entries with their reason.
   Updated when the extend sub-procedure adds new endpoints.
5. **Retry policy** — one-shot per call (cross-cutting, restated).
6. **Concurrency precondition** — for endpoints that trigger queued
   work, the >2-queued refuse-and-report rule.
7. **Recorded request shape** — pointer to `resources/<endpoint>.json`
   for each endpoint. (No drift-detection escalation — Res #13.)
8. **Recovery on jentic outage** — pointer to the handoff-fallback
   in `ai/testing-guidelines.md`.
9. **Pre-commit checklist** — one box per section above plus
   "shapes in `resources/<endpoint>.json` conform to the schema in
   `external-api-bridge/resources/README.md`."

---

## 6. `resources/README.md` schema (Res #15)

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

### `*_inputs_schema` per-key shape (Res #20)

Each entry in `body_inputs_schema` or `query_inputs_schema` uses this
fixed shape:

| Key       | Type          | Required? | Meaning |
|-----------|---------------|-----------|---------|
| `required`| bool          | yes       | Whether the input must be supplied at call time. |
| `values`  | array of literals | no    | Enumerated allowed values. Omit when the value space is unbounded (e.g. `ref`). |
| `default` | literal       | no        | Value to substitute when the key is absent at call time (only meaningful when `required: false`). |

Examples in the README cover three shapes: enumerated
(`action: { required: true, values: [...] }`), free-form
(`ref: { required: true }`), defaulted
(`per_page: { required: false, default: 30 }`).

### Notes on the recording

- `endpoint_ref` is **optional** (Res #18); populated when jentic
  returns a stable identifier, omitted otherwise.
- `recorded_at` is informational (drift detection was dropped — Res
  #13); audit only.
- `response.status` only — no response body schema (Res #13).
- `request.body` / `request.query` are the verified working values
  from the live-fire test — concrete examples.
- `request.body_inputs_schema` / `request.query_inputs_schema` list
  which keys are call-time inputs vs fixed. Keys in `body` / `query`
  not listed in the corresponding schema are fixed and reused as-is
  (Res #17, Res #21).
- POST endpoints typically use `body` + `body_inputs_schema`; GET
  endpoints typically use `query` + `query_inputs_schema`. Either
  pair may be omitted when the method doesn't carry that section.
- `headers` are recorded literally; auth headers are NOT recorded —
  jentic supplies them at call time.
- `url_template` uses `{owner}`, `{repo}`, etc. as path placeholders.

The README also includes one fully-worked example
(`workflow_dispatch`) so child authors have a concrete model. (The
worked example is populated from PR2's probe output and lands as a
follow-up commit to PR1 if PR1 ships first with a placeholder.)

---

## 7. Out of scope

Not part of PR1 or PR2:

- File-commit-based CI triggers and any fallback to them.
- Drift detection (Res #13).
- Non-destructive queue diagnosis (Res #14).
- `CLAUDE.md` / `INDEX.md` / SessionStart-hook discoverability
  plumbing (Res #5).
- CI lint of `ext-*` skill structure (Res #7).
- Forbidden-surface list / per-endpoint file split / skill rename
  for scope-creep prevention (Res #8).
- Sandbox-budget gating (Res #11).
- `ref=main` protection at the skill level (Res #12).
- Persistence of meta-skill wait state (Res #6).

---

## 8. PR ordering and gating

1. PR1 lands first: meta-skill + workflow edit.
2. Discovery probe (catalog search only) confirms GitHub's
   `workflow_dispatch` endpoint is reachable via jentic.
3. PR2 lands after the probe and after the user-approved live-fire
   test plan has executed successfully and shapes are recorded.
