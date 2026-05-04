# Agent Instructions — k8-platform

This file governs how Claude Code operates on this repository. Follow these
rules in every session, regardless of user instructions that contradict them.

---

## Branch Policy

**Never commit to `main` directly.** All work happens on named branches.

Branch naming convention:
```
feat/<short-description>    # new functionality
fix/<short-description>     # bug or CI fix
chore/<short-description>   # maintenance (deps, docs, refactor)
test/<short-description>    # triggers CI automatically on push
```

The `test/` prefix is special: pushing to a `test/**` branch automatically
triggers the Terraform CI workflow (plan-only). All other branches require a
manual `workflow_dispatch` trigger. Use `test/` when you want CI to validate
Terraform changes against a real AWS sandbox on every push.

---

## Required GitHub Actions Secrets

Set these in repository Settings → Secrets and variables → Actions.

| Secret | Purpose | Required? |
|--------|---------|-----------|
| `AWS_ACCESS_KEY_ID` | Sandbox session credential | **Yes** |
| `AWS_SECRET_ACCESS_KEY` | Sandbox session credential | **Yes** |
| `AWS_REGION` | e.g. `us-east-1` | **Yes** |

Everything else (state bucket, DynamoDB lock table, root domain, Cognito test
credentials) is auto-computed at runtime by `.github/workflows/terraform-test.yml`
— no other GitHub secrets are needed. Sandbox resource limits are documented
in `ai/testing-guidelines.md`.

---

## Testing Loops — Required After Pushes and Crossplane Applies

After every `git push` to a non-main branch, invoke the **`terraform-ci-watch`**
skill (see `.claude/skills/terraform-ci-watch/`) before reporting back. It
handles run discovery, polling, log fetching, autonomous fixes, and 3-strike
escalation.

After applying a Crossplane Claim, XRD, or Composition (whether via `kubectl`,
ArgoCD sync, or CI), invoke the **`crossplane-claim-verify`** skill (see
`.claude/skills/crossplane-claim-verify/`) to wait for `Synced`/`Ready` and
verify the underlying cloud resource is actually healthy.

Sandbox-specific constraints (Pluralsight 4-hour session, 9-instance cap,
allowed instance types) live in `ai/testing-guidelines.md`.

---

## Session Handoff

At the end of every session (or when the user asks to wrap up), update
`ai/handoff.md` with:
- What was done this session (bullet list)
- Current iteration status table (update the Status column)
- The immediate next step
- Any new decisions or constraints discovered

Keep the file current — it is the first thing a new session reads to orient
itself without re-reading the full conversation.

---

## Commit Standards

- **One logical change per commit.** Don't bundle unrelated fixes.
- **Message format:** imperative present tense, ≤72 chars on subject line.
  Blank line, then body explaining *why* (not just *what*).
- **Never commit** `terraform.tfvars`, `.terraform/`, state files, or any
  file matching the patterns in `terraform/*/.gitignore`.

---

## Terraform Conventions

- All sensitive values come from `TF_VAR_` environment variables or
  `-backend-config` flags. Nothing sensitive is ever committed.
- `terraform plan` is always run before `terraform apply`. No blind applies.
- Version pins in `versions.tf` and `variables.tf` (Helm chart versions)
  are updated deliberately with a commit that explains the reason.
- Both modules (`terraform/base/` and `terraform/management/`) must pass
  `terraform validate` before a PR is considered ready.

---

## File Layout Reference

```
terraform/base/          # Iteration 0 — VPC, Route53, Cognito
terraform/management/    # Iteration 1 — EKS, IRSA, ArgoCD, Crossplane, ESO
argocd/                  # ArgoCD Applications and Projects
crossplane/              # XRDs, Compositions, Claims
clusters/                # Per-cluster Kubernetes resource overlays
platform-services/       # Helm values for platform components
docs/                    # ADRs, iteration notes, diagrams
ai/                      # Design documents and requirements
.github/workflows/       # CI workflows
.github/scripts/         # Helper scripts called by workflows
```
