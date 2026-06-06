# ADR: Spoke clusters receive add-ons via a dedicated platform-spoke AppProject and plain Applications

- **ID**: ADR-310f7e2fd3
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-05
- **Source retrospective**: ../2026-06-05-148.md
- **PRs covered**: #145, #146, #147, #148

## Context

The management (hub) cluster installs its add-ons (ingress-nginx, ExternalDNS)
via Terraform `helm_release`. Spoke clusters (the phase-3 platform cluster, the
phase-6 workload cluster) cannot use Terraform — REQ-NF-02 mandates GitOps after
the management bootstrap. So spoke add-ons must be delivered by the hub ArgoCD.
But the existing `k8-platform` AppProject is deliberately locked down:
`sourceRepos` is this-repo-only ("no third-party charts via Argo"), destinations
are the management cluster only, and the kind whitelist covers only XRDs / CSS /
ClusterPolicy / Namespace. Every spoke add-on is a third-party Helm chart
deployed to a non-management destination installing workload kinds (Deployment,
Service, Ingress, CRDs, cluster RBAC) — none of which the `k8-platform` project
permits. The session also had to decide how the account-ephemeral cross-cluster
values (cert ARN, root domain, spoke IRSA role ARN) reach the spoke without being
committed to git (AGENTS §8.1).

## Decision

Deliver spoke add-ons through a **dedicated `platform-spoke` ArgoCD AppProject**
(pinned exact chart `sourceRepos`, an enumerated workload-kind whitelist, and
spoke-by-name destinations) using **plain per-service Applications** for phase 3,
with the account-ephemeral values overlaid at registration time — deferring an
ApplicationSet to phase 6 where multi-cluster fan-out first earns it.

## Alternatives considered

- **Broaden the `k8-platform` project** to allow chart repos + spoke destinations.
  Rejected: it would silently authorize third-party charts and cluster-admin-grade
  RBAC onto the hub too, dissolving the lockdown the project exists to enforce.
- **An ApplicationSet (cluster generator) from day one.** Rejected for phase 3:
  with exactly one spoke it buys zero fan-out, adds goTemplate/multi-source
  indirection, and a bare cluster generator also targets the hub in-cluster
  destination (a real footgun a reviewer flagged). It becomes worthwhile at the
  phase-6 second cluster — and that refactor is itself a teaching artifact.
- **Vendor rendered manifests in-repo** (helm template → commit). Kept as the
  per-chart fallback if live ArgoCD egress to a chart CDN fails (the
  OI-2026-06-05-2 precedent), not adopted preemptively — it bloats the repo
  (kube-prometheus-stack alone is ~10k lines) and bakes in values.
- **Crossplane provider-helm Releases on the spoke.** Rejected: it collapses the
  two-tool pedagogical split (ArgoCD deploys apps, Crossplane provisions infra)
  the project is built around, and adds two providers for no capability ArgoCD
  lacks.

## Consequences

- Phases 4/5/6 reuse one pattern: a new chart repo appended to `platform-spoke`
  `sourceRepos`, one Application per service, in-git static values, ephemeral
  values overlaid at registration. Low marginal cost per service.
- The hub ArgoCD application-controller must be mapped to cluster-admin on the
  spoke (it applies arbitrary add-on RBAC); the AppProject's pinned sourceRepos +
  kind whitelist + a Kyverno cluster-admin-CRB guard become the real blast-radius
  controls, which must be kept tight (CI-gated no-wildcard test).
- Hub-targeted add-ons (the phase-4 Alloy agent) fit neither project and need a
  third `hub-addons` project — an open follow-up surfaced by this decision.
- The phase-3→6 progression gains a natural "plain Apps → ApplicationSet" refactor
  story.

## References

- [`../2026-06-05-148.md`](../2026-06-05-148.md) — the source retrospective.
- [`../../decisions/auto-008-spoke-gitops-delivery.md`](../../decisions/auto-008-spoke-gitops-delivery.md) — the 2-round / 5-reviewer decision brief.
- [`../../decisions/auto-009-phase3-live-completion-runbook.md`](../../decisions/auto-009-phase3-live-completion-runbook.md) — the live-coupled half.
- PRs: #145 (foundation), #146 (phase 6), #147 (phase 4), #148 (phase 5).
