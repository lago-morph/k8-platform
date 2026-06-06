# Phase 4 / Phase 5 design decisions — chosen 2026-06-06

Durable record so these user-made decisions are not re-litigated or
dropped by a later session. Both were decided by the user (jonathan) on
2026-06-06.

## Phase 4 (observability) — hub Alloy AppProject: **Option A**

The Grafana Alloy agent runs on the **hub** (management cluster) and is a
**third-party chart**, which fits neither existing ArgoCD AppProject
(`k8-platform` allows the hub destination but forbids third-party charts;
`platform-spoke` allows the Grafana chart but forbids the hub
destination). See PR #147's parked
`argocd/apps/spoke/observability-alloy-mgmt.yaml.todo`.

**Decision: Option A — a new dedicated `hub-addons` AppProject.**
- `destination`: the hub in-cluster server (`https://kubernetes.default.svc`).
- `sourceRepos`: **exactly** this repo + the Grafana Helm chart repo
  (`https://grafana.github.io/helm-charts`) — no wildcards (CI-gated, same
  pattern as `platform-spoke`).
- Resource-kind whitelist scoped to Alloy's DaemonSet / RBAC / ConfigMap.
- Leaves the locked-down `k8-platform` project's "no third-party charts on
  the hub" intent fully intact; opens exactly one small, auditable door.

Rejected: (B) vendoring Alloy's rendered manifests into this repo under the
existing `k8-platform` project — heavier to maintain on chart bumps; and
(C) provider-helm Release — collapses the ArgoCD/Crossplane split.

When implementing: rename the `.todo` to `.yaml`, set `spec.project:
hub-addons`, add `argocd/projects/hub-addons.yaml`, and wire it into the
spoke/obs tests.

## Phase 5 (auth) — Keycloak database backend: **abstract via a general XRD, RDS for now**

**Decision: a general `XDatabase`-style XRD that abstracts the database
backend; RDS (via Crossplane) as the only implementation for now.**
- Keycloak consumes a database `Claim`/XR through the abstraction, not a
  hard-coded RDS reference.
- The first (and currently only) composition implementation provisions
  AWS RDS via the AWS provider.
- The abstraction leaves room for other backends later without re-wiring
  Keycloak.

Supersedes the "undecided DB backend" open question flagged on PR #148.
