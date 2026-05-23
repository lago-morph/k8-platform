# Testing Plan

Three layers of test, plus a fourth planned for phase 2+. Each runs in a
different environment and catches a different class of bug.

| Layer | Lives at | Runs against | Catches | Cost per run |
|---|---|---|---|---|
| Unit | `tests/unit/` | Local shell — no AWS, no cluster | Helm chart value contracts, IRSA wiring, IAM-policy completeness, EKS module tripwires | <30s |
| Kyverno (audit) | `policies/audit/` | Continuously, in-cluster | Drift from any source — chart bump, hand edit, Argo sync, new namespace | continuous |
| Integration | `tests/integration/` | Live management cluster + sandbox AWS | Real end-to-end flows — IRSA STS, ExternalDNS → Route53, Crossplane → S3, Argo selfHeal | ~10–15 min for all 10 |
| Chainsaw (planned) | `tests/chainsaw/` | `kind` cluster ± LocalStack | XRD / Composition / Claim logic before any AWS apply | <2 min per scenario |

The matrix is intentionally non-overlapping. Unit tests catch authoring-time
mistakes. Kyverno watches runtime drift. Integration tests catch
real-cloud failures. Chainsaw will catch Crossplane logic bugs in seconds
instead of waiting for the 15-minute management apply.

---

## Layer 4 (planned): Chainsaw for Crossplane

**Status:** intent recorded; concrete tests authored when phase 2 begins.

### Why Chainsaw, why now-but-not-quite-yet

[Kyverno Chainsaw](https://kyverno.github.io/chainsaw/) is a declarative
Kubernetes end-to-end test runner. Each scenario is YAML: a sequence of
`apply` / `assert` / `wait` / `delete` steps, with built-in retry and
timeout. It runs against any reachable cluster — typically a fresh `kind`
cluster in CI.

Chainsaw's sweet spot is multi-step Kubernetes flows with timing concerns,
which is exactly the shape of Crossplane testing:

```yaml
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Test
metadata: { name: platformsecret-claim }
spec:
  steps:
    - apply: { file: ../../crossplane/xrds/platform-secret.yaml }
    - apply: { file: ../../crossplane/compositions/platform-secret.yaml }
    - apply: { file: fixtures/test-claim.yaml }
    - assert: { file: assertions/composite-ready.yaml }
    - assert: { file: assertions/secret-materialized.yaml }
```

Compared to `bash + kubectl + wait_for` (what `tests/integration/06` does
today):
- Tests are declarative, easier to review
- Retry / timeout / poll-interval are first-class fields
- Cleanup happens automatically
- `kind` lifecycle is one config block away

It's not the right tool **today** because phase 1 has no XRDs / Compositions
/ Claims yet — there's nothing for Chainsaw to test that the existing
`helm template` unit tests don't already cover faster.

### When it lands

Phase 2 introduces the first XRDs:
- `PlatformSecret` (AWS Secrets Manager + ESO ClusterSecretStore + ExternalSecret)
- `PlatformCluster` (full EKS via Crossplane AWS provider)

When the phase 2 work starts, the first thing added is the Chainsaw test
infrastructure:

1. `tests/chainsaw/` directory with sub-trees per XRD.
2. A `kind` config under `tests/chainsaw/kind-config.yaml` that
   pre-installs Crossplane v2 + AWS provider stub.
3. Per-XRD `Test` files plus assertion manifests.
4. A `tests/chainsaw/run.sh` that wraps `kind create` → install
   Crossplane → run chainsaw → kind destroy. Target wall-clock: <3 min.
5. A `chainsaw` job in `.github/workflows/terraform-test.yml` that runs
   on every PR touching `crossplane/`.

### What it does NOT replace

- The existing integration tests (05, 06) still run against the real
  sandbox to catch issues a kind + stub setup can't see: real IRSA,
  real AWS API rate limits, real-provider package install behaviour,
  Route53 propagation. Chainsaw lives upstream of those — it catches
  the Composition-logic bugs before they reach the 15-minute apply.
- Unit-test contracts on helm chart rendering still belong in
  `tests/unit/test_helm_render.sh`. Chainsaw runs YAML, not Helm
  values, so per-chart bugs aren't its concern.

### Open design questions for the phase-2 author

- Real AWS or LocalStack for the provider's calls? Real AWS gives
  high-fidelity test, costs us sandbox quota; LocalStack is free but
  the Crossplane AWS provider doesn't always like its responses.
  Default plan: **real AWS, scoped to a single test bucket prefix**.
- Crossplane v2 in kind needs ~2 GB RAM. CI runner needs to be sized
  accordingly. Self-hosted runner would help, but introduces a
  maintenance surface — start with GH-hosted and revisit.
- Per-scenario kind cluster vs. shared kind cluster across scenarios?
  Per-scenario is cleaner but slower. Default plan: **shared cluster
  per Chainsaw run, scenarios serialized**.

---

## Bug-to-test traceability

For every bug encountered during phase 1, the table below shows which
test would catch it on the next iteration.

| Bug | Catches it | Faster diagnostic added |
|---|---|---|
| EKS v20 `enable_cluster_creator_admin_permissions` default | `tests/unit/test_eks_module_defaults.sh` | n/a — terraform error is immediate |
| RBAC race on first helm release | (none — race condition; fixed by retry semantics) | retry built into the loop |
| argocd IRSA on top-level SA, not server.SA | `tests/unit/test_helm_render.sh`; `policies/audit/01-argocd-server-irsa.yaml` | n/a |
| ExternalDNS install missing entirely | `tests/unit/test_irsa_helm_linkage.sh` | n/a |
| bitnami external-dns chart stuck | `tests/unit/test_helm_render.sh` (chart-specific helm template would fail) | n/a |
| external-dns IRSA missing ListHostedZones | `tests/unit/test_iam_required_actions.sh` | `scripts/diag-component.sh external-dns` dumps the AccessDenied logs |
| argocd ingress.hosts vs ingress.hostname | `tests/unit/test_helm_render.sh`; `policies/audit/03-ingress-managed-by-external-dns.yaml` | DNS-failure diagnostic in workflow now dumps ingress YAML |
