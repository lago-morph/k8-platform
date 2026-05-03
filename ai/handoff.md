# Session Handoff — k8-platform

This file is updated at the end of every AI session. It captures what was done,
the current state of the codebase, and the next concrete steps.

---

## Current State (as of 2026-05-03 — second session)

### Iteration progress

| Iteration | Description | Status |
|-----------|-------------|--------|
| 0 | Base environment (VPC, Route53, Cognito, ACM) | Code complete, plan passes — **not yet apply-tested** |
| 1 | Management cluster (EKS, ArgoCD, Crossplane, ESO, ExternalDNS) | Code complete, plan passes after base apply — **not yet apply-tested** |
| 2 | Crossplane foundations (PlatformSecret XRD) | Not started |
| 3 | Platform services cluster | Not started |
| 4 | Observability (Grafana, Prometheus) | Not started |
| 5 | Authentication (Keycloak → Cognito SSO) | Not started |
| 6 | First workload cluster | Not started |

### What "plan passes" means

The GitHub Actions CI workflow runs `terraform plan` on every push. Both modules
plan cleanly against a real sandbox AWS account with no errors. However, the plan
has never been promoted to a full `apply-and-destroy` cycle. That is the immediate
next milestone.

---

## What Was Done This Session (second session — docs cleanup + skills)

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

**Phase 5 of the plan: run a full `apply-and-destroy` cycle** to validate
the infrastructure actually provisions end-to-end, with explicit
intent-verification (not just "no terraform errors").

1. Start a fresh Pluralsight AWS sandbox session
2. Copy the three AWS credentials into GitHub repository secrets
3. Go to **Actions → Terraform Test → Run workflow**
4. Select the `main` branch, mode `apply-and-destroy`
5. Invoke the `terraform-ci-watch` skill to follow the run

After apply (before destroy), run the intent checks listed in Phase 5 of
the plan: ACM `ISSUED`, EKS `ACTIVE`, 2 nodes `Ready`, ArgoCD pods
running with IRSA annotation, ESO and Crossplane installed, ArgoCD UI
reachable at `argocd.management.<domain>` over HTTPS with valid cert.

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
