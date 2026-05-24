# ADR: Read-only diagnose-first before any mutating apply-and-verify on the live cluster

- **ID**: ADR-3dde47af42
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-24
- **Source retrospective**: ../2026-05-24-62.md
- **PRs covered**: #52, #61

## Context

This session dispatched `phase=management apply-and-verify` against an unfixed phase-2 state (policy 09 in the wrong directory). 15 minutes of CI burned before the failure surfaced. A 2-minute diagnose (or just `git log` to confirm PR #52 was in main) would have caught it. The handoff Step 0 #4 codifies this for the next session — verify PR #61 merged before dispatching Step 1.

## Decision

Before dispatching any mutating workflow whose runtime exceeds 5 minutes (apply-and-verify, teardown-rebuild, EKS provisioning), dispatch a read-only diagnostic first and quote its evidence in the announcement of the mutating dispatch.

## Alternatives considered

- **Just-try-it and read the failure log** — rejected because the cost asymmetry is 7-15x in favor of the diagnose.
- **Require pre-flight tests inside the mutating workflow itself** — rejected because the mutating workflow's pre-flight runs AFTER the workflow starts; the diagnose-first pattern runs in a separate cheap call.

## Consequences

**Easier:** prevent wasted long cycles; cheaper to iterate on fix-then-diagnose-again. **Harder:** one extra dispatch per mutating op. **Trade-off:** 2-3 extra minutes per mutating op vs 15+ minutes saved on the typical preventable failure.

## References

- [`../2026-05-24-62.md`](../2026-05-24-62.md) — the source retrospective.
- [`./SKILL-SPEC-3dd589f9a4-diagnose-before-mutate.md`](./SKILL-SPEC-3dd589f9a4-diagnose-before-mutate.md) — related skill spec.
- [`./SKILL-SPEC-19353a51dd-probe-then-diagnose-cluster-state.md`](./SKILL-SPEC-19353a51dd-probe-then-diagnose-cluster-state.md) — related skill spec.
- PRs the decision was made in: #52, #61.
