# ADR: Direct-access sandbox supersedes the jentic bridge for cluster operations

- **ID**: ADR-667388a141
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-70.md
- **PRs covered**: #69 (handoff rewrite captured the capability shift), #70 (`integration-tests.yml` trim)

## Context

Through the late-2026-05-23 → late-2026-05-24 sessions, the agent sandbox lacked direct AWS / kubernetes / ArgoCD access. The workaround was the `jentic` MCP bridge: every AWS or GitHub Actions call became a tool invocation against jentic's pre-registered API recordings, and every cluster diagnostic required dispatching a workflow that ran `kubectl` inside GitHub Actions, polling for completion, then downloading and parsing the (often 75–170 KB) log.

This shaped several decisions:

- **`phase-2-diagnose.yml`** — exists primarily because the agent couldn't kubectl directly; the workflow is a kubectl proxy that emits its evidence as a log.
- **`integration-tests.yml`** — extended in PR #58 with `mode=teardown-phase-2 / verify-absent / rebuild` inputs precisely so the operator workflows could be driven from a bridge-only sandbox.
- **`ai/handoff.md`** "APIs you want" section listed `ext-aws`, `ext-argocd`, `ext-kubernetes` as future jentic recordings that would close the gap.
- Subagent log-extraction (see `SKILL-SPEC-8afdbefab5-subagent-log-extraction.md`) became a routine pattern because logs were the only evidence channel.

Late in the late-2026-05-24 session, the user upgraded the sandbox: AWS CLI admin on the test account, direct `kubectl` (via `aws eks update-kubeconfig`), unlimited outbound network. The bridge is no longer needed for cluster diagnostics.

The session captured this shift in two artifacts: the rewritten `ai/handoff.md` QUICKSTART (PR #69), and the workflow trim of `integration-tests.yml` (PR #70, which dropped the three operator modes and kept only `mode=test`). The PHASE-2-LIFECYCLE-PLAN.md doc was simultaneously upgraded with inline copy-pasteable runbook blocks so the operator can run the teardown/verify-absent/rebuild sequences directly without dispatching.

## Decision

When the agent's sandbox grants `aws` CLI + `kubectl` + unlimited egress, use them directly for cluster diagnostics, claim verification, and ad-hoc reads. Reserve `phase-2-diagnose.yml` (and any future dispatch-based diagnostic workflows) for capturing reproducible PR-time snapshots, not for the inner debug loop.

Concretely:

- **First action of every session**: `aws sts get-caller-identity`. If it succeeds, the sandbox is direct-access; act accordingly. If it fails, fall back to the bridge.
- **Diagnostic reads** (MR status, pod logs, ArgoCD app state) → direct `kubectl` / `aws` CLI / `curl` against ArgoCD's API. Do NOT author or dispatch a one-off workflow.
- **Reproducible snapshots** (evidence for a PR description, before-and-after diffs, audit trail for a debug session) → `phase-2-diagnose.yml` is still the right tool because its log is durable and citable.
- **Operator runbooks** (teardown, verify-absent, rebuild) → inline `kubectl` / `aws` commands in `ai/PHASE-2-LIFECYCLE-PLAN.md`. The workflow-dispatch wrapping is removed (PR #70).

## Alternatives considered

**(a) Keep the workflow-dispatch wrappers as a parallel path.** Rejected because two paths to the same operation means twice the maintenance — every change to teardown logic must be made in both places, and they will drift. The session demonstrated the cost: PR #70 removed the workflow modes because they were already obsolete the moment direct access landed.

**(b) Add `ext-aws` / `ext-argocd` / `ext-kubernetes` jentic recordings as universal fallbacks.** Worth doing for sandboxes that don't have direct access (older session config, restricted environments). But not the default path — direct access is faster, cheaper, and produces less log noise.

**(c) Treat the capability change as a per-session detail rather than an architectural decision.** Rejected because the choice between dispatch and direct affects how skills, runbooks, and handoffs are authored. Codifying the convention prevents future sessions from re-introducing the dispatch-only pattern when direct access is available.

## Consequences

**Easier:**

- Inner debug loop is faster (one kubectl call vs. one workflow dispatch + 3-minute poll + 170 KB log parse).
- Runbooks are copy-pasteable instead of being embedded inside a workflow YAML with `if: inputs.mode == 'X'` guards.
- The handoff doc no longer needs an "APIs you want" wish list — the requested APIs are already available.

**Harder:**

- Sessions that lose direct access must remember to fall back to the bridge. The first-action rule (`aws sts get-caller-identity`) makes the fallback explicit.
- Reproducibility now depends on the operator running the runbook correctly, vs. dispatching a workflow. Mitigated by keeping `phase-2-diagnose.yml` as the snapshot tool — it remains the durable, citable evidence channel for PRs.

**Accepted trade-off:**

- The `integration-tests.yml` workflow lost its operator surface area (PR #70). The lifecycle plan doc absorbed the surface. The reviewer who wants to see what the operator does opens the markdown, not the YAML.

## References

- [`../2026-05-25-70.md`](../2026-05-25-70.md) — source retrospective.
- [`./SKILL-SPEC-8afdbefab5-subagent-log-extraction.md`](./SKILL-SPEC-8afdbefab5-subagent-log-extraction.md) — the log-extraction skill that was *necessary* under bridge-only access and is *optional* under direct access.
- PR #69 — handoff rewrite that codified the capability shift.
- PR #70 — `integration-tests.yml` trim + lifecycle plan upgrade.
- `ai/PHASE-2-LIFECYCLE-PLAN.md` — the inlined runbook.
- `ai/handoff.md` NEW SESSION QUICKSTART → "Session capabilities you now have" — the operational guidance.
