---
name: external-api-bridge
description: >-
  Reach an external HTTP API from a Claude Code sandbox when (a) direct
  network egress is blocked by sandbox policy, (b) no MCP tool covers the
  desired operation, or (c) an MCP tool advertises the operation but
  doesn't actually work in this sandbox. The bridge uses the jentic MCP
  server as an outbound broker — jentic calls the upstream API on the
  agent's behalf, with credentials managed by the user in jentic's web
  app (no tokens or secrets enter this repo or the sandbox). Use this
  skill to author a new ext-{service} child skill (e.g. ext-github,
  ext-aws) that wraps the specific endpoints needed, or to extend an
  existing ext-{service} with a new endpoint. Trigger phrases:
  "workflow_dispatch", "trigger CI", "jentic", "egress blocked",
  "MCP tool missing/broken", "create ext-github", "add a new endpoint
  to ext-github", "the sandbox can't reach X".
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - mcp__560280ab-3faa-4706-a23f-995ec2d5256f__search_apis
  - mcp__560280ab-3faa-4706-a23f-995ec2d5256f__load_execution_info
  - mcp__560280ab-3faa-4706-a23f-995ec2d5256f__execute
  - mcp__560280ab-3faa-4706-a23f-995ec2d5256f__list_credentials
---

# external-api-bridge

Meta-skill for building `ext-{service}` child skills that route HTTP
calls through the jentic MCP server when the sandbox can't (or won't)
make the call directly. The canonical design is
`ai/specs/ext-github-design.md` (§1–§8); this skill executes that
design.

## When to invoke

Reach for this skill when **any** of the following is true:

1. The sandbox network policy blocks direct egress to an upstream API.
2. No MCP tool covers the desired operation.
3. An MCP tool advertises coverage for the operation but is not
   actually usable in the current sandbox (host policies vary; an
   advertised tool may be denied at call time).

If a relevant `ext-{service}` skill already exists, you may be in the
**extend-existing** flow (adding a new endpoint to a known child).
Otherwise you're in the **create-new** flow.

## What this skill does NOT do

- Does not duplicate working MCP tools. If the GitHub MCP server
  exposes the operation you need and it actually works, use it.
- Does not call jentic from inside this skill at *invocation* time —
  the bridge happens via the *child* skill (`ext-{service}`) that this
  skill helps you author. The catalog search in step 1 of the
  procedure is the only jentic call this skill makes directly.
- Does not register the new child in `CLAUDE.md` or
  `ai/testing-guidelines.md`. Discoverability of `ext-*` skills relies
  on aggressive `description:` frontmatter on the child itself.

## Procedure

Two flows. The full step-by-step is in `reference/procedure.md`;
high-level summary follows.

### Create a new `ext-{service}`

1. **Catalog search** — `search_apis` on jentic for the endpoint(s)
   needed.
2. **Missing-endpoint handling** — if missing, ask the user to add
   the API group via the jentic web app; wait **exactly one user
   turn**. If no confirmation, stop.
3. **Endpoint-coverage prompt** — ask the user whether the new
   `ext-{service}` should cover other endpoints on this service while
   you're here.
4. **Test-plan negotiation** — produce a draft live-fire test plan,
   one entry per intended endpoint with cost/side-effects spelled
   out. User approves, modifies, or vetoes each entry.
5. **Live-fire execution** — run the approved plan. One shot per
   call, no retries. On any veto, stop and ask for direction.
6. **Record verified shapes** — write `resources/<endpoint>.json` in
   the child skill, conforming to the schema in
   `resources/README.md`.
7. **Author the child skill** from `resources/TEMPLATE.md`; complete
   the pre-commit checklist.

### Extend an existing `ext-{service}`

Same procedure but: skip the endpoint-coverage prompt (the user
already named what they want), and leave existing
`resources/<endpoint>.json` files alone unless the user explicitly
asks for re-verify of a specific one.

See `reference/procedure.md` for the complete walkthrough including
how to handle missing endpoints, vetoes, and live-fire failures.

## Files in this skill

- `resources/TEMPLATE.md` — the canonical scaffold every
  `ext-{service}` child must follow. Includes the pre-commit
  checklist.
- `resources/README.md` — strict JSON schema for the per-endpoint
  recordings (`<endpoint>.json`) that each child commits under its
  own `resources/`.
- `reference/procedure.md` — long-form procedure with the full
  step-by-step, including the extend-existing sub-procedure.

## Companion workflow setting

This skill assumes `.github/workflows/terraform-test.yml` has
`cancel-in-progress: false` on its `concurrency` block, so that
follow-up dispatches queue rather than cancel a running one. If you
find that line set to `true`, the safety the >2-queued refuse rule
provides is undermined — change it back to `false` and explain why
in the commit.
