# ADR: Every Upbound child provider runs under one shared IRSA ServiceAccount via runtimeConfigRef

- **ID**: ADR-56cbfe6440
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-07
- **Source retrospective**: ../2026-06-07-162.md
- **PRs covered**: #162

## Context

In the Upbound `provider-family-aws` v2 model each child provider
(eks/iam/acm/route53/secretsmanager/rds) runs its **own** controller pod under its
**own** ServiceAccount. The management terraform created an IRSA-annotated
`DeploymentRuntimeConfig` (`aws-provider-config`, SA `upbound-provider-family-aws`,
role `<cluster>-crossplane`) but referenced it **only** from the family Provider.
The crossplane IRSA role trust is a `StringEquals` on exactly
`system:serviceaccount:crossplane-system:upbound-provider-family-aws`. Result
(auto-011 blocker #3, proven live): child pods got default un-annotated SAs, had no
`AWS_WEB_IDENTITY_TOKEN_FILE`, and every composed managed resource stalled
`Synced=False: token file name cannot be empty` with zero AWS API calls — the
platform-cluster XR composed 11 MRs but provisioned nothing.

## Decision

Every child AWS provider sets `spec.runtimeConfigRef` to the shared
`aws-provider-config` DeploymentRuntimeConfig, so all provider pods run under the
single IRSA-annotated ServiceAccount `upbound-provider-family-aws` that the
crossplane role trust admits. The role trust stays a narrow `StringEquals` on that
one subject (no wildcard).

## Alternatives considered

- **Per-child annotated SA + wildcard trust (Option B).** Give each child its own
  auto-named SA carrying the role-arn annotation and broaden the role trust to
  `StringLike system:serviceaccount:crossplane-system:provider-aws-*`. Rejected as
  the default because it broadens the trust of a highly-privileged role; kept as the
  documented fallback if Crossplane churned on the shared pinned SA (it did not).
- **Leave it manual / per-session.** Rejected — the cluster is rebuilt periodically
  and a manual step is absent on every rebuild (the same failure class as the
  missing ClusterProviderConfig).

## Consequences

- Easier: one IRSA role, one trusted subject, minimal trust surface; a rebuilt
  cluster reaches a working provider plane with no manual step. Confirmed live: the
  eks pod has the token, the XR is `Synced=True`, EKS provisioned.
- Harder: all child provider Deployments share one ServiceAccount (unusual); if
  Crossplane ever changes SA ownership semantics this could churn — watch for it.
  A body sentinel on the providers' `triggers_replace` is required so the manifest
  edit actually re-applies.
- Trade-off accepted: provider-bootstrap changes now go through terraform + a
  management apply rather than a one-off kubectl.

## References

- [`../2026-06-07-162.md`](../2026-06-07-162.md) — the source retrospective.
- [`../../decisions/auto-011-child-provider-irsa.md`](../../decisions/auto-011-child-provider-irsa.md) — the live diagnosis + both options + validation.
- [`../2026-06-06-162/ADR-f52e8eeb51-declarative-provider-bootstrap.md`](../2026-06-06-162/ADR-f52e8eeb51-declarative-provider-bootstrap.md) — the parent "deliver provider bootstrap declaratively" ADR this refines.
- PR #162 (commit `f737e03`).
