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
Items marked **auto** are discovered at runtime and do not need to be secrets.

| Secret | Purpose | Required? |
|--------|---------|-----------|
| `AWS_ACCESS_KEY_ID` | AWS credentials from the sandbox session | **Yes** |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials from the sandbox session | **Yes** |
| `AWS_REGION` | AWS region, e.g. `us-east-1` | **Yes** |
| `TF_STATE_BUCKET` | S3 state bucket | **auto** — derived from account ID |
| `TF_STATE_DYNAMODB_TABLE` | DynamoDB lock table | **auto** — fixed name |
| `TF_VAR_DOMAIN` | Root domain | **auto** — queried from Route53 |
| `TF_VAR_COGNITO_TEST_USER_EMAIL` | Cognito test user email | **auto** — `ci-test@{domain}` |
| `TF_VAR_COGNITO_TEST_USER_PASSWORD` | Cognito test user password | **auto** — random per run |
| `TF_VAR_ACME_EMAIL` | Let's Encrypt email | **removed** — ACM used instead |

The CI workflow creates the S3 bucket and DynamoDB table on first run.
The domain is discovered from the pre-existing Route53 zone in the sandbox.
See `ai/testing-overview.md` for the full testing setup and `ai/testing-guidelines.md`
for Pluralsight sandbox resource limits.

---

## CI Loop — Required After Every Push

After every `git push` to a non-main branch, execute this loop **before
reporting back to the user**:

### How CI results are posted

The workflow (`post-comment.py`) posts a Markdown summary as either:
- A **PR comment** — when an open PR exists for the branch
- A **commit comment** — when no PR exists (direct push or manual dispatch)

This means **check runs / commit statuses do NOT carry the result content**.
You must read the comment directly to get plan/apply/destroy output.

### 1. Find the commit SHA and determine PR status

Use `mcp__github__list_commits` on the branch to get the HEAD commit SHA.

Then check for an open PR:
```
mcp__github__list_pull_requests  (filter by head branch)
```

### 2. Poll the Actions run until terminal

The workflow run status is available via the GitHub REST API. Use Bash + curl:
```bash
curl -s \
  "https://api.github.com/repos/{owner}/{repo}/actions/runs?branch={branch}&per_page=1" \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['workflow_runs']; print(r[0]['status'], r[0]['conclusion'], r[0]['html_url']) if r else print('none')"
```

Poll every 30 seconds until `status` is a terminal state:
`completed` → check `conclusion` for `success`, `failure`, `cancelled`, or `timed_out`.

A run is **still in progress** when `status` is `queued` or `in_progress`.

### 3. Read the result comment

**If a PR exists** — use `mcp__github__pull_request_read` with `get_comments`
to read the most recent Terraform summary comment on the PR.

**If no PR exists** — fetch commit comments via Bash + curl:
```bash
curl -s \
  "https://api.github.com/repos/{owner}/{repo}/commits/{sha}/comments" \
  | python3 -c "import json,sys; comments=json.load(sys.stdin); [print(c['body']) for c in comments]"
```
Note: this requires the repo to be public, or set a `GITHUB_TOKEN` env var
(`-H "Authorization: Bearer $GITHUB_TOKEN"`). The repo is public, so
unauthenticated reads work.

### 4. On success

Report back with:
- One sentence confirming success
- The Actions run URL
- Key output from the Terraform summary comment (overall status line +
  any plan/apply highlights)

### 5. On failure — attempt autonomous fix

a. Fetch the workflow run logs via Bash + curl:
   ```bash
   curl -s \
     "https://api.github.com/repos/{owner}/{repo}/actions/runs/{run_id}/logs" \
     -L -o /tmp/run-logs.zip && unzip -p /tmp/run-logs.zip | head -200
   ```
   If there are multiple log files in the zip, unzip selectively to find
   the failing step's log.

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

### 6. After 3 consecutive failed fix attempts — stop

Report to the user with:
- The exact error text from the most recent log
- A numbered list of each fix attempted and its outcome
- Your diagnosis of why the loop is stuck
- A concrete question or action you need from the user to unblock

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
