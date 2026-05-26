# 30 — SEG-1 Review (Round 1, Reviewer B — correctness angle)

**Verdict:** REVISE-MAJOR

## What the plan does well

- Walks every break in the impact matrix (XRD claimNames removal, API-group rename, deletionPolicy, providerConfigRef kind, wConSTN, claimRef patches, render-fixture leak, ArgoCD app paths) and explicitly assigns each to a step.
- Correctly identifies the BLAST moment (claim CRDs deleted at XRD apply) and gates it behind a Step 3 drain.
- Catches the `claimRef.name/namespace` patches in `platform-secret.yaml` L121-131 and proposes the correct v2 rewrite (`metadata.name` / `metadata.namespace`).
- Catches that `recurse: true` + the include glob inadvertently slurps `xrds/*/render-fixtures/input.yaml`.
- Flags `function-patch-and-transform` input apiVersion, ClusterProviderConfig vs namespaced ProviderConfig, and Kyverno policy 09 as explicit open questions.

## Correctness flaws

1. **`apiextensions.crossplane.io/v1` is wrong for v2 namespaced XRDs.** Plan §2 Step 1: *"Keep `apiVersion: apiextensions.crossplane.io/v1` (Crossplane v2 still serves … the v2 surface adds `spec.scope`)"*. Upstream v2 introduces **`apiextensions.crossplane.io/v2`** for XRDs that support `spec.scope: Namespaced` (and removes `claimNames` from the v2 schema). `v1` is preserved for backwards compatibility but is the **cluster-scoped legacy shape**; mixing `v1` + `spec.scope: Namespaced` may be silently ignored or rejected. This needs verification against the live v2 XRD CRD on a 2.3 control plane — the plan asserts it as fact with no source.

2. **`connectionSecretKeys` survival is asserted, not verified.** Plan: *"keep `connectionSecretKeys` — v2 still honours these on namespaced XRs"*. v2 reworked the connection-secret model (XRs are namespaced; secrets land in the XR's namespace). Whether `connectionSecretKeys` is still a valid field on the v2 XRD schema is unconfirmed. If it's gone, the platform-cluster XRD admission-fails.

3. **MR-CONNECTION-DETAILS-NS only half handled for platform-cluster.** Plan removes `writeConnectionSecretsToNamespace` from the Composition but never adds the v2 equivalent (the *Composition*'s mechanism for declaring which MR connection-details propagate to the XR). The plan says XR-author sets `writeConnectionSecretToRef` — true for *where the XR's combined secret lands* — but the Composition still needs to declare WHICH MR keys feed it (currently relies on `connectionSecretKeys` + ASM/EKS provider connection details). Gap.

4. **`crossplane.io/external-name` annotation behaviour unverified for v2 namespaced MRs.** Plan does not address whether the existing external-name patches (cluster-role, node-role, eks-cluster, eks-nodegroup) need namespace-qualification or change semantics under `.m.upbound.io`. Important for adoption (Open Q #1).

## Completeness gaps

- **`crossplane/xrds/platform-secret/render-fixtures/input.yaml`** and **`crossplane/xrds/platform-cluster/render-fixtures/input.yaml`** — impact trace flagged `claimRef` as v1-only inside these fixtures. Plan excludes them via glob but never rewrites them; if SEG-4 runs `crossplane render` against them they still fail.
- **`crossplane/claims/example-*.yaml`** — punted to SEG-3 but impact trace lists them as RUNTIME-FAIL. Plan should at minimum delete-or-rewrite them in this PR to avoid stale `kind: PlatformSecret` examples breaking `kubectl apply`.
- **Kyverno policy 09** — deferred to follow-up; the impact trace explicitly notes silent no-op risk. Should be inside SEG-1's PR scope or have a tracking issue filed.

## Risky assumptions / fictional details

- `kind: ClusterProviderConfig` exists and is the right name (vs `ProviderConfig` with `scope: Cluster`) — needs doc-cite. Upbound v2.x AWS providers ship both `ProviderConfig` and `ClusterProviderConfig`; the plan picks one without source.
- That `apiextensions.crossplane.io/v1` accepts `spec.scope: Namespaced` (see Flaw #1).
- That `crossplane render` in v0.10.6 still consumes `pt.fn.crossplane.io/v1beta1` input.
- That removing `deletionPolicy` is unconditional — v2 introduces `managementPolicies` as the replacement; the plan mentions it once in §3 Open-Q #1 but never sets a default in the Compositions.

## Suggested concrete fixes

1. Verify and pin the XRD apiVersion: fetch the live v2 XRD CRD (`kubectl get crd compositeresourcedefinitions.apiextensions.crossplane.io -o yaml`) on a 2.3 cluster and commit to either `v1` or `v2`. Cite docs in the plan.
2. Verify `connectionSecretKeys` is still a valid field; if removed, plan how `platform-cluster` exports the kubeconfig (likely via the EKS Cluster MR's connection-details and an explicit `writeConnectionSecretToRef` on the XR).
3. Add `managementPolicies: ["*"]` (or explicit list) to every MR base in both Compositions as the v2 replacement for `deletionPolicy: Delete`. Without it, the default may differ from v1.
4. Resolve `ClusterProviderConfig` vs `ProviderConfig` against the live `aws.m.upbound.io` CRDs in the cluster and cite a doc URL.
5. Include `crossplane/claims/example-*.yaml` and both `render-fixtures/input.yaml` in SEG-1 (rewrite or delete) — don't ship a PR that leaves stale v1 examples in the tree.
6. File a tracking issue for Kyverno policy 09 inside SEG-1 even if the fix is a follow-up.
7. State the connection-secret routing for `platform-cluster` end-to-end: which MR keys → XR → `writeConnectionSecretToRef.name: platform-cluster-kubeconfig` in ns `platform`.

## Report

Wrote `/home/user/k8-platform/ai/crossplane-v1-v2-un-fuckify/30-review-SEG-1-R1B-correctness.md`. Verdict REVISE-MAJOR. Top flaws: (1) plan asserts `apiextensions.crossplane.io/v1` accepts `spec.scope: Namespaced` with no source — v2 introduces an `apiextensions.crossplane.io/v2` group for namespaced XRDs and the wrong choice admission-fails the XRDs; (2) `deletionPolicy: Delete` removal is not paired with the v2 replacement `managementPolicies`, leaving MR lifecycle behaviour undefined.
