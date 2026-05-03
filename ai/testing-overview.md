# Testing Overview — k8-platform CI

This document describes how automated testing works for this project so that
future AI sessions and new contributors can understand the CI loop without
reverse-engineering the workflow files.

---

## Test Environment

All testing runs in a **Pluralsight AWS cloud sandbox** — a disposable,
fully-permissioned AWS account that lasts 4 hours and is then torn down.
See `ai/testing-guidelines.md` for the specific resource limits that apply.

Key properties:
- Fresh AWS account each session — no persistent state between sessions
- One pre-created Route53 public hosted zone with a sandbox-assigned domain
- AWS credentials injected as GitHub Actions secrets (`AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`)
- Terraform remote state is created fresh each session (S3 + DynamoDB
  bootstrapped by the CI workflow itself)

---

## GitHub Actions Workflow

**File:** `.github/workflows/terraform-test.yml`

### Triggers

| Event | Behaviour |
|-------|-----------|
| Push to any non-`main` branch | Runs `terraform init` + `plan` for both modules |
| `workflow_dispatch` with `mode=plan-only` | Same as push |
| `workflow_dispatch` with `mode=apply-and-destroy` | Full `init → plan → apply → destroy` cycle |

### Concurrency
One run per branch at a time. A new push cancels any in-progress run on the
same branch (`concurrency.cancel-in-progress: true`).

### Steps (in order)

1. **Checkout** — `actions/checkout@v4`
2. **Verify AWS CLI** — confirms `aws` is on PATH (ubuntu-latest ships it)
3. **Setup Terraform** — `hashicorp/setup-terraform@v3` pinned to `~1.6`
4. **Bootstrap state backend** — idempotent; creates S3 bucket + DynamoDB
   table if they don't exist, then writes `TF_BACKEND_*` and `TF_VAR_tf_state_bucket`
   to `$GITHUB_ENV` for subsequent steps
5. **Discover Route53 zone** — queries the account for the first public hosted
   zone, strips the trailing dot from the name, and writes `TF_VAR_domain` and
   `TF_VAR_route53_zone_id` to `$GITHUB_ENV`
6. **Detect modules** — checks whether `terraform/base/` and
   `terraform/management/` exist; sets step outputs. Allows the workflow to
   degrade gracefully when the Terraform code isn't yet merged.
7. **[base] init** — `terraform init` with S3 backend config via `-backend-config` flags
8. **[base] plan** — `terraform plan -out=base.tfplan`; output teed to `$RUNNER_TEMP/base-plan.txt`
9. **[base] apply** — `apply-and-destroy` only
10. **[management] init** — same pattern; `continue-on-error: true` because
    base remote state must exist before this can succeed (it won't on plan-only runs)
11. **[management] plan** — `continue-on-error: true` for same reason
12. **[management] apply** — `apply-and-destroy` only; re-plans first to get
    fresh remote state after base apply
13. **[management] destroy** — `always()` when `apply-and-destroy`; cleans up
    even if apply partially failed
14. **[base] destroy** — same; runs after management destroy
15. **Post summary comment** — always runs; calls `.github/scripts/post-comment.py`
    to post plan/apply/destroy output as a comment on the PR or commit

### Required Secrets

| Secret | Used for | Auto-discovered? |
|--------|----------|-----------------|
| `AWS_ACCESS_KEY_ID` | AWS API access | No — must be set |
| `AWS_SECRET_ACCESS_KEY` | AWS API access | No — must be set |
| `AWS_REGION` | AWS region for all resources | No — must be set |
| `TF_STATE_BUCKET` | ~~S3 bucket name~~ | **Yes** — derived from account ID |
| `TF_STATE_DYNAMODB_TABLE` | ~~DynamoDB table~~ | **Yes** — hardcoded as `k8-platform-tfstate-lock` |
| `TF_VAR_DOMAIN` | ~~Root domain~~ | **Yes** — queried from Route53 |
| `TF_VAR_COGNITO_TEST_USER_EMAIL` | ~~Cognito test user email~~ | **Yes** — `ci-test@{domain}` |
| `TF_VAR_COGNITO_TEST_USER_PASSWORD` | ~~Cognito test user password~~ | **Yes** — random per run |
| `TF_VAR_ACME_EMAIL` | ~~Let's Encrypt email~~ | **Removed** — ACM used instead |

Only the three AWS credential secrets need to be configured in GitHub
repository settings. Everything else is auto-generated at runtime.

---

## TLS Strategy

**Production (real deployments):** cert-manager with Let's Encrypt ACME (DNS-01
via Route53) issues per-service certificates managed as Kubernetes Secret
objects. Fully automated, no wildcard needed.

**Sandbox / CI testing:** AWS Certificate Manager (ACM) issues a single
`*.{domain}` wildcard certificate provisioned in `terraform/base/acm.tf`. The
certificate is attached to each cluster's ingress-nginx Network Load Balancer
via the `service.beta.kubernetes.io/aws-load-balancer-ssl-cert` annotation.
TLS terminates at the NLB; nginx and all cluster services see plain HTTP.

Why ACM for testing:
- The sandbox domain is not a real registered domain — Let's Encrypt's public
  ACME servers cannot validate it the same way
- ACM with DNS-01 validation (Route53) works for any domain in a Route53 zone,
  even sandbox-assigned ones
- No cert-manager IRSA role needed on the management cluster; simpler setup
- Wildcard cert means no per-service cert requests, no rate limits

---

## Domain and DNS

The workflow discovers the pre-existing sandbox hosted zone:
```bash
aws route53 list-hosted-zones \
  --query 'HostedZones[?Config.PrivateZone==`false`] | [0]'
```

The zone name becomes `TF_VAR_domain`. All cluster subdomains use this:
- `argocd.management.{domain}`
- `grafana.platform.{domain}`
- `auth.platform.{domain}`
- `hello.workload1.{domain}`

ExternalDNS on each cluster creates Route53 CNAME records pointing
`{service}.{cluster}.{domain}` → the cluster's NLB DNS name.

---

## Agent CI Loop

The AI agent (Claude Code) follows this loop after every push (defined in
`CLAUDE.md`):

1. Find the Actions run via GitHub MCP tools
2. Poll every 30s until terminal state
3. If **success**: report back with run URL
4. If **failure**: read logs, identify root cause, fix, push, repeat
5. After **3 failed fix attempts**: escalate to the user with full diagnosis

Common failure categories and autonomous fixes:

| Failure | Fix |
|---------|-----|
| Terraform syntax error | Edit the `.tf` file |
| Provider version constraint | Update `versions.tf` |
| AWS API error (resource conflict) | Investigate; may need manual teardown |
| Missing secret | Report to user — cannot be fixed autonomously |
| Backend bootstrap fails | Check AWS credentials; may be expired sandbox |

---

## Running Tests Manually

### Plan only (safe, no AWS changes)
Push any commit to a non-main branch. The workflow runs automatically.

### Full apply-and-destroy
```
GitHub → Actions → Terraform Test → Run workflow
  Branch: <your-branch>
  Mode: apply-and-destroy
```

**Important:** The sandbox session lasts 4 hours. If you trigger
`apply-and-destroy` near the end of a session, the destroy may not complete
before the account is terminated, leaving Terraform state inconsistent for the
next session. Always trigger at the beginning of a fresh session.

### Checking the plan output
After every push, the workflow posts a comment to the PR (or to the commit if
no PR exists) with collapsible sections showing the plan/apply/destroy output
for each module.

---

## Fresh Session Runbook

1. Start a new Pluralsight AWS sandbox session
2. Copy the AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
   `AWS_REGION`) into the GitHub repository secrets
3. Push a commit (or re-push) to trigger the workflow
4. For a full test: trigger `apply-and-destroy` via `workflow_dispatch`
5. Destroy before the 4-hour window closes (or the session ending does it for you)
