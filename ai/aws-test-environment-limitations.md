# AWS Test Environment — Hard Limits (do NOT cross)

This is a **Pluralsight cloud sandbox account**. It is ephemeral and rotated
between sessions. **Crossing any line below can trigger immediate account
shutdown.** Stay inside these lines.

Authoritative source for project-specific caps: `ai/testing-guidelines.md §1`.
Authoritative source for Pluralsight sandbox policy: the Pluralsight
"AWS cloud sandbox" help article (auth-walled; consult on rotation).

## Hard blockers — violating any of these can terminate the account

- **Regions:** stay in `us-east-1` or `us-west-2`. Never call any other region.
- **EC2 instance families/sizes:** ONLY `t2`/`t3`/`t3a`/`t4g` in `micro` / `small` / `medium`. No `large+`, no `m`/`c`/`r`/`g`/`p`/`x`/`i` families, no GPU/metal/burstable-unlimited.
- **EC2 concurrent instances:** ≤ **9** total across all services (EKS nodes count).
- **EBS volume size:** ≤ **100 GB** per volume.
- **VPCs:** ≤ **1** per account.
- **NAT GWs:** ≤ **2** (one per AZ — do not add AZs).
- **Elastic IPs:** ≤ **5** (2 already taken by NAT GW pair).
- **Availability zones:** exactly **2**.
- **IAM users:** cannot be created. Roles are fine.
- **Route 53 hosted zone:** exactly one pre-existing public zone — do not create more.
- **Do NOT touch:** AWS Organizations, Control Tower, IAM Identity Center / SSO, WorkSpaces, Connect, **Bedrock**, **AWS Marketplace** subscriptions, any service requiring billing-account changes, anything that creates standing spend after teardown (e.g., Reserved Instances, Savings Plans, support-plan upgrades).
- **Never enable:** services that incur cross-account billing or require explicit Pluralsight enablement — if unsure, do not enable it.
- **Time:** sandbox sessions are time-boxed (typically a few hours). Treat all infra as < 1-day lifetime.

## Pre-flight ritual (always)

1. `aws sts get-caller-identity` — confirm account and creds work.
2. Confirm region: `echo "$AWS_REGION"` is `us-east-1` or `us-west-2`.
3. Before any `terraform apply` / EC2 RunInstances / EKS NodeGroup create:
   - Count current instances: `aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output table`
   - Confirm the diff stays under all caps above.
4. Avoid blind `terraform apply` — always plan first; grep the plan for forbidden families/sizes/services.

## Safe-by-default services for this project

EC2 (within caps), VPC, Route 53, ACM, EKS, ECR, IAM roles/policies,
S3, DynamoDB, Secrets Manager, KMS, Cognito, CloudWatch + Logs + Alarms +
Dashboards + Metric Filters + Insights, EventBridge, SNS, SQS (small),
Lambda (small), CloudTrail, Systems Manager (Parameter Store, Session
Manager), STS.

## If you're unsure

Ask the user before enabling a new service. The cost of one chat round-trip
is trivial; the cost of account shutdown is a multi-hour restart.
