# ADR: XR-level connection secrets removed from v2

- **ID**: ADR-80191c7707
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-26
- **Source retrospective**: ../2026-05-26-106.md
- **PRs covered**: #104 (Wave 2 cutover), #105 (hotfix)

## Context

The Crossplane v1 platform-cluster XRD published a connection-secret pattern: the XRD declared `connectionSecretKeys: [kubeconfig, endpoint, cluster-ca]`, the Composition declared `writeConnectionSecretsToNamespace: crossplane-system`, and the live XR/claim set `writeConnectionSecretToRef.name`. Phase 3 consumers (the workload-services ApplicationSet) read kubeconfig from the resulting Kubernetes Secret.

During the 2026-05-26 v1→v2 migration, the SEG-1 plan tentatively renamed `connectionSecretKeys` → `connectionDetails` per the Crossplane v2 upgrade guide. The SEG-1 subagent verified against the regenerated kubeconform schema (`compositeresourcedefinition_v2.json`) and concluded that v2 actually KEEPS `connectionSecretKeys` — the field exists in the v2 CRD for back-compat. Plan §3 Open Q-3 had anticipated exactly this divergence and instructed "verify after XRD apply"; the subagent dismissed the open question because kubeconform was green.

Wave 2 PR #104 merged. The post-merge `chainsaw.yml` full-set dispatch (run 26439096757) failed at the first scenario with:

```
CompositeResourceDefinition.apiextensions.crossplane.io "xplatformclusters.platform.k8-platform.io"
is invalid: spec: Invalid value: "object": XR connection secrets aren't supported in
apiextensions.crossplane.io/v2
```

The kubeconform schema accepts the field; the v2 admission webhook explicitly rejects it via a handler that the schema can't express. v2 removes XR-level connection secrets entirely (not just renames the field).

## Decision

Connection-secret routing through XR-level fields is REMOVED in Crossplane v2; consumers must read connection secrets directly from the producing MR (e.g., the EKS Cluster MR's own `writeConnectionSecretToRef`) rather than from an XR-aggregated secret. The platform-cluster XRD no longer declares `connectionSecretKeys`, and neither the live XR (`clusters/platform/platform-cluster-claim.yaml`) nor example claims set `writeConnectionSecretToRef`.

## Alternatives considered

- **Rename to `connectionDetails`** (the plan's tentative direction). Rejected: the v2 XRD schema actually doesn't accept `connectionDetails` either; the field name and the rejection are independent. Whatever we renamed to, the v2 admission webhook would reject.
- **Keep `connectionSecretKeys` because kubeconform accepts it**. Rejected: the failure surfaced at `chainsaw xrd-establishes`. Kubeconform schema-pass is necessary but not sufficient (see ADR-c7f74e2fb6).
- **Re-introduce the field via an annotation or CRD patch**. Rejected: v2's design removes XR-level connection secrets deliberately; working around the admission handler would diverge from upstream guidance and break on every Crossplane upgrade.

## Consequences

- **Easier**: XRDs and Compositions are simpler — no XR-level aggregation step.
- **Harder**: Phase 3 ApplicationSet must repoint its kubeconfig source from `platform/platform-cluster-kubeconfig` (the old XR-level secret) to the EKS Cluster MR's own connection-secret. The MR's secret name is now Composition-determined rather than XR-determined; consumers need a way to discover it. Tracked as a Phase 3 follow-up in `run-summary-2026-05-26.md` §"What's next".
- **Trade-off accepted**: deferred kubeconfig-routing redesign to Phase 3. Wave 2 ships without a working consumer-side kubeconfig path; the management cluster's chainsaw + IRSA tests still pass because they don't depend on the XR-level secret.

## References

- [`../2026-05-26-106.md`](../2026-05-26-106.md) — the source retrospective.
- [`./SKILL-SPEC-ac65496714-kubeconform-vs-admission-check.md`](./SKILL-SPEC-ac65496714-kubeconform-vs-admission-check.md) — the skill that would have prevented this if dispatched before merging #104.
- PR #104 (Wave 2 cutover, merged 2026-05-26) — introduced the `connectionSecretKeys` keep decision.
- PR #105 (Wave 2 hotfix, open at retro time) — reverts that decision and removes the XR-level fields.
- `ai/crossplane-v1-v2-un-fuckify/20-plan-SEG-1-production-manifests.md` §3 Q-3 — the plan's anticipated open question that turned out to be the load-bearing risk.
- Chainsaw run https://github.com/lago-morph/k8-platform/actions/runs/26439096757 — the failure that surfaced the issue.
