# Resolved Design — external-api-bridge + ext-github

**Status:** draft for fresh-eyes critique. Folds the §Resolutions from
`ai/specs/ext-github-design.md` into the design itself. The canonical
spec retains the original §Background / §Source material / §Open risks
sections for historical reference; this file is the agreed shape of
what gets built.

**Scope reminder.** Total dispatch volume over the project's lifetime
is expected to be 10–20 dispatches ever. The bridge only has to be
durable until platform implementation completes. Resist the urge to
engineer for scale, longevity, or edge cases that surface only at
high volume.

---

## 1. Skills

Two skills shipped in two PRs.

### PR1 — `external-api-bridge` (parent meta-skill)

A skill that **both** documents and **executes** the discovery /
test-plan / authoring procedure for creating a new `ext-{service}`
child skill. PR1 is not pure scaffolding; the SKILL.md and
`reference/procedure.md` encode runtime behaviour the future agent
follows when invoked.

Files (all under `.claude/skills/external-api-bridge/`):

- `SKILL.md` — frontmatter with aggressive `description:` and trigger
  phrases (Resolution #5); body covering when to use (three triggers,
  see §3), procedure summary, pointers to template and reference.
- `resources/TEMPLATE.md` — child-skill scaffold with mandatory
  headings + pre-commit checklist (Resolution #7).
- `resources/README.md` — explains where per-child captured probe
  outputs live.
- `reference/procedure.md` — long-form discovery / test-plan /
  authoring procedure.

Plus one bundled workflow edit (Resolution #3):

- `.github/workflows/terraform-test.yml` — set
  `cancel-in-progress: false` on the workflow-level `concurrency`
  block (or remove the line; both produce queueing behaviour).

### PR2 — `ext-github` (child skill)

Concrete child built using PR1's pattern. Wraps the specific GitHub
endpoints needed to drive the inner debug loop autonomously from
inside the sandbox.

**Endpoints in scope:**

| Purpose | Endpoint |
|---|---|
| Trigger a CI run | `POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches` |
| List recent runs (for concurrency check + run lookup) | `GET /repos/{owner}/{repo}/actions/runs` |
| Get a specific run | `GET /repos/{owner}/{repo}/actions/runs/{run_id}` |
| Get run logs on failure | `GET /repos/{owner}/{repo}/actions/runs/{run_id}/logs` |

The meta-skill's endpoint-coverage prompt (§3) gives the user a chance
to widen this set at PR2 authoring time if they see a gap.

Files (under `.claude/skills/ext-github/`):

- `SKILL.md` — frontmatter + body following `resources/TEMPLATE.md`.
- `resources/<endpoint>.json` — one file per endpoint, capturing the
  verified request shape from the approved live-fire test plan.
- Pre-commit checklist completed.

Plus one documentation paragraph (Resolution #9):

- `ai/testing-guidelines.md` — short fallback paragraph: when an
  `ext-github` call fails (jentic 5xx, rate-limited, unreachable),
  the agent writes the intended next dispatch to `ai/handoff.md`,
  commits, and stops. Human resumes via the Actions UI.

---

## 2. When to invoke the meta-skill (three triggers)

The agent reaches for `external-api-bridge` when:

1. Sandbox network policy blocks direct egress to an upstream API.
2. No MCP tool covers the desired operation.
3. An MCP tool advertises coverage for the operation but is not
   actually usable in the current sandbox (host policies vary; an
   advertised tool may be denied at call time).

If any of those is true and a relevant `ext-{service}` child skill
doesn't yet exist, the meta-skill drives the authoring procedure in
§3 to create one.

---

## 3. Meta-skill procedure (executed at runtime)

When invoked, the meta-skill walks the user through:

1. **Catalog search.** Call the jentic MCP server to search for the
   endpoint(s) the agent needs. Capture every relevant hit.
2. **Missing-endpoint handling.** If a needed endpoint is missing
   from jentic's catalog, ask the user to add it via the jentic web
   app, then wait **exactly one user turn** for confirmation
   (Resolution #6). If no confirmation arrives in that turn, stop;
   user re-invokes when ready.
3. **Endpoint-coverage prompt.** After identifying the endpoints the
   agent came for, ask the user: "Are there other endpoints on this
   service that this `ext-{service}` skill should also cover while
   we're here? Would you like automated assistance discovering them?"
   Act on the answer.
4. **Test-plan negotiation.** Produce a draft live-fire test plan —
   one entry per intended endpoint, with the cost / side effects /
   resource impact of probing each one spelled out. Recommend a
   full live test of every endpoint to be exposed and explicitly cite
   the schema-vs-runtime mismatch risk (Resolution #4). Ask the user
   to approve, modify, or veto each entry. Record the approved plan.
5. **Live-fire execution.** Run the approved test plan. Each call is
   one-shot — no automatic retries (Resolution #2). On failure, stop
   and escalate to the user.
6. **Record verified shapes.** For each successful probe, capture the
   exact request shape — ref, full inputs map, content-type, request
   body — and the response shape into the child skill's
   `resources/<endpoint>.json`.
7. **Author the child skill** using `resources/TEMPLATE.md`.
   Complete the pre-commit checklist.
8. **Done.** No automatic CLAUDE.md / testing-guidelines.md pointer
   registration (Resolution #5 — rely on aggressive frontmatter on
   the child skill itself).

The procedure for *invoking* an already-authored `ext-{service}`
skill is described inside that skill, not here.

---

## 4. Cross-cutting policies (all resolutions folded in)

- **Retries (Resolution #2).** Every jentic call from any `ext-*`
  skill is one-shot. On failure, escalate to the user. No automatic
  retries inside the skill.
- **CI re-dispatch after a fix (Resolution #10).** Composes with the
  above. After the agent diagnoses a CI failure and applies a fix,
  the agent may auto-re-dispatch once if `terraform-ci-watch`'s
  failure-taxonomy classifies the failure as transient (network, AWS
  throttling, runner allocation, jentic 5xx). Logic failures
  (Terraform diagnostics, schema errors, drift) hand off to the user.
  The outer 3-strike envelope from `terraform-ci-watch` is respected.
- **Concurrency (Resolution #3).** `terraform-test.yml` has
  `cancel-in-progress: false` so dispatches queue rather than cancel
  each other. Before dispatching, `ext-github` lists queued/in-progress
  runs for the same `(ref, phase)`. If more than two are already
  queued, the agent attempts a non-destructive diagnosis of why the
  queue is stacking; if it cannot resolve non-destructively, it stops
  and asks the user.
- **Drift detection (Resolution #4).** Each `ext-*` child records the
  expected response shape per endpoint in
  `resources/<endpoint>.json`. On call, if the live response shape
  differs materially from the recorded shape, the agent notifies the
  user and asks what to do. No silent re-validation, no auto-fix.
- **Discoverability (Resolution #5).** Lean entirely on aggressive
  `description:` frontmatter on every skill (parent and children) —
  generous trigger phrases, named operations, concrete example
  contexts. No `CLAUDE.md` / `INDEX.md` / SessionStart-hook plumbing.
  If a future session demonstrably misses the skill, the user updates
  the frontmatter and proposes a template change.
- **Wait state (Resolution #6).** One-turn timeout when the meta-skill
  is waiting on the user to add a missing API to jentic. No
  persistence machinery.
- **Mandatory sections (Resolution #7).** `resources/TEMPLATE.md`
  ships with required headings + a pre-commit checklist. Enforcement
  is procedural inside the meta-skill: the agent verifies the
  checklist before declaring a child skill ready. No CI lint added.
- **Scope creep (Resolution #8).** Accepted. The boundary between
  MCP-tool coverage and `ext-*` coverage depends on the sandbox
  host's policy and may shift over time. Not enforceable at the skill
  level. Users manage scope per session as gaps shift.
- **Jentic outage (Resolution #9).** When an `ext-github` call fails
  for connectivity reasons (jentic 5xx, rate limit, unreachable), the
  agent writes the intended next dispatch (phase / action / ref) to
  `ai/handoff.md`, commits, and stops. Human picks up via Actions UI.
- **Sandbox budget (Resolution #11).** Fire-and-forget. The agent
  dispatches regardless of remaining sandbox time. If a run outlives
  the sandbox, the human collects results from the Actions UI.
- **Main-branch dispatch (Resolution #12).** No skill-level
  restriction on `ref=main` dispatches. Relies on repository branch
  protections / environment protection rules.

---

## 5. TEMPLATE.md required sections

Each `ext-{service}` child skill must include:

1. **Frontmatter** — aggressive `description:`, trigger phrases,
   allowed-tools list.
2. **When to use** — the specific gap this skill fills.
3. **Endpoints** — table of `{purpose, endpoint, action-class,
   resources/<endpoint>.json}`. Action class is `read-only` or
   `mutating` per endpoint; informs queue-depth check, drift
   detection, and re-dispatch policy.
4. **Test plan record** — the approved live-fire plan from the
   authoring session, including any vetoed entries with their reason.
5. **Retry policy** — one-shot per call (cross-cutting; restated for
   clarity).
6. **Concurrency precondition** — for endpoints that trigger work
   (e.g. `workflow_dispatch`), the queue-depth check from §4.
7. **Expected response shape** — pointer to `resources/<endpoint>.json`
   plus the drift-detection escalation rule (§4).
8. **Recovery on jentic outage** — pointer to the handoff-fallback
   in `ai/testing-guidelines.md`.
9. **Pre-commit checklist** — one box per section above plus
   "verified shapes committed to `resources/`."

---

## 6. Out of scope

Not part of PR1 or PR2:

- File-commit-based CI triggers (`.trigger-action.json`,
  `agent-trigger.yml`, `test/**` auto-triggers, etc.). Removed in
  PR #23; the bridge replaces them.
- Fallback paths to the above.
- `CLAUDE.md` / `INDEX.md` / SessionStart-hook discoverability
  plumbing (Resolution #5).
- CI lint of `ext-*` skill structure (Resolution #7 — convention via
  template + checklist).
- Forbidden-surface list / per-endpoint file split / skill rename
  for scope-creep prevention (Resolution #8).
- Sandbox-budget gating (Resolution #11).
- `ref=main` protection at the skill level (Resolution #12).
- Persistence of meta-skill wait state (Resolution #6).

---

## 7. PR ordering and gating

1. PR1 lands first. Contains the meta-skill, the workflow edit, and
   nothing else.
2. Before PR2 work starts, run the discovery probe (catalog search
   only, no live dispatch) to confirm GitHub's `workflow_dispatch`
   endpoint is reachable via jentic. If missing, the meta-skill's
   missing-endpoint flow applies.
3. PR2 lands after the probe confirms reachability and the live-fire
   test plan (§3 step 4) has been approved by the user.

---

## 8. Carry-forward from §Open risks

§Resolutions in the canonical spec covers all 12 original risks. This
draft assumes those resolutions are final. If §Critique (next step)
surfaces additional risks worth slotting in, they will be appended as
rows 13+ in §Resolutions and the user will be queried before this
draft is rewritten.
