# Session Handoff — k8-platform

This file is the first thing a new session reads. It captures what was
done last, the current state of the cluster, and the next concrete steps.

The **Environment State** block immediately below tracks what's currently
live in AWS and which phase is being worked on. The agent reads it first
and writes back to it after every workflow run. See
`ai/testing-guidelines.md` for the procedure that drives those updates.

---

## NEW SESSION QUICKSTART (read this first)

You are starting against a **brand-new AWS account** that has had no
prior `terraform apply` from this repo. The previous session's cluster
(account `975050256915`) no longer exists. The credentials in GitHub
Secrets point at a different account, and the new account may have
**no pre-existing public Route53 hosted zone**.

**Required first steps:**

1. Confirm credentials work and the account has a Route53 zone:
   ```sh
   scripts/aws-creds-check.sh
   ```
   If no zone exists, **stop and escalate to the user** — there is no
   code change that fixes a missing hosted zone. The user will either
   provision one in the account or rotate creds to an account that
   has one.
2. Once preflight passes, you are starting at **phase 0 from scratch**.
   All phase states reset to `code-only` because the cluster from the
   previous session is gone. Dispatch:
   - `workflow_dispatch phase=base action=apply-and-verify`
   - then (after green) `workflow_dispatch phase=management action=apply-and-verify`
3. After each green apply-and-verify, run the full test bundle per
   `AGENTS.md §6.3`: `tests/unit/run.sh`, `phase=test action=test-e2e`,
   `tests/integration/run.sh`, then `scripts/kyverno-policies.sh` /
   `scripts/kyverno-violations.sh`.
4. **Read all of `AGENTS.md`** before starting. Pay particular attention to:
   - §5.1 — exact scope of "tear down phase X"
   - §6.2 — TDD discipline on every bug, no exceptions
   - §6.3 — full test bundle after every fresh `apply-and-verify`
   - §6.4 — spawn adversarial subagents whenever drafting new tests
   - §6.5 — repeat back compound prompts before acting
5. Then proceed into **phase 2** (Crossplane foundations: XRDs +
   Compositions + Claims for `PlatformSecret` and `PlatformCluster`).
   Phase 2 begins with Chainsaw infrastructure per `ai/TESTING-PLAN.md`
   §"Layer 4 (planned)".

**Stacked-PR state at session start:**

By the time this is read, three PRs from the previous session should
have been merged: PR #36 (AGENTS.md §§5.1/6.4/6.5 additions), the
handoff/plan PR (this file's updates), and the retrospective PR.
After they merge their branches are deleted; you start from `main`.

---

## Environment State

| Field | Value |
|---|---|
| Active phase | 1 (management apply-and-verify in flight) |
| Last update | 2026-05-23 (phase 0 verified on fresh account 309191981509) |
| AWS account | `309191981509` — Route53 zone `309191981509.realhandsonlabs.net` (Z0426781193AJAT8UDLZO) |

### Phase states

| Phase | State | Last action | Run URL |
|---|---|---|---|
| 0 base | verified | 2026-05-23 apply-and-verify ✅ (25 resources, ACM ISSUED, Cognito ready) | https://github.com/lago-morph/k8-platform/actions/runs/26340162917 |
| 1 management | applied? | 2026-05-23 apply-and-verify in flight on `claude/sweet-mayer-swD65` | — |
| 2 xrds | not-coded | — | — |
| 3 platform | not-coded | — | — |
| 4 observability | not-coded | — | — |
| 5 auth | not-coded | — | — |
| 6 workload | not-coded | — | — |

State values: `not-coded`, `code-only`, `plan-green`, `applied`, `verified`,
`broken`.

The agent updates this block after each `workflow_dispatch` completes.
If the state is stale or contradicts a recent CI run, refresh it first.

---

## Current State (as of 2026-05-10)

### Iteration progress

| Iteration | Description | Status |
|-----------|-------------|--------|
| 0 | Base environment (VPC, Route53, Cognito, ACM) | Code complete, **plan ✅ apply-tested ✅** (apply+destroy confirmed 2026-05-04) |
| 1 | Management cluster (EKS, ArgoCD, Crossplane, ESO, ExternalDNS) | Code complete, **apply-and-verify ✅** end-to-end (2026-05-23) |
| 2 | Crossplane foundations (PlatformSecret XRD) | Not started |
| 3 | Platform services cluster | Not started |
| 4 | Observability (Grafana, Prometheus) | Not started |
| 5 | Authentication (Keycloak → Cognito SSO; EKS API → Keycloak) | Spec updated, not started |
| 6 | First workload cluster | Not started |

### What "plan passes" means

The GitHub Actions CI workflow runs `terraform plan` on every push. Both modules
now plan cleanly against the target AWS account — base and management init+plan
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
| `AWS_ACCESS_KEY_ID` | AWS credential for the target account |
| `AWS_SECRET_ACCESS_KEY` | AWS credential for the target account |
| `AWS_REGION` | e.g. `us-east-1` |

Everything else (domain, state bucket, Cognito test user) is auto-discovered
or generated at runtime.

---

## What Was Done — 2026-05-23 (Phase 1 verified + test scaffolding)

1. **Phase 1 verified end-to-end** in AWS. PR #34
   contains the seven fixes that took us from cold management apply to a
   live ArgoCD UI reachable over HTTPS through the NLB. See
   `ai/TESTING-PLAN.md` for the bug-to-test traceability matrix.

2. **Test scaffolding landed** to prevent another seven-strike phase-1
   bring-up. Three layers (and a fourth planned):

   - `tests/unit/` — four new suites: `test_helm_render.sh`,
     `test_irsa_helm_linkage.sh`, `test_iam_required_actions.sh`,
     `test_eks_module_defaults.sh`. All run in <30s, no AWS / no cluster.
     Catch five of the seven phase-1 bugs at authoring time.
   - `policies/audit/` — Kyverno installed in Audit mode with 8 starter
     ClusterPolicies. Acts as continuous in-cluster assertion store.
   - `tests/integration/` — 10 end-to-end smoke tests (ArgoCD app sync,
     ExternalDNS → Route53, NLB → nginx → echo, ESO secret round-trip,
     Crossplane MR + XRD/Claim, IRSA STS round-trip, Kyverno report,
     selfHeal loop, secondary ingress). Orchestrator at
     `tests/integration/run.sh`.
   - **(Planned)** `tests/chainsaw/` — Kyverno Chainsaw for Crossplane
     logic, to be authored as the first deliverable of phase 2. See
     `ai/TESTING-PLAN.md` §"Layer 4 (planned)".

3. **Helper scripts** under `scripts/`: `k8s-status.sh`, `k8s-logs.sh`,
   `diag-component.sh`, `kyverno-policies.sh`, `kyverno-violations.sh`,
   `argocd-apps.sh`, `route53-records.sh`, `aws-creds-check.sh`.
   All read-only, all deterministic, source-pinned at top with usage.

4. **Workflow diagnostics improved**: the management argocd-url verify
   step now queries Route53 directly (not `dig` against public
   resolvers) and dumps pod logs / events / ingress YAML on failure.
   Same diagnostic block now mirrors to the HTTP step too.

---

## Immediate Next Step

The previous AWS account is gone. The first thing this session does is
follow **NEW SESSION QUICKSTART** at the top of this file:

1. `scripts/aws-creds-check.sh` — confirm the new account is usable.
2. Bring phase 0 and phase 1 back up from scratch
   (`apply-and-verify` for each, then full test bundle per §6.3).
3. **Only after phase 1 is green end-to-end**, start phase 2.

### Phase 2 — Crossplane foundations (start once phase 1 verified)

Authorial order, with §6.4 adversarial review at each test-drafting
point:

1. **Author `tests/chainsaw/` infrastructure first** (kind config,
   run.sh, per-XRD Test fixtures). See `ai/TESTING-PLAN.md` §"Layer 4
   (planned)". Before authoring the chainsaw scenarios themselves,
   draft the test list and invoke §6.4 (adversarial subagent review).
2. **Author `crossplane/xrds/platform-secret.yaml` + composition**;
   verify green via Chainsaw before any AWS apply. The test list for
   PlatformSecret also goes through §6.4 review.
3. **Author `crossplane/xrds/platform-cluster.yaml` + composition**;
   verify green via Chainsaw. Same §6.4 review.
4. **Re-apply management module** to register both XRDs in the live
   cluster (terraform_data already in place would re-fire if XRDs
   added there; for phase 2 they ship as ArgoCD-managed instead —
   wire an ArgoCD Application pointing at `crossplane/`).
5. **Run integration tests** —
   `tests/integration/05_crossplane_managed_resource.sh` and
   `06_crossplane_xrd_claim.sh` — to confirm round-trip against real
   AWS. Any failure goes through §6.2 (TDD on bug fix).

### Stacked-PR pattern for phase 2

Per `AGENTS.md §3`:

1. Phase 2 implementation + tests → one PR off `main`.
2. Phase 2 live-run + bug-fix work → stacked PR off (1).
3. Once phase 2 tests pass against the live cluster, dispatch
   `destroy` scoped to phase 2 only (per `AGENTS.md §5.1`: delete
   Claims → wait for cloud cleanup → delete XRDs/Compositions; leave
   phase 1 management cluster alone). Re-apply phase 2 from scratch
   and run the full test bundle again — the clean re-run is the
   actual quality signal.

---

## Key Design Decisions (summary)

Full rationale is in `ai/DESIGN.md`. Short version:

| Decision | Choice | Why |
|----------|--------|-----|
| Multi-cluster pattern | Hub-spoke via ArgoCD | Management cluster manages all others |
| Cluster provisioning | Crossplane XRDs | Self-service via Claims, no Terraform per-cluster |
| Secret distribution | ESO + AWS Secrets Manager | Single source of truth, no k8s Secret replication |
| TLS (this account) | ACM wildcard + NLB termination | Pre-existing zone has no public-ACME challenge path |
| TLS (production) | cert-manager + Let's Encrypt | Per-service certs, fully automated |
| State backend | S3 + DynamoDB | Standard; bootstrapped automatically by CI |
| Instance sizing | `t3.medium` × 2 | Fits within the 9-instance EC2 quota |
