# Operations Guide — k8-platform

This guide explains how to work with this repository day-to-day: how to run
tests, how to deploy, how to understand what's running, and how to recover
from common failures. It assumes no memory of prior sessions.

---

## Prerequisites

### Tools (local)
- `git`
- `terraform` ≥ 1.6
- `aws` CLI v2
- `kubectl`
- `helm` ≥ 3

### Accounts / Access
- **GitHub repository access** — to push branches and trigger Actions
- **Pluralsight AWS sandbox** — for testing (see below)

---

## Understanding the Repository

```
terraform/base/          # Iteration 0 — VPC, Route53, Cognito, ACM cert
terraform/management/    # Iteration 1 — EKS cluster + ArgoCD + Crossplane + ESO
argocd/                  # ArgoCD Applications and Projects (GitOps)
crossplane/              # XRDs, Compositions, Claims
platform-services/       # Helm values overrides per service
clusters/                # Per-cluster Kubernetes manifests
docs/                    # Architecture decisions, diagrams, iteration notes
ai/                      # AI session context: design, requirements, testing docs, handoff
.github/workflows/       # CI — see "Running Tests" below
```

The platform is built in iterations. See `ai/handoff.md` for current iteration
status. See `ai/DESIGN.md` for full architecture.

---

## Running Tests (CI)

All testing happens via **GitHub Actions** in a disposable Pluralsight AWS sandbox.

### Step 1 — Start a sandbox session

1. Log into Pluralsight and start a new AWS Cloud Sandbox
2. Copy the three credentials it provides

### Step 2 — Set GitHub secrets

Go to **GitHub → repo → Settings → Secrets and variables → Actions** and set:

| Secret name | Value |
|-------------|-------|
| `AWS_ACCESS_KEY_ID` | From Pluralsight |
| `AWS_SECRET_ACCESS_KEY` | From Pluralsight |
| `AWS_REGION` | Region shown by Pluralsight (usually `us-east-1`) |

These are the **only** secrets needed. Everything else is auto-discovered.

### Step 3 — Trigger the workflow

All Terraform CI runs are manual: Actions → Terraform Test → Run workflow.
Pick the `phase` (`base` | `management` | `test`) and `action` (`plan` |
`apply` | `verify` | `apply-and-verify` | `destroy` | `test-unit` | `test-e2e`)
and dispatch.

**Plan only (safe, no AWS resources created):**
- Actions → Terraform Test → Run workflow → phase: `base` (or `management`) → action: `plan`

**Apply and verify a phase (creates real AWS resources):**
- Actions → Terraform Test → Run workflow → phase: `base` (or `management`) → action: `apply-and-verify`
- Duration: ~3 min (base) / ~15 min (management)
- The sandbox session must have enough time remaining (see `ai/testing-guidelines.md` §5)

### Step 4 — Read the results

After the workflow finishes, it posts a comment on the PR (or the commit if
no PR is open) with:
- An **Overall** status line (✅ passed / ❌ failed with which steps)
- Collapsible sections for each step's output

If a step failed, expand its section to see the Terraform error.

### What the workflow does

1. Creates S3 bucket + DynamoDB table for Terraform state (idempotent)
2. Discovers the sandbox Route53 zone and sets `TF_VAR_domain` automatically
3. Generates a Cognito test user email + password for this run
4. Runs `terraform init` + `plan` for `terraform/base/`
5. Runs `terraform init` + `plan` for `terraform/management/`
   (this step is expected to warn on plan-only — it needs base state to exist)
6. On `apply-and-destroy`: applies base, then applies management, then destroys
   management, then destroys base

---

## Deploying Manually (outside CI)

You can run Terraform locally against a sandbox account.

```bash
# Export sandbox credentials
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1

# Discover the sandbox domain
ZONE=$(aws route53 list-hosted-zones \
  --query 'HostedZones[?Config.PrivateZone==`false`] | [0]' \
  --output json)
export TF_VAR_domain=$(echo "$ZONE" | jq -r '.Name' | sed 's/\.$//')
export TF_VAR_route53_zone_id=$(echo "$ZONE" | jq -r '.Id' | sed 's|/hostedzone/||')

# Set up state backend
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export TF_VAR_tf_state_bucket="k8-platform-tfstate-${ACCOUNT_ID}"

# Deploy base
cd terraform/base
terraform init \
  -backend-config="bucket=${TF_VAR_tf_state_bucket}" \
  -backend-config="key=k8-platform/base/terraform.tfstate" \
  -backend-config="region=${AWS_DEFAULT_REGION}" \
  -backend-config="dynamodb_table=k8-platform-tfstate-lock"
terraform plan
terraform apply

# Deploy management cluster
cd ../management
terraform init \
  -backend-config="bucket=${TF_VAR_tf_state_bucket}" \
  -backend-config="key=k8-platform/management/terraform.tfstate" \
  -backend-config="region=${AWS_DEFAULT_REGION}" \
  -backend-config="dynamodb_table=k8-platform-tfstate-lock"
terraform plan
terraform apply
```

### Access the management cluster after apply

```bash
aws eks update-kubeconfig \
  --name k8-platform-mgmt \
  --region "${AWS_DEFAULT_REGION}"
kubectl get pods -A
```

ArgoCD UI is at `https://argocd.management.${TF_VAR_domain}`.
Initial admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Branch and PR Workflow

**Never commit directly to `main`.** All changes go through branches:

```
git checkout -b feat/my-feature   # or fix/..., chore/...
# make changes
git add <files>
git commit -m "feat: describe the change"
git push -u origin feat/my-feature
# open PR → dispatch terraform-test.yml manually when ready → merge when green
```

Branch naming:
- `feat/` — new functionality
- `fix/` — bug fixes
- `chore/` — docs, maintenance, refactoring

---

## Common Failures and Fixes

### Plan fails: "no such bucket"
The S3 state bucket doesn't exist. This shouldn't happen (CI creates it), but
if running locally, create it first:
```bash
aws s3 mb "s3://${TF_VAR_tf_state_bucket}" --region "${AWS_DEFAULT_REGION}"
```

### Plan fails: "Error: No public hosted zone found"
The sandbox account doesn't have a Route53 zone yet, or credentials are wrong.
Check that `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are from the current
(active) sandbox session — sandbox credentials expire when the session ends.

### Management init fails with "Backend configuration changed"
The state bucket changed (new sandbox session = new account ID = new bucket name).
Run `terraform init -reconfigure` or delete the `.terraform` directory.

### Apply fails: "InvalidInstanceType"
An instance type outside `t2/t3/t3a/t4g micro/small/medium` was used. See
`ai/testing-guidelines.md` for allowed types. The management cluster must use
`t3.medium` or smaller.

### Apply fails: "VcpuLimitExceeded" or instance count errors
Too many instances. The Pluralsight sandbox allows **maximum 9 concurrent
instances** (including stopped). Check `node_desired_size` in
`terraform/management/variables.tf` — reduce to `1` if needed.

### ArgoCD UI not reachable after apply
- Check that ExternalDNS created the DNS record:
  ```bash
  aws route53 list-resource-record-sets --hosted-zone-id "${TF_VAR_route53_zone_id}" \
    --query "ResourceRecordSets[?Name=='argocd.management.${TF_VAR_domain}.']"
  ```
- Check that the NLB is active:
  ```bash
  kubectl -n ingress-nginx get svc ingress-nginx-controller
  ```
- ACM cert must be in `ISSUED` state:
  ```bash
  aws acm list-certificates --query 'CertificateSummaryList[*].[DomainName,Status]'
  ```

---

## Sandbox Session Checklist

Before triggering `apply-and-verify`:

- [ ] Fresh sandbox session started (credentials not expired)
- [ ] GitHub secrets updated with new credentials
- [ ] At least 30 minutes remaining in the session
- [ ] `node_desired_size` ≤ 2, `node_instance_type` = `t3.medium` or smaller
- [ ] Only 2 AZs configured (to stay within NAT gateway and instance limits)

After the run:
- [ ] Check the PR/commit comment for ✅ overall status
- [ ] If ❌, read the failing step's output section for the error
- [ ] Sandbox destroys itself at session end — no manual cleanup needed unless
      `apply-and-destroy` failed mid-way (check the destroy steps ran)

---

## Where to Find Things

| Question | Where to look |
|----------|--------------|
| What iteration are we on? | `ai/handoff.md` |
| Why was X designed this way? | `ai/DESIGN.md` (ADR sections) |
| What are the AWS sandbox limits? | `ai/testing-guidelines.md` |
| How does CI work in detail? | `ai/testing-overview.md` |
| What are the full requirements? | `ai/REQUIREMENTS.md` |
| What secrets does CI need? | `CLAUDE.md` → Required Secrets table |
