# Session Handoff — k8-platform

This file is updated at the end of every AI session. It captures what was done,
the current state of the codebase, and the next concrete steps.

---

## Current State (as of 2026-05-04)

### Iteration progress

| Iteration | Description | Status |
|-----------|-------------|--------|
| 0 | Base environment (VPC, Route53, Cognito, ACM) | Code complete, **plan ✅ apply-tested ✅** (apply+destroy confirmed 2026-05-04) |
| 1 | Management cluster (EKS, ArgoCD, Crossplane, ESO, ExternalDNS) | Code complete, **plan ✅** — apply not yet tested (blocked by EKS+Crossplane bugs, now fixed) |
| 2 | Crossplane foundations (PlatformSecret XRD) | Not started |
| 3 | Platform services cluster | Not started |
| 4 | Observability (Grafana, Prometheus) | Not started |
| 5 | Authentication (Keycloak → Cognito SSO) | Not started |
| 6 | First workload cluster | Not started |

### What "plan passes" means

The GitHub Actions CI workflow runs `terraform plan` on every push. Both modules
now plan cleanly against a real sandbox AWS account — base and management init+plan
both succeed regardless of whether base has been applied first.

---

## What Was Done This Session (2026-05-04)

1. **Investigated real CI run** — a `workflow_dispatch apply-and-destroy` run on
   `main` was missed because CI results are posted as commit comments (not PR
   comments or check runs) when no PR exists. Updated CLAUDE.md CI loop with
   explicit two-path instructions and `curl` commands for reading commit comments.

2. **Fixed management module Terraform errors** found in the CI apply run:
   - `manage_aws_auth_configmap = true` removed (no longer valid in EKS module v20+)
   - Remote state `try()` guards added so management plans when base state is empty
   - `aws_nat_gateways` data source guarded with `count` conditional
   - NAT gateway route block converted to `dynamic` to avoid index-out-of-bounds
   - Removed `kubernetes` provider entirely — replaced with `terraform_data`
     local-exec for Crossplane manifests; ArgoCD ingress moved to Helm values

3. **Upgraded to Crossplane v2 APIs** — the previous code used v1 APIs that were
   removed in Crossplane v2:
   - `ControllerConfig` (v1alpha1) → `DeploymentRuntimeConfig` (v1beta1)
   - `controllerConfigRef` → `runtimeConfigRef` (with explicit apiVersion/kind)
   - Provider package: `upbound/provider-aws:v0.46.0` → `upbound/provider-family-aws:v1.12.0`
   - Crossplane Helm chart: `1.15.1` → `2.0.1`
   - IRSA service account: `provider-aws-*` → `upbound-provider-family-aws`

4. **Plan-only CI now fully green** — both base (25 resources) and management
   (51 resources) init and plan without errors on every push to `test/**`.

---

## Previous Session Work (2026-05-03)

1. **Created the entire repo structure** — directory skeleton, all placeholder
   `.gitkeep` files, README, CLAUDE.md agent instructions.

2. **Scaffolded `terraform/base/`** (Iteration 0):
   - VPC with 2 AZs, public/private subnets, IGW, NAT gateways
   - Route53 dual-mode: creates a new zone for real deployments, or uses a
     pre-existing zone (Pluralsight sandbox mode) when `route53_zone_id` is set
   - ACM wildcard certificate (`*.{domain}`) with Route53 DNS-01 validation
   - Cognito user pool, app client (for Keycloak OIDC federation), test user

3. **Scaffolded `terraform/management/`** (Iteration 1):
   - EKS cluster (`t3.medium` × 2 nodes) via `terraform-aws-modules/eks`
   - IRSA roles for ArgoCD, Crossplane, ESO, ExternalDNS
   - Helm installs: ingress-nginx (NLB + ACM TLS termination), ESO, Crossplane
     (with AWS provider), ArgoCD
   - ArgoCD Ingress with ExternalDNS annotation

4. **Set up CI** (`.github/workflows/terraform-test.yml`):
   - Triggers on push to non-main branches and `workflow_dispatch`
   - Bootstrap step creates S3/DynamoDB state backend if absent
   - Auto-discovers Route53 zone and domain from the sandbox account
   - Auto-generates Cognito test credentials (no GitHub secrets needed for these)
   - Posts collapsible plan/apply/destroy output as PR/commit comment
   - Shows overall ✅/❌ status and per-step outcomes in the comment

5. **Fixed bugs found during CI runs**:
   - `issues: write` permission needed for PR comments
   - `set -o pipefail` on all `command | tee` steps
   - Cognito variables default to `""` so plan doesn't fail without secrets
   - HCL syntax: semicolons invalid in single-line `set` blocks in `helm_release`

6. **Documented testing approach** in `ai/testing-guidelines.md` and
   `ai/testing-overview.md`.

### Only 3 GitHub secrets are required

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | From Pluralsight sandbox |
| `AWS_SECRET_ACCESS_KEY` | From Pluralsight sandbox |
| `AWS_REGION` | e.g. `us-east-1` |

Everything else (domain, state bucket, Cognito test user) is auto-discovered
or generated at runtime.

---

## Immediate Next Step

**Run a full `apply-and-destroy` cycle** to validate management module
end-to-end (base apply+destroy was confirmed on 2026-05-04; management was
blocked by EKS/Crossplane bugs which are now fixed).

1. Merge `claude/review-handoff-actions-TmBhJ` to `main` (or run directly from it)
2. Start a fresh Pluralsight AWS sandbox session
3. Copy the three AWS credentials into GitHub repository secrets
4. Go to **Actions → Terraform Test → Run workflow**
5. Select the branch, mode `apply-and-destroy`
6. Watch for the commit comment — it should show ✅ for all steps

Expected duration: ~30 minutes (ACM cert 1–3 min, EKS cluster ~15 min,
ArgoCD+Crossplane Helm installs ~5 min, destroy ~10 min).

**Known remaining risks for the apply:**
- Crossplane `DeploymentRuntimeConfig` (v1beta1) requires Crossplane v2 to be
  fully up before the CRD is available — `terraform_data` depends_on handles
  ordering, but watch for timing issues.
- ArgoCD ingress via Helm `server.ingress.*` values — confirm ExternalDNS
  creates the DNS record correctly after apply.

If the apply fails, the CI loop in CLAUDE.md defines how to diagnose and fix.

---

## After a Successful Apply-and-Destroy

Once the full cycle passes, move to **Iteration 2: Crossplane foundations**.

Key deliverables for Iteration 2:
- `PlatformSecret` XRD and Composition (syncs AWS Secrets Manager → k8s Secret
  in any cluster via ESO)
- `PlatformCluster` XRD and Composition (provisions an EKS cluster via Crossplane
  AWS provider)
- Test the XRDs by creating a Claim from the management cluster

Files to create:
- `crossplane/xrds/platform-secret.yaml`
- `crossplane/compositions/platform-secret.yaml`
- `crossplane/xrds/platform-cluster.yaml`
- `crossplane/compositions/platform-cluster.yaml`
- ArgoCD Application pointing at the `crossplane/` directory

---

## Key Design Decisions (summary)

Full rationale is in `ai/DESIGN.md`. Short version:

| Decision | Choice | Why |
|----------|--------|-----|
| Multi-cluster pattern | Hub-spoke via ArgoCD | Management cluster manages all others |
| Cluster provisioning | Crossplane XRDs | Self-service via Claims, no Terraform per-cluster |
| Secret distribution | ESO + AWS Secrets Manager | Single source of truth, no k8s Secret replication |
| TLS (sandbox) | ACM wildcard + NLB termination | Sandbox domain can't use public ACME |
| TLS (production) | cert-manager + Let's Encrypt | Per-service certs, fully automated |
| State backend | S3 + DynamoDB | Standard; bootstrapped automatically by CI |
| Instance sizing | `t3.medium` × 2 | Fits within Pluralsight 9-instance limit |
