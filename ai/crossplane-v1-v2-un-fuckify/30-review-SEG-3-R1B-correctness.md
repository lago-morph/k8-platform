# 30 — Review SEG-3 R1B: correctness

**Reviewer:** adversarial-correctness
**Target:** [`20-plan-SEG-3-test-infra.md`](./20-plan-SEG-3-test-infra.md)
**Verdict:** **REVISE-MAJOR**

---

## Verification anchors

- Crossplane v2 docs (`docs.crossplane.io/latest/managed-resources/managed-resources/`) confirm both `ProviderConfig` (namespaced) and `ClusterProviderConfig` (cluster-scoped) live under the **`aws.m.upbound.io/v1beta1`** group in provider-family-aws v2. Default fallback when `providerConfigRef.kind` is omitted is `ClusterProviderConfig` named `default`.
- v2 XRDs use `apiVersion: apiextensions.crossplane.io/v1` (unchanged) but require **`spec.scope: Namespaced`** for v2 behavior.
- SEG-1 plan §2.3 row 2 and §6 have already chosen `kind: ClusterProviderConfig` named `default`.

## Findings

### F1 (BLOCKER) — `run.sh` ProviderConfig heredoc apiGroup is wrong AND kind is wrong

Plan §2.3 row 1 only changes `aws.upbound.io/v1beta1` → `aws.m.upbound.io/v1beta1`. It leaves `kind: ProviderConfig` (lines 231 of run.sh). SEG-1's Compositions reference `kind: ClusterProviderConfig name: default`. Two consequences:

1. v2 `ProviderConfig` is **namespaced** — the heredoc has no `metadata.namespace`, so the apply lands in whatever default namespace the kubeconfig points at (likely `default`), not `crossplane-system`. The cluster-wide `default` name expected by every MR is never created.
2. Even if it landed correctly, `ProviderConfig` (namespaced) cannot satisfy a `providerConfigRef.kind: ClusterProviderConfig` reference — kind mismatch. Every MR will block with `cannot find ClusterProviderConfig default`.

**Fix:** change heredoc to `kind: ClusterProviderConfig` (cluster-scoped — no namespace). This matches the one-shared-PC-across-namespaces pattern.

### F2 (BLOCKER) — Integration test 06: missing `scope: Namespaced` on inline XRD

§2.3 row for 06 removes `claimNames:` and rewrites the Claim apply as a direct namespaced XR, but does **not** add `spec.scope: Namespaced` to the inline XRD. Without it the XRD is interpreted as `LegacyCluster` (v2 still accepts that for backward compat) — the resulting `PlatformTestBucket` CRD is cluster-scoped, and the `metadata.namespace: $TEST_NS` on the XR apply at the new L85–93 is silently ignored. Wait-for-XR misses, cleanup `delete -n $TEST_NS` errors.

### F3 (MAJOR) — Unit composition tests: `apiVersion` assertion value

Plan §2.3 changes only the API group on L41 of `test_platform_secret_composition.sh`. Per Crossplane v2 docs the v2 group for AWS SecretsManager Secret is `secretsmanager.aws.m.upbound.io/v1beta1` — confirmed in 00-situation.md §4. The plan's literal string is correct. **No defect here**, but the new providerConfigRef assertions added by the plan (§2.3 "NEW" rows) hard-code `ClusterProviderConfig` — must match SEG-1's choice exactly (it does).

### F4 (MAJOR) — Integration test 05: cluster-scoped MR ambiguity

Plan §3 open question 1 admits 05 may need a namespace. v2 default is namespaced; `s3.aws.m.upbound.io/v1beta1 Bucket` will be namespaced. Plan defers but lists no fallback edit. Bucket apply without `metadata.namespace` will land in `default` — `wait-for-claim.sh "$kind" "$BUCKET" "" 180` (empty ns arg) will not find it. Plan needs to commit to `namespace: crossplane-system` (or `default`) and update wait-for-claim args.

### F5 (MINOR) — Diagnostic block `-A` semantics

§2.3 row 2 says "change to `-A` consistently"; run.sh already uses `-A`. No actual edit needed; remove the row to avoid confusion.

## Coverage preservation

Plan's replacement of `deletionPolicy_Delete` with `no_deletionPolicy` (§2.3) correctly preserves regression coverage. The XRD `claimNames` removal is replaced by an explicit "absent" assertion — also good. **However** no new assertion is proposed for `spec.scope: Namespaced` on the v2 XRDs — gap; add to `test_platform_secret_xrd.sh` / `test_platform_cluster_xrd.sh`.

## RBAC dependency on SEG-1

Plan §1 row 7 flags `crossplane/rbac/01-crossplane-externalsecrets.yaml` as needing SEG-1 coordination. SEG-1 plan §1 row + §6.2 explicitly say "no edit" to that file. The implicit dependency does not exist; remove the row.

---

**Verdict:** REVISE-MAJOR — F1 and F2 are correctness blockers; F4 needs commit before merge.
