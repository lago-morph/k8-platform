# ADR: Crossplane provider bootstrap is delivered declaratively, not as manual kubectl steps

- **ID**: ADR-f52e8eeb51
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-06
- **Source retrospective**: ../2026-06-06-162.md
- **PRs covered**: #161, #162

## Context

Two of the three phase-3 blockers in auto-011 were *missing provider-bootstrap
state* on a rebuilt management cluster: (1) the shared
`ClusterProviderConfig/default` that every composition references was a manual
`kubectl apply` documented in a plan (`SEG-1 §0c`) and was simply absent; (2) the
child AWS providers had no IRSA `runtimeConfigRef`, so their pods couldn't assume
the crossplane role. In both cases the symptom was identical and silent: managed
resources stalled `Synced=False` with no AWS API calls, invisible until a CI
kube-diagnose dumped the MR conditions (~30 min of diagnosis each). Because the
account/cluster is periodically rebuilt, any bootstrap step that isn't in
terraform or GitOps is guaranteed to be missing on the next rebuild.

## Decision

All Crossplane provider-bootstrap state — the shared `ClusterProviderConfig`, every
provider's IRSA runtime configuration (DeploymentRuntimeConfig + `runtimeConfigRef`),
and the IRSA role trust — is delivered declaratively (terraform for provider
install/runtime + IRSA; GitOps `crossplane-resources` for the ClusterProviderConfig)
and is covered by a startup assertion. No provider-bootstrap step lives only in a
plan/runbook as a manual `kubectl apply`.

## Alternatives considered

- **Keep manual bootstrap steps in runbooks.** Rejected: proven to vanish on every
  rebuild and to fail silently (no AWS error, just non-reconciling MRs).
- **Single family controller for all services (no child runtime configs).** Not how
  this install behaves — the diagnose showed each child provider runs its own pod
  under its own SA, so per-child IRSA wiring is required regardless.
- **Broaden the crossplane role trust to a wildcard SA subject** (so any auto-named
  provider SA can assume it). Viable (decision-note Option B) but broadens the
  trust of a highly-privileged role; the narrow shared-SA approach (Option A) is
  preferred unless Crossplane churns on the shared SA.

## Consequences

- Easier: a fresh account rebuild reaches a working provider plane with no manual
  steps; the failure mode (silent non-reconciliation) is designed out.
- Harder: provider-bootstrap changes now go through terraform + a management apply
  (slower than a one-off kubectl), and the IRSA trust posture must be a conscious,
  reviewed choice (Option A vs B in the decision note).
- A startup/verify assertion (ClusterProviderConfig present; a child provider pod
  has `AWS_WEB_IDENTITY_TOKEN_FILE`) is added so the next regression is caught at
  apply time, not 30 minutes into a live diagnosis.

## References

- [`../2026-06-06-162.md`](../2026-06-06-162.md) — the source retrospective.
- [`../../decisions/auto-011-child-provider-irsa.md`](../../decisions/auto-011-child-provider-irsa.md) — blocker #3 fix options.
- [`./SKILL-SPEC-5b122d19e1-live-kube-read-via-argocd-and-ci.md`](./SKILL-SPEC-5b122d19e1-live-kube-read-via-argocd-and-ci.md) — how the blockers were diagnosed.
- PRs: #161 (ClusterProviderConfig via GitOps), #162 (XSpokeAccess + provider-kubernetes/envconfig terraform).
