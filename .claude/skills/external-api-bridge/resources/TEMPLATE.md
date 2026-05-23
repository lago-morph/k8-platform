# `ext-{service}` Child Skill Template

This is the canonical scaffold for every `ext-{service}` child skill
created via `external-api-bridge`. Copy this file into the new
skill's directory (`.claude/skills/ext-{service}/SKILL.md`) and fill
in every section. The pre-commit checklist at the bottom must be
fully ticked before the skill is committed.

The canonical design is `ai/specs/ext-github-design.md`. If anything
in this template appears to disagree with that spec, the spec wins —
update the template, not the skill.

---

## Required frontmatter

```yaml
---
name: ext-{service}
description: >-
  <Aggressive, trigger-phrase-rich description. Name every operation
  the skill covers. Spell out the specific gap (sandbox-blocked,
  no-MCP-coverage, MCP-tool-broken). Include the verbs a future
  agent will use to search ("dispatch", "trigger", "list runs",
  etc.). Be longer than feels comfortable — a fresh session won't
  find this skill if the description is generic.>
allowed-tools:
  - Read
  - Bash
  - mcp__<jentic-uuid>__search_apis
  - mcp__<jentic-uuid>__load_execution_info
  - mcp__<jentic-uuid>__execute
  - <any other tools this skill actually invokes>
---
```

The `description:` field is the **only** discoverability mechanism
this skill has (per the canonical design's Resolution #5). Be
generous.

---

## Required sections

The child SKILL.md body must include these sections, in this order.

### 1. When to use

State the specific gap this skill fills. One paragraph. Name the
service. State which of the three trigger conditions applies (egress
blocked / no MCP tool / MCP tool exists but broken). Reference any
companion skills (e.g. `terraform-ci-watch`).

### 2. Endpoints

A table listing every endpoint this skill wraps:

| Purpose | Endpoint | resources/ file |
|---|---|---|
| <one-line purpose> | `METHOD /path/to/endpoint` | `<endpoint>.json` |

One row per endpoint. The `resources/` file column points at the
recorded shape in this skill's own `resources/` directory. (Schema:
`external-api-bridge/resources/README.md`.)

### 3. Test plan record

The approved live-fire test plan from the authoring session(s).
Updated when the extend sub-procedure adds new endpoints.

Format: one line per endpoint, status either `approved` or
`vetoed (reason)`. If `vetoed`, the endpoint either ships with a
`verified: false` note (see §5) or is excluded from the skill
entirely — say which.

Example:

```
workflow_dispatch       — approved (live-fired 2026-05-23, ref=branch/foo)
list workflow runs      — approved (live-fired 2026-05-23)
get a specific run      — approved (live-fired 2026-05-23)
get run logs on failure — approved (live-fired 2026-05-23)
```

### 4. Retry policy

One-shot per call. No automatic retries inside the skill. On
failure, escalate to the user. (This rule is cross-cutting — restate
it here for the future reader.)

### 5. Concurrency precondition

For any endpoint that **triggers queued work** (e.g.
`workflow_dispatch`): before dispatching, list queued/in-progress
items for the same identity tuple (for `ext-github` that's
`(ref, phase)`). If more than two are already queued, **refuse the
dispatch** and report verbatim to the user:

> "N runs already queued for {identity}; please intervene."

No automatic diagnosis. No retry. User unblocks before the skill
proceeds.

For endpoints that don't trigger queued work (pure reads, etc.) this
section may say "N/A — read-only endpoint."

### 6. Recorded request shape

For each endpoint, a pointer to its `resources/<endpoint>.json`
file. State plainly: "the recording is the source of truth for the
call shape; do not handcraft requests from documentation." If any
endpoint was vetoed during test-plan negotiation and ships with a
`verified: false` recording, flag that here explicitly:

> ⚠ `<endpoint>.json` has `verified: false` — the live-fire probe
> was vetoed. The recording is derived from documentation and has
> not been confirmed against the live API. Surface this every time
> this endpoint is invoked.

### 7. Recovery on jentic outage

When a call from this skill fails for connectivity reasons (jentic
5xx, rate limit, unreachable), the agent must write the intended
next action (with enough context for a human to resume) to
`ai/handoff.md`, commit, and stop. See the documented fallback in
`ai/testing-guidelines.md` (section added by the first `ext-*`
skill that needed it).

---

## Pre-commit checklist

The agent authoring this skill must tick every box before
committing. Verifying the checklist is the meta-skill's enforcement
mechanism for Resolution #7 — do not skip.

- [ ] Frontmatter `description:` is aggressive, names every endpoint
      this skill covers, and includes trigger phrases a future agent
      would search for.
- [ ] §1 When to use — names the specific gap (egress / no-MCP /
      MCP-broken) and the upstream service.
- [ ] §2 Endpoints — every endpoint has a row, every row points at a
      `resources/<endpoint>.json` file that exists.
- [ ] §3 Test plan record — every endpoint appears with status
      `approved` or `vetoed (reason)`. Vetoed entries are explicit
      about whether the skill ships partial or omits the endpoint.
- [ ] §4 Retry policy — one-shot, no retries, restated.
- [ ] §5 Concurrency precondition — set for queuing endpoints;
      explicit "N/A — read-only" for the rest.
- [ ] §6 Recorded request shape — pointer per endpoint, with the
      `verified: false` warning surfaced if any apply.
- [ ] §7 Recovery on jentic outage — present and pointing at the
      handoff-fallback documentation.
- [ ] Every `resources/<endpoint>.json` file conforms to the schema
      in `external-api-bridge/resources/README.md` (required keys,
      `*_inputs_schema` sub-shape, etc.).
- [ ] The skill's `description:` plus its body name no operations
      this skill cannot actually perform — no aspirational scope.
