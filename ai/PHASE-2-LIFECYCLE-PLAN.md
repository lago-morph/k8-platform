# Phase 2 lifecycle plan — verify, tear down, rebuild

This doc tracks the concrete steps to (A) finish phase-2 verification,
(B) tear it down via ArgoCD, (C) confirm it's gone, (D) rebuild it
from git, and (E) re-verify. Each step is dispatchable (or hand-runnable)
and ticks off as it lands.

## Confirmed before starting

- **No Terraform touches phase 2 resources** after `terraform_data.argocd_bootstrap` in `terraform/management/helm.tf` fires (one-shot, ran at the end of phase-1 apply-and-verify on 2026-05-24 run 26346784628). The XRDs, Compositions, Kyverno policy 09, and ClusterSecretStore all live behind ArgoCD-managed paths.
- The `terraform_data.kyverno_audit_policies` resource still applies the 8 policies in `policies/audit/` — those are phase-1 audit policies that don't reference any platform abstraction kinds. PR #52 relocated the only phase-2-coupled policy (09) to `crossplane/policies/`, where it is ArgoCD-synced.
- This means tear-down/rebuild of phase 2 is **purely a GitOps + kubectl operation**; Terraform state is untouched.

## A. Final verification of phase 2 as-is

| # | Action | Mechanism | Status |
|---|---|---|---|
| A.1 | Dispatch `integration-tests.yml` `test_filter=11` | jentic → workflow_dispatch | ⏳ in flight (run 26347839740) |
| A.2 | Confirm `platformclusters.platform.k8-platform.io` CRD landed | workflow's pre-flight step prints it | ⏳ |
| A.3 | Dispatch `integration-tests.yml` with empty filter — full bundle | jentic → workflow_dispatch | ⏳ |
| A.4 | Mark phase 2 `verified` in `ai/handoff.md` Environment State | Commit to a chore branch + PR | ⏳ |

Completion criterion: A.1, A.2, A.3 all green; A.4 PR merged.

## B. Tear down phase 2 via ArgoCD (no Terraform touched)

The cascade order matters — claims first (so AWS resources clean via the providers), then XRDs/Compositions (so admission stops accepting new claims), then the ClusterSecretStore (so ESO stops trying to sync from a deleted store).

| # | Action | Notes |
|---|---|---|
| B.1 | Delete in-flight PlatformSecret claims: `kubectl delete platformsecret --all -A` | Triggers ASM secret cleanup via the Composition's `deletionPolicy: Delete`. |
| B.2 | Wait for composites + managed resources gone | `kubectl wait --for=delete xplatformsecret --all --timeout=300s`; ASM API may take ~30s extra. |
| B.3 | Patch ArgoCD apps to disable selfHeal | Otherwise selfHeal undoes the cascade-delete in seconds. Patch `spec.syncPolicy.automated = null` on `crossplane-resources` and `management-cluster-config`. |
| B.4 | Cascade-delete the ArgoCD apps | `kubectl delete application crossplane-resources management-cluster-config -n argocd --cascade=foreground`. ArgoCD's `resources-finalizer.argocd.argoproj.io` triggers ordered prune of XRDs, Compositions, ClusterPolicy 09, ClusterSecretStore. |

Implementation: new `mode: teardown-phase-2` in `integration-tests.yml` so it dispatches end-to-end.

## C. Verify phase 2 is fully gone

| # | Check | Expected |
|---|---|---|
| C.1 | `kubectl get crd \| grep platform.k8-platform.io` | empty |
| C.2 | `kubectl get composition -A` | no `platform-secret-aws` / `platform-cluster-aws` |
| C.3 | `kubectl get clustersecretstore aws-secrets-manager` | `NotFound` |
| C.4 | `kubectl get clusterpolicy platform-secret-namespace-allowed` | `NotFound` |
| C.5 | `aws secretsmanager list-secrets --filters Key=tag-key,Values=PlatformAbstraction` | empty (or only `scheduled-for-deletion`) |
| C.6 | `kubectl get application -n argocd` | only `bootstrap` + any phase-3 apps remain |

Implementation: `mode: verify-absent` in `integration-tests.yml`.

## D. Rebuild phase 2 from git

Two equivalent rebuild paths:

**D-path-1 (preferred): re-sync the bootstrap App.** Because bootstrap syncs `argocd/apps/*.yaml`, force-syncing bootstrap re-creates both `management-cluster-config` and `crossplane-resources` Applications. Each then syncs its own subtree:

```sh
argocd app sync bootstrap --force --replace
# OR via kubectl since we don't always have argocd CLI:
kubectl patch application bootstrap -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD","syncOptions":["Replace=true"]}}}'
```

**D-path-2 (fallback): re-apply the manifests.**

```sh
kubectl apply -f argocd/apps/management-cluster-config.yaml \
              -f argocd/apps/crossplane-resources.yaml \
              -f argocd/apps/platform-cluster-claim.yaml
```

ArgoCD then runs in sync-wave order: `-10` (management-cluster-config → ClusterSecretStore) before `0` (crossplane-resources → XRDs/Compositions/policies).

Implementation: `mode: rebuild` in `integration-tests.yml`.

## E. Re-verify everything works after rebuild

| # | Action | |
|---|---|---|
| E.1 | Re-run unit tests | push to a chore branch triggers `unit-tests.yml`. |
| E.2 | Re-dispatch `integration-tests.yml` with empty filter | full bundle expected green again. |
| E.3 | Mark phase 2 `re-verified-after-teardown` in `ai/handoff.md` | Commit + merge. |

## Out-of-scope follow-ups (not blocking phase 2)

- Chainsaw ESO webhook-cert harness bug (kind cluster only; not phase-2-blocking)
- Repair the broken `tests/e2e/run.sh` reference in `terraform-test.yml` (cosmetic — current path uses dedicated `integration-tests.yml`)
- PlatformCluster Composition's first live invocation (phase 3)
