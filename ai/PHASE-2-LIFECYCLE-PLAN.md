# Phase 2 lifecycle plan — verify, tear down, rebuild

This doc is a **runbook** for the operator (you, or a future agent with
direct `aws` + `kubectl` access). It covers (A) finishing phase-2
verification, (B) tearing it down via ArgoCD, (C) confirming it's gone,
(D) rebuilding it from git, and (E) re-verifying.

Earlier versions of this doc were paired with a `mode=teardown-phase-2 /
verify-absent / rebuild` input on `.github/workflows/integration-tests.yml`
so the steps could be dispatched from a sandbox without cluster access.
That dispatch surface was removed once the standard sandbox gained
`aws` CLI + direct `kubectl`; the bash blocks here are the verbatim
contents of those removed workflow steps. Paste them inline.

## Confirmed before starting

- **No Terraform touches phase 2 resources** after `terraform_data.argocd_bootstrap` in `terraform/management/helm.tf` fires (one-shot, ran at the end of phase-1 apply-and-verify). The XRDs, Compositions, Kyverno policy 09, and ClusterSecretStore all live behind ArgoCD-managed paths.
- The `terraform_data.kyverno_audit_policies` resource still applies the 8 policies in `policies/audit/` — those are phase-1 audit policies that don't reference any platform abstraction kinds. PR #52 relocated the only phase-2-coupled policy (09) to `crossplane/policies/`, where it is ArgoCD-synced.
- This means tear-down/rebuild of phase 2 is **purely a GitOps + kubectl operation**; Terraform state is untouched.

## Prerequisite: kubeconfig

Every section below assumes:

```sh
aws sts get-caller-identity
aws eks update-kubeconfig --name k8-platform-mgmt --region "$AWS_REGION"
kubectl get nodes
```

## A. Final verification of phase 2 as-is

| # | Action | Mechanism |
|---|---|---|
| A.1 | Run a focused PlatformSecret e2e test | dispatch `integration-tests.yml` with `test_filter=11`, OR `bash tests/integration/11_platform_secret_e2e.sh` directly |
| A.2 | Confirm `platformclusters.platform.k8-platform.io` CRD landed | `kubectl get crd platformclusters.platform.k8-platform.io` |
| A.3 | Run the full integration bundle | dispatch `integration-tests.yml` with empty filter, OR `tests/integration/run.sh` directly |
| A.4 | Mark phase 2 `verified` in `ai/handoff.md` Environment State | commit to a chore branch + PR |

Completion criterion: A.1, A.2, A.3 all green; A.4 PR merged.

## B. Tear down phase 2 via ArgoCD (no Terraform touched)

The cascade order matters — claims first (so AWS resources clean via the providers), then disable selfHeal (otherwise it un-deletes everything), then delete the Applications themselves so ArgoCD's resources-finalizer prunes the rest in dependency order.

```sh
set -e

echo "── B.1 delete in-flight PlatformSecret claims ──"
# If the CRD is gone (already torn down), skip cleanly.
if kubectl get crd platformsecrets.platform.k8-platform.io >/dev/null 2>&1; then
  kubectl delete platformsecret --all -A --ignore-not-found || true
else
  echo "  PlatformSecret CRD already absent — nothing to delete"
fi

echo ""
echo "── B.2 wait for composites + managed resources gone ──"
if kubectl get crd xplatformsecrets.platform.k8-platform.io >/dev/null 2>&1; then
  # 5 min cap — claim deletion triggers Composition cascade →
  # ASM API call → status propagation.
  kubectl wait --for=delete xplatformsecret --all --timeout=300s 2>/dev/null || true
fi
# Also wait for any remaining ASM managed resources to drain.
if kubectl get crd secrets.secretsmanager.aws.upbound.io >/dev/null 2>&1; then
  kubectl wait --for=delete secret.secretsmanager.aws.upbound.io --all --timeout=300s 2>/dev/null || true
fi

echo ""
echo "── B.3 disable selfHeal on the two phase-2 apps ──"
for app in crossplane-resources management-cluster-config; do
  if kubectl get application "$app" -n argocd >/dev/null 2>&1; then
    kubectl patch application "$app" -n argocd --type merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}'
    echo "  patched $app: selfHeal disabled"
  else
    echo "  $app already absent"
  fi
done

echo ""
echo "── B.4 cascade-delete the apps ──"
# ArgoCD's resources-finalizer.argocd.argoproj.io triggers ordered
# prune of every resource the app manages. Foreground cascade blocks
# until finalizers complete.
for app in crossplane-resources management-cluster-config; do
  if kubectl get application "$app" -n argocd >/dev/null 2>&1; then
    # Ensure finalizer is set so cascade actually prunes.
    kubectl patch application "$app" -n argocd --type merge \
      -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
    kubectl delete application "$app" -n argocd \
      --cascade=foreground --timeout=600s &
  fi
done
wait
echo "── teardown complete ──"
```

## C. Verify phase 2 is fully gone

```sh
set -e
fail=0

check_absent() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✗ FAIL: $label — still present"
    fail=1
  else
    echo "  ✓ ok: $label — absent"
  fi
}

echo "── C.1 platform.k8-platform.io CRDs ──"
check_absent "platformsecrets CRD"   kubectl get crd platformsecrets.platform.k8-platform.io
check_absent "xplatformsecrets CRD"  kubectl get crd xplatformsecrets.platform.k8-platform.io
check_absent "platformclusters CRD"  kubectl get crd platformclusters.platform.k8-platform.io
check_absent "xplatformclusters CRD" kubectl get crd xplatformclusters.platform.k8-platform.io

echo ""
echo "── C.2 Compositions ──"
# Composition CRD is from Crossplane and stays; just check the
# individual Composition objects we deployed are gone.
if kubectl get crd compositions.apiextensions.crossplane.io >/dev/null 2>&1; then
  check_absent "platform-secret-aws Composition"  kubectl get composition platform-secret-aws
  check_absent "platform-cluster-aws Composition" kubectl get composition platform-cluster-aws
fi

echo ""
echo "── C.3 ClusterSecretStore ──"
if kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; then
  check_absent "aws-secrets-manager ClusterSecretStore" \
    kubectl get clustersecretstore aws-secrets-manager
fi

echo ""
echo "── C.4 Kyverno ClusterPolicy ──"
if kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  check_absent "platform-secret-namespace-allowed ClusterPolicy" \
    kubectl get clusterpolicy platform-secret-namespace-allowed
fi

echo ""
echo "── C.5 ASM secrets tagged PlatformAbstraction ──"
asm=$(aws secretsmanager list-secrets \
  --query 'SecretList[?Tags[?Key==`PlatformAbstraction`]].Name' \
  --output text 2>/dev/null || true)
if [ -z "$asm" ] || [ "$asm" = "None" ]; then
  echo "  ✓ ok: no ASM secrets tagged PlatformAbstraction"
else
  echo "  ✗ FAIL: ASM secrets still present:"
  echo "$asm" | sed 's/^/      /'
  fail=1
fi

echo ""
echo "── C.6 Phase-2 ArgoCD apps ──"
for app in crossplane-resources management-cluster-config; do
  check_absent "Application $app" kubectl get application "$app" -n argocd
done

echo ""
if [ "$fail" -ne 0 ]; then
  echo "── VERIFY-ABSENT: FAIL ──"
  exit 1
fi
echo "── VERIFY-ABSENT: all phase-2 resources confirmed gone ──"
```

## D. Rebuild phase 2 from git

Two equivalent rebuild paths:

**D-path-1 (preferred): re-sync the bootstrap App.** Because bootstrap syncs `argocd/apps/*.yaml`, force-syncing bootstrap re-creates both `management-cluster-config` and `crossplane-resources` Applications. Each then syncs its own subtree:

```sh
argocd app sync bootstrap --force --replace
# OR via kubectl since we don't always have argocd CLI:
kubectl patch application bootstrap -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD","syncOptions":["Replace=true"]}}}'
```

**D-path-2 (fallback): re-apply the manifests and watch.**

```sh
set -e
echo "── D apply argocd/apps manifests ──"
kubectl apply -f argocd/apps/management-cluster-config.yaml
kubectl apply -f argocd/apps/crossplane-resources.yaml

echo ""
echo "── waiting for management-cluster-config to sync ──"
# Argo's automated sync kicks within ~30s; give it 5 min to converge
# fully (CRD installs + ClusterSecretStore Ready).
for i in $(seq 1 30); do
  sync=$(kubectl get application management-cluster-config -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  health=$(kubectl get application management-cluster-config -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
  echo "  attempt $i: sync=$sync health=$health"
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && break
  sleep 10
done

echo ""
echo "── waiting for crossplane-resources to sync ──"
for i in $(seq 1 30); do
  sync=$(kubectl get application crossplane-resources -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  health=$(kubectl get application crossplane-resources -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
  echo "  attempt $i: sync=$sync health=$health"
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && break
  sleep 10
done

echo ""
echo "── rebuild post-state ──"
kubectl get application -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
echo ""
kubectl get crd | grep platform.k8-platform.io || true
echo ""
kubectl get clustersecretstore aws-secrets-manager \
  -o jsonpath='{"Ready="}{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

ArgoCD runs in sync-wave order: `-10` (`management-cluster-config` → ClusterSecretStore) before `0` (`crossplane-resources` → XRDs/Compositions/policies).

## E. Re-verify everything works after rebuild

| # | Action | |
|---|---|---|
| E.1 | Re-run unit tests | push to a chore branch triggers `unit-tests.yml`. |
| E.2 | Re-run the full integration bundle | `tests/integration/run.sh` directly, or dispatch `integration-tests.yml` with empty filter. |
| E.3 | Mark phase 2 `re-verified-after-teardown` in `ai/handoff.md` | commit + merge. |

## Out-of-scope follow-ups (not blocking phase 2)

- Chainsaw ESO webhook-cert harness bug (kind cluster only; not phase-2-blocking)
- Repair the broken `tests/e2e/run.sh` reference in `terraform-test.yml` (cosmetic — current path uses dedicated `integration-tests.yml`)
- PlatformCluster Composition's first live invocation (phase 3)
