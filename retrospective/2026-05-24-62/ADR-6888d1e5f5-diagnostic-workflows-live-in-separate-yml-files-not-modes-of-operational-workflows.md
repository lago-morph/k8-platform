# ADR: Diagnostic workflows live in separate .yml files, not modes of operational workflows

- **ID**: ADR-6888d1e5f5
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-24
- **Source retrospective**: ../2026-05-24-62.md
- **PRs covered**: #57, #58, #60

## Context

PRs #57 and #60 separated `integration-tests.yml` (mutating, runs assertions, can leak resources) from `phase-2-diagnose.yml` (read-only, prints state, does not mutate). PR #58 added `mode=teardown-phase-2 / verify-absent / rebuild` to integration-tests.yml because those are mutating like the original — same risk class. The diagnose workflow stays separate to keep its `permissions: contents: read` posture distinct and to make it cheap to re-dispatch without operator confusion about side-effects.

## Decision

Read-only diagnostic operations (e.g., `phase-2-diagnose.yml`) live in their own `.github/workflows/<purpose>.yml` files separate from mutating-operation workflows (e.g., `integration-tests.yml`); diagnostics are NOT added as new `mode=` inputs to mutating workflows.

## Alternatives considered

- **Single multi-mode workflow with all operations behind a `mode` input** — rejected because diagnostic + mutating mixing makes operator review of dispatch intent harder (any dispatch could be either category).
- **One file per operation, including separating each mode in #58** — rejected as too granular; lifecycle-related mutating modes legitimately share infrastructure (kubeconfig, AWS env setup).

## Consequences

**Easier:** dispatch a diagnose with zero risk; reason about workflow-level permissions; re-dispatch without re-confirming intent. **Harder:** two-file pattern for a system with both diag and mutating ops. **Trade-off:** small file-count increase for a clear risk-class boundary.

## References

- [`../2026-05-24-62.md`](../2026-05-24-62.md) — the source retrospective.
- [`./SKILL-SPEC-19353a51dd-probe-then-diagnose-cluster-state.md`](./SKILL-SPEC-19353a51dd-probe-then-diagnose-cluster-state.md) — related skill spec.
- [`./SKILL-SPEC-10ebf2a133-manual-dispatch-as-kubectl-bridge.md`](./SKILL-SPEC-10ebf2a133-manual-dispatch-as-kubectl-bridge.md) — related skill spec.
- PRs the decision was made in: #57, #58, #60.
