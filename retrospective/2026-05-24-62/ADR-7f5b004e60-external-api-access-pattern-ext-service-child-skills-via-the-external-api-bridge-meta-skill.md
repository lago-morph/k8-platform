# ADR: External-API access pattern: ext-{service} child skills via the external-api-bridge meta-skill

- **ID**: ADR-7f5b004e60
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-24
- **Source retrospective**: ../2026-05-24-62.md
- **PRs covered**: (meta-pattern, no specific PR this session)

## Context

This session repeatedly authored one-off workflows just to read cluster state (`phase-2-diagnose.yml` is the largest example), because no direct kubectl/AWS/ArgoCD API was reachable from the sandbox. The handoff queued `ext-aws`, `ext-argocd`, and `ext-kubernetes` as planned bridges; the pattern is already proven via `ext-github` which this session used for every `workflow_dispatch`, run polling, and job-log fetch. Codifying the pattern means future agents reach for an ext-bridge before authoring a new workflow.

## Decision

External HTTP API access from the sandbox is routed through child skills under `.claude/skills/ext-{service}/` (e.g., `ext-github`, planned `ext-aws`, `ext-argocd`); the canonical procedure for adding a new bridge is the `external-api-bridge` meta-skill; the bridge transport is the jentic MCP server with credentials managed in jentic's web app (no tokens enter the repo or sandbox).

## Alternatives considered

- **Add direct sandbox network egress to AWS/ArgoCD APIs** — rejected because credential handling moves into the sandbox, and the sandbox is ephemeral; jentic's user-managed credentials are safer.
- **Use Kubernetes proxy via kubectl-via-workflow only** — rejected because every read requires a workflow dispatch + log fetch (10s+ each); ext-API call is sub-second.
- **Vendor a Go/Python SDK into the sandbox** — rejected as a per-cloud authoring burden; meta-skill pattern is generic.

## Consequences

**Easier:** direct verification per `verify-evidence-not-exit-codes` skill; fast iteration on diagnostics; clean separation of credentials. **Harder:** authoring a new ext-{service} bridge requires the user to add an API group in jentic (one-time setup per service). **Trade-off:** one-time per-service setup cost for fast, secure, in-session API access.

## References

- [`../2026-05-24-62.md`](../2026-05-24-62.md) — the source retrospective.
- [`./SKILL-SPEC-92c9f7a0af-verify-evidence-not-exit-codes.md`](./SKILL-SPEC-92c9f7a0af-verify-evidence-not-exit-codes.md) — related skill spec.
- [`./SKILL-SPEC-bbb1a32642-subagent-log-extraction.md`](./SKILL-SPEC-bbb1a32642-subagent-log-extraction.md) — related skill spec.
- PRs the decision was made in: (meta-pattern, no specific PR this session).
