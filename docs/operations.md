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
- **AWS account credentials** — written to GitHub Secrets (see below)

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

All testing happens via **GitHub Actions** against the target AWS account.

### Step 1 — Set GitHub secrets

Go to **GitHub → repo → Settings → Secrets and variables → Actions** and set:

| Secret name | Value |
|-------------|-------|
| `AWS_ACCESS_KEY_ID` | AWS credential for the target account |
| `AWS_SECRET_ACCESS_KEY` | AWS credential for the target account |
| `AWS_REGION` | e.g. `us-east-1` |

These are the **only** secrets needed. Everything else is auto-discovered.
Rotate them if the credentials change.

### Step 2 — Trigger the workflow

All Terraform CI runs are manual: Actions → Terraform Test → Run workflow.
Pick the `phase` (`base` | `management` | `test`) and `action` (`plan` |
`apply` | `verify` | `apply-and-verify` | `destroy` | `test-unit` | `test-e2e`)
and dispatch.

**Plan only (safe, no AWS resources created):**
- Actions → Terraform Test → Run workflow → phase: `base` (or `management`) → action: `plan`

**Apply and verify a phase (creates real AWS resources):**
- Actions → Terraform Test → Run workflow → phase: `base` (or `management`) → action: `apply-and-verify`
- Duration: ~3 min (base) / ~15 min (management). See `ai/testing-guidelines.md` §5 for the full action wall-clock table.

### Step 3 — Read the results

After the workflow finishes, it posts a comment on the PR (or the commit if
no PR is open) with:
- An **Overall** status line (✅ passed / ❌ failed with which steps)
- Collapsible sections for each step's output

If a step failed, expand its section to see the Terraform error.

### What the workflow does

1. Creates S3 bucket + DynamoDB table for Terraform state (idempotent)
2. Discovers the account's Route53 zone and sets `TF_VAR_domain` automatically
3. Generates a Cognito test user email + password for this run
4. Runs `terraform init` + `plan` for `terraform/base/`
5. Runs `terraform init` + `plan` for `terraform/management/`
   (this step is expected to warn on plan-only — it needs base state to exist)
6. On `apply-and-verify`: applies the requested phase, then runs the
   `[phase] e2e-verify` step. Destroy is a separate, scoped action.

---

## Deploying Manually (outside CI)

You can run Terraform locally against the AWS account.

```bash
# Export AWS credentials
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1

# Discover the account's hosted zone domain
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
The account has no public Route53 zone, or credentials are wrong. Confirm
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are valid for the account
that owns the zone — run `scripts/aws-creds-check.sh`.

### Management init fails with "Backend configuration changed"
The state bucket name is derived from the AWS account ID. If credentials
were rotated to a different account, the bucket changes too. Run
`terraform init -reconfigure` or delete the `.terraform` directory.

### Apply fails: "InvalidInstanceType"
An instance type outside `t2/t3/t3a/t4g micro/small/medium` was used. See
`ai/testing-guidelines.md` for allowed types. The management cluster must use
`t3.medium` or smaller.

### Apply fails: "VcpuLimitExceeded" or instance count errors
Too many instances. The account allows **maximum 9 concurrent instances**
(including stopped). Check `node_desired_size` in
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

## Pre-Apply Checklist

Before triggering `apply-and-verify`:

- [ ] GitHub secrets present and current (run `scripts/aws-creds-check.sh`)
- [ ] `node_desired_size` ≤ 2, `node_instance_type` = `t3.medium` or smaller
- [ ] Only 2 AZs configured (to stay within NAT gateway and instance limits)

After the run:
- [ ] Check the PR/commit comment for ✅ overall status
- [ ] If ❌, read the failing step's output section for the error
- [ ] The environment persists between runs — destroy is a deliberate,
      scoped action, not an automatic cleanup

---

## Runbooks

Runbooks document specific failure classes with step-by-step recovery procedures.

- `docs/runbooks/runbook-apply-zero-resources.md` — Apply complete: 0 added
  silent no-op class (`triggers_replace` pattern, PR #67).

---

## Where to Find Things

| Question | Where to look |
|----------|--------------|
| What iteration are we on? | `ai/handoff.md` |
| Why was X designed this way? | `ai/DESIGN.md` (ADR sections) |
| What are the AWS account constraints? | `ai/testing-guidelines.md` |
| How does CI work in detail? | `ai/testing-overview.md` |
| What are the full requirements? | `ai/REQUIREMENTS.md` |
| What secrets does CI need? | `CLAUDE.md` → Required Secrets table |

---

## Keycloak-authenticated kubectl (REQ-AUTH-10)

Phase 5 federates EKS API-server authentication to the Keycloak `platform`
realm (which itself brokers to Cognito). An operator authenticates to a
cluster with **only** the `oidc-login` kubectl plugin and a kubeconfig stanza
— **no AWS credentials and no IAM principal mapping**. Removing a user from
their Cognito group revokes cluster access on the next token refresh.

The federation path:

```
Cognito user (group k8s-admins)
  → Keycloak `platform` realm (brokers Cognito, lifts cognito:groups → groups claim)
  → public PKCE `kubernetes` client (no secret)
  → EKS aws_eks_identity_provider_config (usernameClaim preferred_username,
                                          groupsClaim groups, prefix `kc:`)
  → ClusterRoleBinding kc-k8s-admins-cluster-admin → cluster-admin
```

### 1. Install the `oidc-login` krew plugin

```sh
# Install krew (the kubectl plugin manager) if you don't have it, then:
kubectl krew install oidc-login
# Verify:
kubectl oidc-login --help
```

### 2. kubeconfig stanza

Point the cluster's `user` at the `oidc-login` plugin. Replace `<domain>`
with the live root domain (the Keycloak ingress host is
`auth.platform.<domain>`). The `kubernetes` client is **public + PKCE**, so
there is **no client secret**.

```yaml
# ~/.kube/config (user section)
users:
  - name: keycloak
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://auth.platform.<domain>/realms/platform
          - --oidc-client-id=kubernetes
          - --oidc-extra-scope=openid
          - --oidc-extra-scope=email
          - --oidc-extra-scope=profile
          # public client + PKCE: no --oidc-client-secret
        interactiveMode: IfAvailable
```

Wire it to a context whose `cluster` entry is the EKS API endpoint (from the
cluster connection secret / `aws eks update-kubeconfig`, but with the `user`
swapped for `keycloak`):

```sh
kubectl config set-context platform-keycloak \
  --cluster=<eks-cluster> --user=keycloak
kubectl --context platform-keycloak get pods   # opens a browser to Cognito on first use
```

The first call opens a browser, you log in as a Cognito user, and the plugin
caches the token. Subsequent calls reuse the cached token until it expires.

### Keycloak database (OPEN QUESTION — separate brief)

`platform-services/keycloak/values.yaml` disables the bundled Bitnami
PostgreSQL sub-chart and points Keycloak at an **external** Postgres reached
via a Kubernetes Secret named `keycloak-db` (keys `db-username`/`db-password`,
host/port/database in the values). **Which external Postgres is NOT yet
decided** — the candidates are (a) an RDS instance provisioned via a Crossplane
XR (consistent with the platform's Crossplane-first stance, durable, costs an
always-on instance), or (b) an in-cluster Postgres operator (cheaper for a
learning platform, but Keycloak's own state is then only as durable as the
cluster). Until the DB brief resolves this, `keycloak-db` must be created out
of band before the Keycloak Application can become Healthy.

### Keycloak realm — live wiring (COMMITTED 2026-07-05, phase-5 identity)

`platform-services/keycloak/spoke/realm-platform-configmap.yaml` imports the
`platform` realm with Cognito as an OIDC IdP (`identityProviders` alias
`cognito`), the `cognito:groups → groups` attribute mapper, the
`${CLAIM.email}` username template mapper, and the public PKCE `kubernetes`
client. Account-ephemeral values are `${KC_COGNITO_*}` env placeholders that
Keycloak substitutes during `--import-realm` (verified on the pinned 24.0.5).
The delivery chain: `terraform/base` writes ASM `k8-platform/base/cognito`
(endpoints + confidential client — the client secret is COGNITO-generated, so
the generate-once XPlatformSecret chain cannot carry it; the earlier plan to
route it via `keycloak-oidc-clients` predates ADR-0012 and is superseded) →
spoke ExternalSecret `keycloak-cognito-idp` → non-optional secretKeyRef env in
the keycloak ApplicationSet. Contract pinned by
`tests/unit/test_keycloak_cognito_idp_contract.sh`. Realm imports apply only
on a fresh Keycloak database (startup import is IGNORE_EXISTING): a merged
realm edit reaches a LIVE cluster's realm only at the next clean build. The
EKS `IdentityProviderConfig` (issuer = the Keycloak realm) is composed into
the platform-cluster Composition; on a fresh build its association retries
until Keycloak's discovery endpoint is publicly served, then converges.
