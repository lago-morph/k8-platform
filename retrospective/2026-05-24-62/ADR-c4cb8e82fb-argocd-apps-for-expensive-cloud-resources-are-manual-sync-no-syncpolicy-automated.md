# ADR: ArgoCD apps for expensive cloud resources are manual-sync (no syncPolicy.automated)

- **ID**: ADR-c4cb8e82fb
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-24
- **Source retrospective**: ../2026-05-24-62.md
- **PRs covered**: #55

## Context

PR #55 scaffolded `argocd/apps/platform-cluster-claim.yaml` for the phase-3 platform services cluster. The wrapped `PlatformCluster` claim triggers ~15 minutes of real EKS provisioning + node-group bootstrap. Auto-sync would mean any git push to the claim file (e.g., a typo fix) starts a new cluster provision. The session's `test_argocd_app_revision_pinned.sh` test was extended to recognize this pattern: an Application with `syncPolicy.automated: null` AND a documenting comment in the file header passes the lint.

## Decision

ArgoCD Applications that, when synced, provision real cloud resources costing real money or with long provisioning times (>5 min) must omit `syncPolicy.automated` entirely; sync is a deliberate operator action (UI click, `argocd app sync`, or `kubectl patch operation`).

## Alternatives considered

- **Auto-sync with a long readiness-check timeout** — rejected because the timeout doesn't change the fact that any git push triggers a provision.
- **Require manual gate via a separate ArgoCD project / RBAC restriction** — rejected as too heavyweight for the small number of expensive apps (today: just `platform-cluster-claim`; tomorrow: `workload1-cluster-claim` etc.).

## Consequences

**Easier:** safe to push changes to expensive-claim YAML files without unintended cluster work; reasoning about the cost of a sync action. **Harder:** operator forgets to sync after a legitimate intent-to-provision change. **Trade-off accepted:** explicit operator action for expensive resources.

## References

- [`../2026-05-24-62.md`](../2026-05-24-62.md) — the source retrospective.
- [`./SKILL-SPEC-10ebf2a133-manual-dispatch-as-kubectl-bridge.md`](./SKILL-SPEC-10ebf2a133-manual-dispatch-as-kubectl-bridge.md) — related skill spec.
- PRs the decision was made in: #55.
