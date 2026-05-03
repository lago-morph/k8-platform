# Pluralsight AWS Cloud Sandbox — Testing Guidelines

**Source:** https://help.pluralsight.com/hc/en-us/articles/24425443133076-AWS-cloud-sandbox
(Note: this page requires Pluralsight authentication. The limits below are from
the documented constraints applied to this project. Verify against the above URL
if in doubt, especially before bumping instance sizes or counts.)

---

## Session Constraints

| Constraint | Value |
|------------|-------|
| Session duration | **4 hours** — the account and all resources are destroyed automatically |
| Re-use across sessions | Not possible — each session is a fresh account |
| Manual teardown | `workflow_dispatch` with `mode=apply-and-destroy` before the 4h cutoff |

**Implication for this project:** Terraform state stored in S3 within the sandbox
account is also destroyed when the session ends. Each new session starts from
scratch; the CI bootstrap step creates a fresh S3 bucket and DynamoDB table.

---

## EC2 Instance Restrictions

### Allowed instance families
_(Confirmed from Pluralsight documentation)_

| Family | Allowed sizes |
|--------|--------------|
| t2     | micro, small, medium |
| t3     | micro, small, medium |
| t3a    | micro, small, medium |
| t4g    | micro, small, medium |

**Only micro, small, and medium sizes are permitted.** Any instance type outside
these families and sizes (e.g. t3.large, m5.large, c5.xlarge) will be rejected.

### Maximum volume size
**100 GB** per EBS volume. The default EKS node root volume (20 GB) is well
within this limit.

### Total instance count
**Maximum 9 concurrent instances** across all services in the account.
This count includes stopped instances but excludes terminated ones.

EKS managed node group instances count toward this limit. Plan for the full
apply-and-destroy cycle:
- 2 management cluster nodes + NAT GW ENIs + any other instances ≤ 9

### Configuration for this project
The management cluster is configured to use `t3.medium` with `desired=2`,
`min=1`, `max=3`. This fits within sandbox limits (2 nodes out of 9 total).

- If the 2-node desired count causes quota issues, reduce `node_desired_size`
  to `1` — one t3.medium node is enough for plan/apply CI testing.
- Do **not** use t3.large or any larger size — the sandbox will reject it.

---

## EKS Constraints

- EKS control plane itself is a managed service and does not count toward
  the EC2 instance quota.
- Managed node groups use EC2 instances — they **do** count toward the quota.
- EKS version: use a currently supported version (1.28–1.30 as of 2026-05).
  Older versions may not be available in a fresh sandbox account.

---

## VPC and Networking

- **1 VPC per account** is typically the default limit. This project uses one
  VPC; do not create additional VPCs.
- Internet Gateway: 1 per VPC (default). The base module creates exactly one.
- NAT Gateways: sandbox accounts typically allow 2–5. The base module creates
  one per AZ (2 by default) — this is fine.
- Elastic IPs: default limit is 5. With 2 NAT gateways = 2 EIPs used. Leaves
  3 spare.

---

## IAM Constraints

- **IAM users cannot be created** in sandbox accounts. The workflow uses the
  temporary IAM credentials injected via `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
  secrets — these are sufficient for all Terraform operations.
- IAM roles and policies can be created (required for IRSA).
- The sandbox credential has `AdministratorAccess` — do not try to simulate
  least-privilege IAM in the sandbox; it works in real accounts.

---

## Route53

- The sandbox account comes with **one pre-created public hosted zone** for a
  randomly assigned subdomain (e.g. `ps-XXXX.training.internal` or similar).
- The CI workflow auto-discovers this zone and sets `TF_VAR_domain` and
  `TF_VAR_route53_zone_id` automatically.
- Do **not** try to create a second hosted zone; the base module uses a data
  source to reference the existing one when `route53_zone_id` is provided.

---

## ACM (Certificate Manager)

- ACM is available in sandbox accounts with no meaningful quota constraints
  for this project.
- The wildcard cert (`*.{domain}`) is provisioned in `terraform/base/acm.tf`
  with DNS validation via Route53. Validation typically completes in 1–3 minutes.
- ACM certificates are regional; the cert is created in `var.aws_region`.

---

## S3 and DynamoDB (Terraform State)

- The CI workflow creates an S3 bucket and DynamoDB table automatically if
  they don't already exist (using the account ID as a suffix for uniqueness).
- S3 bucket name: `k8-platform-tfstate-{account_id}`
- DynamoDB table: `k8-platform-tfstate-lock`
- Both are deleted when the sandbox session ends.

---

## Services Known to be Restricted or Unavailable

| Service | Status |
|---------|--------|
| AWS Organizations | Not available |
| AWS Control Tower | Not available |
| AWS SSO / IAM Identity Center | Not available |
| Amazon WorkSpaces | Not available |
| Amazon Connect | Not available |
| Cost Explorer historic data | Limited / no data |

Services used by this project (EKS, EC2, VPC, Route53, ACM, Secrets Manager,
Cognito, S3, DynamoDB, IAM) are all available.

---

## Staying Within Limits — Checklist

Before triggering `apply-and-destroy`:

- [ ] `node_desired_size` ≤ 2 in `terraform/management/`
- [ ] `node_instance_type` = `t3.medium` or smaller
- [ ] Only 1 VPC (the base module creates it)
- [ ] Only 2 NAT gateways (one per AZ) — do not add more AZs
- [ ] `availability_zones` has exactly 2 entries
- [ ] No t3.large, t3.xlarge, or any m-family instances anywhere
