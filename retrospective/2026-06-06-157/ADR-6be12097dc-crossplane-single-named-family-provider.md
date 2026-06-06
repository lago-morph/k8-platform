# ADR: Crossplane v2 explicit family Provider must carry the dependency-derived name

- **ID**: ADR-6be12097dc
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-06
- **Source retrospective**: ../2026-06-06-157.md
- **PRs covered**: #156

## Context

In Crossplane v2, an AWS child provider (`provider-aws-eks`, `-iam`, `-acm`, `-route53`) auto-creates its family-dependency `Provider` object with a name **deterministically derived from the package's own `metadata.name`** — `upbound-provider-family-aws`. The management cluster also declared an *explicit* family Provider, but under a different name (`provider-family-aws`). The result was two `Provider` objects claiming ownership of the one family package. The package-manager could not build the dependency DAG — the crossplane Lock surfaced `cannot build DAG: node xpkg.upbound.io/upbound/provider-family-aws already exists` (captured live on run 27055996205 while diagnosing `OI-2026-06-06-2`). With no resolvable DAG there were no provider runtimes, hence no Deployment, hence no ServiceAccount; the IRSA-pinned `serviceaccount/upbound-provider-family-aws` never appeared and every managed resource stalled.

This was not a one-off: the same provider-bootstrap deadlock blocked the auto-005 and auto-007 runs. It is a binding structural choice about how the platform declares its provider family — a re-occurring, multi-file architectural call, not a tactical edit — so it warrants a recorded decision. The partial OI-2026-06-05-3/4 fixes addressed symptoms but not the duplicate-name root cause.

## Decision

Declare the explicit AWS family Provider under the dependency-derived name `upbound-provider-family-aws`, order it before its children with `depends_on`, add an idempotent orphan-cleanup of any differently-named family Provider, and assert exactly one Provider owns the package.

Concretely, the management-cluster crossplane bootstrap must:

1. Name the explicit family Provider exactly `upbound-provider-family-aws` so the child providers de-duplicate onto it instead of spawning a second owner.
2. Add `depends_on` so the family Provider is applied and Healthy before the children, eliminating the create race.
3. Run an idempotent orphan-cleanup (`kubectl delete provider provider-family-aws --ignore-not-found`) so a cluster already wedged by the old name self-heals in place — no `terraform destroy` required.
4. Assert that exactly **one** Provider owns the family package, so a re-introduced duplicate fails loud rather than silently re-wedging the DAG.

Validated live: run 27056287208 (validation-2) passed green — EKS ACTIVE, all crossplane providers Healthy, the pinned `serviceaccount/upbound-provider-family-aws` present, the one-Provider assertion satisfied, ArgoCD UI HTTP 200.

## Alternatives considered

- **Delete the explicit family Provider entirely and let the children auto-create it.** Rejected: the explicit Provider is where the IRSA `runtimeConfigRef` / pinning is anchored; dropping it would surrender control of the family's runtime configuration and ServiceAccount pinning to whatever the children derive by default.
- **Retarget to the derived name but rely only on apply ordering / wait, without orphan-cleanup.** Rejected: `kubectl apply` does not prune, so a cluster already wedged with the stray old `provider-family-aws` keeps the duplicate alive and stays deadlocked. Validation-1 (run 27055996205) failed for exactly this reason — the rename was correct but the orphaned old Provider lingered. The fix needs an explicit idempotent delete of the orphan to self-heal a wedged cluster without a destructive rebuild.

## Consequences

- Provider bootstrap becomes deterministic and self-healing: a fresh cluster and a previously-wedged cluster both converge to a single family Provider, ending the recurring deadlock that blocked auto-005/auto-007.
- A re-introduced duplicate now fails loud via the one-Provider assertion instead of silently breaking the DAG, so the failure is caught at bootstrap rather than discovered hours later through stalled managed resources.
- The bootstrap carries extra moving parts — a `depends_on` edge, an orphan-cleanup delete, and an assertion — which must be kept aligned with the chainsaw harness's Provider names (a reviewer flagged this name-alignment). The accepted trade-off is slightly more bootstrap logic in exchange for in-place recoverability and no destroy.

## References

- [`../2026-06-06-157.md`](../2026-06-06-157.md) — the source retrospective (lesson L5).
- Source open issue: `OI-2026-06-06-2` (provider-SA bootstrap deadlock), closed by this decision.
- Supersedes the partial `OI-2026-06-05-3` / `OI-2026-06-05-4` fixes.
- Live evidence: crossplane Lock condition `cannot build DAG ... already exists` (run 27055996205); validation-2 green (run 27056287208).
- PR the decision was made in: #156.
