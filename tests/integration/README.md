# tests/integration/

End-to-end smoke tests that exercise the management cluster against real
AWS. Each test is a self-contained script: it sets up a small fixture,
asserts the expected runtime behaviour, then tears down. None of the
tests touch production data; all live under throwaway names that include
a per-run suffix (`$RUN_ID`).

These are deliberately **separate** from `tests/unit/` (no AWS, no
cluster) and from `tests/e2e/` (read-only sanity assertions). Integration
tests **mutate cluster state** and **may create AWS resources**, so they
require a live cluster and explicit invocation.

## Bug coverage map

Each script exercises one (and only one) integration concern. The matrix
below is how I'd reach for them when something specific breaks.

| # | Script | Exercises | Most likely catches |
|---|---|---|---|
| 01 | `01_argocd_deploy_app.sh` | ArgoCD Application creates and syncs a Deployment | Argo broken, repo creds wrong, AppProject misscoped |
| 02 | `02_external_dns_record_creation.sh` | ExternalDNS reconciles an Ingress annotation → Route53 A record | IRSA scope, domainFilter mismatch, missing chart args |
| 03 | `03_ingress_curl_end_to_end.sh` | NLB→nginx→backend HTTP round trip | NLB TLS termination wrong, ACM cert mismatch, ingress class drift |
| 04 | `04_eso_secret_round_trip.sh` | Write to Secrets Manager → ESO materializes a k8s Secret | ESO IRSA, ClusterSecretStore config, secret-name format |
| 05 | `05_crossplane_managed_resource.sh` | Apply a raw Crossplane MR (S3 Bucket), assert Ready + bucket exists | Crossplane AWS provider package missing, runtimeConfig SA wrong, IAM gap |
| 06 | `06_crossplane_xrd_claim.sh` | XRD + Composition + Claim → composite Ready + bucket exists | Composition syntax, patches, composite-resource generation |
| 07 | `07_kyverno_audit_policy.sh` | Create a deliberately-bad SA → PolicyReport shows the violation | Kyverno reports broken, policy not loaded |
| 08 | `08_irsa_sts_round_trip.sh` | Run a pod with an IRSA-annotated SA, call sts:GetCallerIdentity, assert the assumed-role ARN matches | IRSA assume-role failing silently, OIDC provider broken, SA→role binding wrong |
| 09 | `09_secondary_ingress.sh` | Deploy a second app behind a different hostname; full DNS + HTTP path | external-dns ignoring non-argocd Ingresses, ingress class registry failure |
| 10 | `10_argocd_gitops_loop.sh` | Modify a manifest in the Application's repo; assert Argo auto-syncs | Argo repo polling, automated sync policy, drift detection |

## Running

```sh
# All ten, sequentially. ~10–15 minutes.
tests/integration/run.sh

# Just one, with verbose output and no teardown:
KEEP=1 VERBOSE=1 tests/integration/03_ingress_curl_end_to_end.sh
```

Environment variables consumed by all scripts:

- `KUBECONFIG` — required; tests use whatever cluster this points at.
- `AWS_REGION` — required for AWS API calls.
- `TEST_DOMAIN` — defaults to the auto-discovered Route53 zone domain.
- `RUN_ID` — defaults to a random 6-char suffix; override to share state
  across reruns of the same script (for KEEP=1 debugging).
- `KEEP=1` — skip teardown so you can `kubectl get` the leftovers.
- `VERBOSE=1` — emit each `kubectl` / `aws` call.

## Conventions

- Every fixture name includes `$RUN_ID` so parallel runs don't collide.
- All resources live under labels `test.k8-platform/integration=true` so
  `kubectl delete -l test.k8-platform/integration=true` clears
  everything in an emergency.
- Tests print `PASS` / `FAIL` / `SKIP` lines that `run.sh` aggregates.
- A test that requires another to have run already (e.g. (06) needs the
  provider from (05)) declares that in its header comment and skips
  with a clear message if the prerequisite is missing.

## Tear-down of cloud resources

Crossplane-managed resources persist after pod deletion. (05) and (06)
both explicitly delete the Crossplane object and wait for the cloud
resource to disappear before declaring success. If a test aborts mid-flight
you may need to clean up manually — `scripts/aws-creds-check.sh`
will at least confirm what's still around.
