# Session Handoff — k8-platform

This file is updated at the end of every AI session. It captures what was done,
the current state of the codebase, and the next concrete steps.

The **Current Sandbox Session** block immediately below tracks per-session
state — what's currently live in AWS, which phase is being worked on, when
the sandbox expires. The agent reads it first and writes back to it after
every workflow run. See `ai/testing-guidelines.md` for the procedure that
drives those updates.

---

## Current Sandbox Session

| Field | Value |
|---|---|
| Sandbox started | 2026-05-23T03:20Z |
| Estimated expiry | 2026-05-23T07:20Z |
| Active phase | 1 (management) — cumulative bring-up of phase 0 first |

### Phase states (this session)

| Phase | State | Last action | Run URL |
|---|---|---|---|
| 0 base | not-applied-this-session | — | — |
| 1 management | not-applied-this-session | — | — |
| 2 xrds | not-coded | — | — |
| 3 platform | not-coded | — | — |
| 4 observability | not-coded | — | — |
| 5 auth | not-coded | — | — |
| 6 workload | not-coded | — | — |

State values: `not-coded`, `code-only`, `plan-green`, `applied`, `verified`,
`broken`, `not-applied-this-session` (code exists and has been verified in
a *prior* session; needs re-apply in the current sandbox).

The agent updates this block after each `workflow_dispatch` completes. If
the sandbox is expired or unknown, ask the user once and then refresh.

---

## Current State (as of 2026-05-10)

### Iteration progress

| Iteration | Description | Status |
|-----------|-------------|--------|
| 0 | Base environment (VPC, Route53, Cognito, ACM) | Code complete, **plan ✅ apply-tested ✅** (apply+destroy confirmed 2026-05-04) |
| 1 | Management cluster (EKS, ArgoCD, Crossplane, ESO, ExternalDNS) | Code complete, **plan ✅** — apply not yet tested (blocked by EKS+Crossplane bugs, now fixed) |
| 2 | Crossplane foundations (PlatformSecret XRD) | Not started |
| 3 | Platform services cluster | Not started |
| 4 | Observability (Grafana, Prometheus) | Not started |
| 5 | Authentication (Keycloak → Cognito SSO; EKS API → Keycloak) | Spec updated, not started |
| 6 | First workload cluster | Not started |

### What "plan passes" means

The GitHub Actions CI workflow runs `terraform plan` on every push. Both modules
now plan cleanly against a real sandbox AWS account — base and management init+plan
both succeed regardless of whether base has been applied first.

---

## What Was Done — 2026-05-10 (Iteration 5 spec extension: kubectl via Keycloak)

Branch: `claude/keycloak-k8s-integration-LurOa`. Spec-only change; no Terraform
or manifest work yet.

1. **Untangled the two OIDC roles in EKS** — the cluster as OIDC *issuer* (IRSA,
   already in scope) versus the API server as OIDC *client* (the new bit).
   Documented this distinction in `DESIGN.md` §2.5 so it is not re-confused later.

2. **Added the kubectl-via-Keycloak federation flow** to `DESIGN.md` §2.5,
   including the diagram, the "Keycloak is the only IdP EKS sees" stance, and
   the rationale for username/group prefixes (`kc:`).

3. **Extended Iteration 5 deliverables** in `DESIGN.md` §4 to include
   `aws_eks_identity_provider_config`, the Keycloak `kubernetes` public/PKCE
   client, the Cognito → Keycloak group-claim mapper, and ClusterRoleBindings
   for `kc:k8s-admins` / `kc:k8s-viewers`.

4. **Added REQ-AUTH-07..10** in `REQUIREMENTS.md`:
   - 07: associated OIDC config on the API server pointing at Keycloak
   - 08: groups originate in Cognito, mapped through Keycloak
   - 09: ClusterRoleBindings under `clusters/<cluster>/`; IAM stays as break-glass
   - 10: documented kubectl/`oidc-login` setup

5. **Added ADR-007** "EKS API server federates to Keycloak; Cognito stays
   behind Keycloak; IAM is break-glass" with the full reasoning chain
   (provider slot choice, group source choice, IAM-as-recovery, token
   refresh latency caveat).

**Decisions captured this session:**
- Group source: Cognito groups, passed through Keycloak (preserves ADR-004
  and REQ-AUTH-03).
- Sequencing: extend Iteration 5 rather than splitting into 5b — auth lights
  up as one coherent milestone.

**Immediate next step:** when Iteration 5 begins, the base module needs Cognito
groups (`k8s-admins`, `k8s-viewers`) added before Keycloak realm work can be
tested end-to-end.

---

## What Was Done — 2026-05-04 (Terraform fixes + Crossplane v2)

1. **Investigated real CI run** — a `workflow_dispatch apply-and-destroy` run on
   `main` was missed because CI results are posted as commit comments (not PR
   comments or check runs) when no PR exists. Updated `terraform-ci-watch` skill
   with explicit two-path instructions and `curl` commands for reading commit comments.

2. **Fixed management module Terraform errors** found in the CI apply run:
   - `manage_aws_auth_configmap = true` removed (no longer valid in EKS module v20+)
   - Remote state `try()` guards added so management plans when base state is empty
   - `aws_nat_gateways` data source guarded with `count` conditional
   - NAT gateway route block converted to `dynamic` to avoid index-out-of-bounds
   - Removed `kubernetes` provider entirely — replaced with `terraform_data`
     local-exec for Crossplane manifests; ArgoCD ingress moved to Helm values

3. **Upgraded to Crossplane v2 APIs** — the previous code used v1 APIs removed in v2:
   - `ControllerConfig` (v1alpha1) → `DeploymentRuntimeConfig` (v1beta1)
   - `controllerConfigRef` → `runtimeConfigRef` (with explicit apiVersion/kind)
   - Provider package: `upbound/provider-aws:v0.46.0` → `upbound/provider-family-aws:v1.12.0`
   - Crossplane Helm chart: `1.15.1` → `2.0.1`
   - IRSA service account: `provider-aws-*` → `upbound-provider-family-aws`

4. **Plan-only CI now fully green** — both base (25 resources) and management
   (51 resources) init and plan without errors on every push to `test/**`.

---

## What Was Done — 2026-05-03 second session (docs cleanup + skills)

Branch: `claude/plan-and-cleanup-docs-w7OKB`. Implementation phases 1–4 of
the plan in `/root/.claude/plans/we-need-to-plan-vectorized-moore.md`.

1. **Slimmed `CLAUDE.md`** — secrets table reduced from 9 rows to 3 (only
   the actually-required GitHub secrets), CI Loop section (~65 lines)
   replaced with a 4-line pointer to the new skills. Net 168 → 110 lines.

2. **Reorganized `ai/`**:
   - `ai/testing-overview.md` → `ai/archive/` (superseded by skill)
   - `ai/BLOG-OVERVIEW.md`, `ai/BLOG-OUTLINES.md` → `ai/blog/`
   - Added `ai/archive/README.md` and `ai/blog/README.md`
   - Kept in place: `REQUIREMENTS.md`, `DESIGN.md`, `handoff.md`,
     `testing-guidelines.md`

3. **Added a `SessionEnd` hook** at `.claude/settings.json` that copies
   each session's transcript to `logs/<session-id>.jsonl` automatically.
   The `.gitignore` rule on `*.jsonl` is preserved — files land untracked
   until a human reviews and `git add -f`s them. See `logs/README.md`.

4. **Created `terraform-ci-watch` skill** at
   `.claude/skills/terraform-ci-watch/`. Reusable across other Terraform-
   on-AWS-via-GitHub-Actions projects. Drives the post-push CI loop:
   locate run, poll, fetch logs on failure, classify, fix, re-push,
   3-strike escalation. Reference docs split out:
   `failure-taxonomy.md`, `log-fetching.md`, `escalation-template.md`.

5. **Created `crossplane-claim-verify` skill** at
   `.claude/skills/crossplane-claim-verify/`. Independent of the
   terraform skill; use whichever fits the change. Drives the
   post-claim-apply loop: wait for `Synced`/`Ready`, descend into managed
   resources, verify the actual cloud resource out-of-band, classify and
   fix, 3-strike escalation. Reference docs: `readiness-conditions.md`,
   `failure-taxonomy.md`, `cloud-verification.md`,
   `escalation-template.md`.

### Iteration code state — unchanged from first session

Iterations 0 and 1 are still code-complete and CI-plan-passing but not
yet apply-tested. That's still the immediate next milestone (Phase 5 in
the plan).

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
blocked by EKS/Crossplane bugs, now fixed).

1. Start a fresh Pluralsight AWS sandbox session
2. Copy the three AWS credentials into GitHub repository secrets
3. Go to **Actions → Terraform Test → Run workflow**
4. Select `main`, mode `apply-and-destroy`
5. Use the `terraform-ci-watch` skill to follow the run

After apply succeeds (before destroy runs), verify intent — not just
"no Terraform errors":
- ACM cert status: `ISSUED`
- EKS cluster status: `ACTIVE`, 2 nodes `Ready`
- ArgoCD pods running with IRSA annotation
- ESO and Crossplane installed in their namespaces
- ArgoCD UI reachable at `argocd.management.<domain>` over HTTPS

**Known risks:**
- Crossplane `DeploymentRuntimeConfig` (v1beta1) CRD must be registered
  before `terraform_data` applies the Provider — `depends_on` handles this
  but watch for timing issues.
- ArgoCD ingress via Helm `server.ingress.*` — confirm ExternalDNS creates
  the DNS CNAME correctly.

Expected duration: ~25 minutes (ACM cert validation 1–3 min, EKS cluster
creation ~15 min, ArgoCD Helm install ~3 min, destroy ~10 min).

If the apply fails, the `terraform-ci-watch` skill drives the diagnose-
and-fix loop (3-strike escalation).

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
