# 30 — SEG-1 Review (Round 1, Reviewer A — sequencing angle)

**Verdict:** REVISE-MAJOR

## What the plan does well

- Explicit "BLAST moment" identification in Step 2 plus the Step-3 drain gate is the right shape: claim CRDs disappear when `claimNames` is removed, and the plan acknowledges this must happen against an empty cluster.
- The state-transition mermaid and failure-recovery table per-step are concrete and reviewable; the rollback honesty ("git revert does NOT restore service") is unusually candid.
- Correctly identifies the render-fixture leak via `recurse: true` as a pre-existing bug and folds the fix into the cutover PR rather than deferring.

## Sequencing flaws

1. **Step 1 and Step 2 cannot be a single PR if ArgoCD sync orders them independently.** The plan packs XRDs + Compositions into one PR but Step 2's narrative requires Composition apply to follow XRD apply. ArgoCD with one Application syncing both files orders by kind (CRD/XRD before Composition by default) — that's fine — but the state diagram shows a transient "XRDs rolled, Compositions still v1" state which under v2 strict decoding means the v1 Composition is briefly invalid against the new XRD scope. Fix: add `argocd.argoproj.io/sync-wave` annotations: XRDs wave `-1`, Compositions wave `0`, OR enforce `SyncOptions=ApplyOutOfOrder=false` + verify Composition sync waits for XRD `Established`. Currently neither is specified.

2. **Step 3 (drain) runs BEFORE the PR merges, but ArgoCD auto-sync is not paused.** Between "drain complete" and "PR merged," ArgoCD's next auto-sync of `crossplane-resources` (default 3-min poll) re-applies the v1 manifests from `main`, which against provider v2.5.4 fails admission — but more importantly, if any consumer re-applies a claim during the gap, the drain is undone. Fix: `argocd app set crossplane-resources --sync-policy none` BEFORE Step 3; re-enable after Step 5 verify. Plan must add this as Step 2.5 / Step 5.5.

3. **Step 4's "manual sync" assumes the operator notices ArgoCD has already auto-synced.** The `platform-cluster-claim` app header says manual-sync, but no verify confirms `syncPolicy.automated` is absent. If a prior operator enabled auto-sync, Step 4 races with ArgoCD applying the OLD `kind: PlatformCluster` (whose CRD is gone). Fix: explicit `argocd app get platform-cluster-claim -o json | jq .spec.syncPolicy` check in Step 0.

4. **Step 0 gate on `ClusterProviderConfig default` existing is a verify, not a create — but SEG-2 is described as "may create it."** If SEG-2 doesn't, Step 0 fails and there's no fallback. Fix: Step 0 must include "if absent, apply this manifest:" with the literal YAML, not just a check.

5. **Finalizer race on Step 3 is hand-waved.** "Wait for finalizers" with `kubectl wait --for=delete` will hang indefinitely if the v1 provider can no longer Observe (it's already broken per situation doc §1 — that's the whole reason for the migration). The v1 provider in `PendingExternalResource` loop will never confirm deletion. Plan needs explicit: patch finalizers to `[]` after a bounded timeout (e.g., 5min), then manually verify AWS resource state via `aws` CLI. The recovery table mentions this but Step 3's happy-path doesn't.

6. **Step 5 (ArgoCD glob change) is sequenced LAST but must land in the SAME commit as Step 1.** If the glob isn't tightened, ArgoCD's first sync of the new XRDs ALSO syncs the v1 render-fixture XRs (which use `claimRef`) and they hit the cluster before the BLAST is complete. Fix: Step 5's `crossplane-resources.yaml` glob tighten must be ordered FIRST in the PR's apply sequence (sync-wave `-2`), not last.

7. **The "ProviderConfig must use `kind:`" in Step 2's MR `providerConfigRef` edit is correct, but the ClusterProviderConfig object itself must exist on the new `aws.m.upbound.io` group BEFORE Compositions render any MR.** Step 0 verifies its presence; good. But the plan never says whether SEG-2 or this PR creates it. If "operator one-liner," that one-liner needs to be in the PR description as a literal runbook command.

## Cross-segment hazards

- **SEG-2 partial completion.** Plan says "SEG-2 has merged" in Step 0 but SEG-2 might be merged-but-broken (IRSA SA-pin failing silently — exactly the risk doc 12 §"Single biggest blocker" calls out). The Step 0 gate only checks `Healthy=True INSTALLED=True`, which is true even when IRSA is broken. Need a stronger gate: apply a throwaway `XPlatformSecret` in a scratch namespace and assert it reaches `Ready=True` within 5 min. If it doesn't, SEG-1 cannot proceed regardless of SEG-2's `Healthy` claim.
- **ArgoCD auto-sync race during drain.** Covered in flaw #2 above. This is the highest-likelihood concurrency hazard.
- **Finalizer races on v1 MRs.** Covered in flaw #5. v1 provider is the broken-Observe provider — it cannot reliably finalize, so finalizer drain WILL hang.
- **PR #98 ordering vs. SEG-1 PR.** PR #98 bumps provider to v2.5.4. If PR #98 merges and ArgoCD applies v1 manifests against the v2 provider, the cluster enters a half-state: provider v2.5.4 running, v1 XRDs/Compositions/claims on cluster, all reconciles failing with admission/CRD-mismatch errors. The plan assumes PR #98 → SEG-2 → SEG-1, but SEG-1 must hard-gate "SEG-2 verify XR reaches Ready" before its drain step or the drain itself is impossible.
- **Two-operator concurrency.** Nothing in the plan prevents operator A running Step 3 drain while operator B runs `terraform apply` (which re-applies the Provider via `terraform_data.crossplane_aws_provider` and re-deletes the provider Deployment per the kubectl-delete-deploy hack — see doc 12 §`terraform_data.crossplane_aws_provider`). During the hack's deletion window, no reconciler is running; drain appears to complete; then provider comes back and re-reconciles the deleted MRs. Plan needs an explicit lockout: announce the cutover, freeze terraform apply for the duration.

## Suggested concrete fixes

1. Add **Step 0.5: Pause ArgoCD auto-sync** on `crossplane-resources` AND `platform-cluster-claim` Applications. Re-enable in new **Step 5.5** after verify.
2. Add **Step 0.6: Freeze `terraform apply`** via either a CI lockout label on the SEG-2 PR or a manual coordination note. Document the duration window (~2.5h per §7).
3. Strengthen **Step 0 IRSA gate**: apply a probe `XPlatformSecret` in a scratch ns; require `Ready=True` within 5 min. If not, halt.
4. In **Step 3**, add bounded-timeout finalizer drain (5 min) followed by explicit `kubectl patch --type=merge -p '{"metadata":{"finalizers":[]}}'` fallback, with a manual AWS-side cleanup checklist for any orphaned resources.
5. Add **sync-wave annotations**: glob-fix wave `-2`, XRDs wave `-1`, Compositions wave `0`, live XR wave `10` (already correct). Currently only the live-XR wave is mentioned.
6. Move the **ArgoCD include-glob tighten** (Step 5 for `crossplane-resources.yaml`) into the same commit AND order it first; render-fixture leak must be closed before the new XRDs land.
7. In **Step 0**, replace "verify ClusterProviderConfig exists" with "verify or create" and inline the literal YAML for the `aws.m.upbound.io/v1beta1` ClusterProviderConfig.
8. Add an explicit **"who runs what"** table mapping each step to operator-vs-ArgoCD-vs-Crossplane, so the two-operator concurrency hazard is visible at runbook time.
