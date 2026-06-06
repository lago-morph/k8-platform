# agent instruction

**Never let test fixtures sit in a GitOps-synced path.** "Keep render fixtures, example manifests, and test inputs out of any directory an ArgoCD Application (or other GitOps controller) syncs. An include glob is not enough — verify with an explicit exclude. Swept-in fixtures can duplicate resources (invalidating the whole sync) or be applied as real objects that provision cloud resources."

*Grounded in: 2026-06-06 — `crossplane/xrds/*/render-fixtures/{input,expected}.yaml` were swept into the crossplane-resources sync, duplicating render-probe XRs, so the XRDs never installed.*

# justification

The phase-3 provisioning was blocked at the last step by a repo bug, not the cluster: the `crossplane-resources` ArgoCD app synced `crossplane/` and pulled in the SPEC-S9 `render-fixtures/{input,expected}.yaml` — each of which contains the same `render-probe-*` XR — so every probe appeared twice. ArgoCD rejected the whole sync (`one or more synchronization tasks are not valid`), the XRDs never installed, and `platform-cluster-claim` then failed with "CRD not installed." Worse, had the duplication ever resolved, ArgoCD would have applied `render-probe-cluster` as a *real* `XPlatformCluster` and provisioned a throwaway EKS cluster. The existing `include: '{xrds/platform-*.yaml,…}'` glob was *intended* to keep fixtures out but didn't. The rule is cheap insurance: fixtures are test inputs, never live resources; put them outside the synced tree or pin an explicit `exclude`, and verify the app reaches `Synced` — the failure mode is otherwise invisible until a downstream app can't find its CRD.
