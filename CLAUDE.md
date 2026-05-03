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
```

---

## Required GitHub Actions Secrets

Set these in repository Settings → Secrets and variables → Actions.
Items marked **auto** are discovered at runtime and do not need to be secrets.

| Secret | Purpose | Required? |
|--------|---------|-----------|
| `AWS_ACCESS_KEY_ID` | AWS credentials from the sandbox session | **Yes** |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials from the sandbox session | **Yes** |
| `AWS_REGION` | AWS region, e.g. `us-east-1` | **Yes** |
| `TF_VAR_COGNITO_TEST_USER_EMAIL` | Cognito test user email | **Yes** |
| `TF_VAR_COGNITO_TEST_USER_PASSWORD` | Cognito test user password | **Yes** |
| `TF_STATE_BUCKET` | S3 state bucket | **auto** — derived from account ID |
| `TF_STATE_DYNAMODB_TABLE` | DynamoDB lock table | **auto** — fixed name |
| `TF_VAR_DOMAIN` | Root domain | **auto** — queried from Route53 |
| `TF_VAR_ACME_EMAIL` | Let's Encrypt email | **removed** — ACM used instead |

The CI workflow creates the S3 bucket and DynamoDB table on first run.
The domain is discovered from the pre-existing Route53 zone in the sandbox.
See `ai/testing-overview.md` for the full testing setup and `ai/testing-guidelines.md`
for Pluralsight sandbox resource limits.

---

## CI Loop — Required After Every Push

After every `git push` to a non-main branch, execute this loop **before
reporting back to the user**:

### 1. Find the Actions run

Use `mcp__github__pull_request_read` to read the PR associated with the
branch, or `mcp__github__list_commits` / `mcp__github__get_commit` to find
the commit SHA. The commit's check runs reflect the Actions status.

Alternatively, use the GitHub REST API via available MCP tools to call:
```
GET /repos/{owner}/{repo}/actions/runs?branch={branch}&per_page=1
```

### 2. Poll until terminal

Poll every 30 seconds until the run reaches a terminal state:
`completed` (success), `failure`, `cancelled`, or `timed_out`.

A run is **still in progress** when `status` is `queued` or `in_progress`.

### 3. On success

Report back with:
- One sentence confirming success
- The Actions run URL
- Any notable plan output from the comment posted on the PR/commit

### 4. On failure — attempt autonomous fix

a. Fetch the workflow run logs. The run logs are available at:
   ```
   GET /repos/{owner}/{repo}/actions/runs/{run_id}/logs
   ```
   If this returns a redirect to a zip URL, fetch and read the relevant
   log file(s) from the zip.

b. Identify the root cause. Common failure categories:
   - **Missing secret** — variable is empty, `terraform init` fails with
     "no such bucket" or similar. Cannot be fixed autonomously; report to user.
   - **Terraform syntax/config error** — fix the `.tf` file and re-push.
   - **Provider version constraint** — update `versions.tf` and re-push.
   - **IAM / permission error** — adjust the IRSA policy in `irsa.tf`.
   - **AWS API error** — may be a real resource conflict; investigate before
     changing code.

c. Apply the fix. Edit only the files required.

d. Commit with a message that references the failure:
   ```
   fix: [module] short description of what failed and why
   ```

e. Push and return to step 1.

### 5. After 3 consecutive failed fix attempts — stop

Report to the user with:
- The exact error text from the most recent log
- A numbered list of each fix attempted and its outcome
- Your diagnosis of why the loop is stuck
- A concrete question or action you need from the user to unblock

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
