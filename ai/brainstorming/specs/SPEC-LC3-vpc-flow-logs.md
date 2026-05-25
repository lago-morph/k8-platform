# SPEC-LC3 — Enable VPC Flow Logs to CloudWatch (7-day retention)

Status: DRAFT (spec only — no implementation in this PR)
Tier: C (nice-to-have, low risk, low effort)
Brainstorm ID: A1-004
Branch: to be created when the implementing agent picks this up
Owner: next agent picking up base-infrastructure hardening work

---

## 1. Summary

Add VPC flow logs, delivered to CloudWatch Logs with a 7-day retention
policy, as part of `terraform/base/vpc.tf`. The change introduces three
resources: an `aws_cloudwatch_log_group` for the flow log destination, an
`aws_iam_role` with the standard VPC flow log trust policy, and an
`aws_flow_log` resource attached to the platform VPC using traffic type
`ALL`. A helper script at `scripts/vpc-flow-grep.sh` provides a
ready-to-run Logs Insights query wrapper so the implementing agent — and
every future session — can interrogate the log group without reconstructing
the schema from scratch. Flow logs are part of Cluster 1 (base
infrastructure), are a prerequisite for Phase 5 (Keycloak ingress through
ALB) and Phase 6 (cross-cluster traffic), and have zero interaction with
the Crossplane, ArgoCD, or ESO stacks.

---

## 2. Retro pain killed

- **Silent NAT / SG failures during bring-up** (`ai/brainstorming/A1-debug-tools-max-capability.md`, row A1-004): the brainstorm catalogue was written precisely because NAT-gateway and security-group deny events are invisible without flow logs. Every session that provisioned the VPC operated blind on the network data-plane. Any packet drop — wrong SG rule, missing route, NACL mismatch — looked identical from the application side: a connection that never completed.

- **Blind debug loops on Crossplane provider connectivity** (`retrospective/2026-05-24-62.md`, Phase 6 summary): five chainsaw failures across PRs #52 and #53 were diagnosed entirely from Kubernetes-layer evidence. The root cause in each case involved a pod-to-endpoint path. Had VPC flow logs been present, a `REJECT` record on the relevant 5-tuple would have confirmed or ruled out a network-layer drop in seconds, rather than after multiple subagent log extractions.

- **"Manifest-only edit invisible to triggers_replace"** (`retrospective/2026-05-24-62.md`, PR #66 / SPEC-C1): the 7-second apply that reported `0 added, 0 changed, 0 destroyed` was the canonical example of an agent mistaking a green wrapper for a successful outcome. Network-layer silence has the same shape: a packet dropped at the SG produces no application-layer error, only a timeout. Flow logs break that silence.

- **Schema amnesia across account rotations** (`AGENTS.md §8.1`): the AWS test account is ephemeral. Every session starts fresh. Without a helper script encoding the flow log schema and the common query patterns, each session wastes 5–15 minutes reconstructing the Logs Insights query to find `REJECT` records. Cross-review A4→A1-004 (`ai/brainstorming/cross-review-from-A4.md`) calls this out explicitly: "Flow logs alone burned hours in prior sessions because nobody remembered the schema."

---

## 3. Out of scope

- **Flow logs to S3.** Rejected. The Pluralsight sandbox imposes no explicit S3 budget, but S3 buckets with server-side encryption and lifecycle rules are provisioned and destroyed with every account rotation. A bucket-based flow log destination requires a bucket policy with the VPC service principal, versioning decisions, and lifecycle management — all of which must be torn down cleanly. CloudWatch Logs is simpler, already in use by EKS and other phase-0/1 resources, and incurs no additional resource type. S3 would be the right choice in a production account with long-term SIEM integration; it is the wrong choice here.

- **Traffic type `REJECT` only.** Considered. A `REJECT`-only flow log is cheaper (roughly half the volume) and surfaces the most actionable signal: a dropped packet is always interesting. However, `ALL` is retained for two reasons. First, accepted flows are needed to confirm that a path believed to be open is actually being used — useful when debugging Phase 6 cross-cluster latency or Phase 5 ALB health-check reachability. Second, the 7-day retention cap and per-GB CloudWatch Logs pricing for a sandbox VPC with ≤9 EC2 instances produces a negligible bill; the cost difference between `REJECT` and `ALL` at this traffic volume is effectively zero.

- **Custom log format.** The default AWS VPC flow log format (version 2) is used. A custom format would add fields useful in later phases (for example, `pkt-src-aws-service` to identify traffic from AWS endpoints) but requires the implementing agent to maintain a format string and update the Logs Insights query schema. Default format is sufficient for all debugging needs through Phase 6, and the helper script documents the field positions.

- **Aggregation interval of 1 minute.** The default 10-minute aggregation interval is sufficient for debugging purposes. One-minute intervals would double CloudWatch Logs ingestion volume. No real-time alerting requirement exists in this platform.

- **Flow log metric filters or alarms.** Not in this spec. A CloudWatch metric filter that counts `REJECT` records and triggers an alarm is a reasonable follow-on (and is listed as A1-005 in the brainstorm catalogue), but it is orthogonal to flow log enablement and adds IAM and CloudWatch alarm resources that belong in a separate spec.

- **Management module flow logs.** Only `terraform/base/` is modified. The management cluster lives in the same VPC; the base-module flow log covers it automatically. There is no separate VPC in `terraform/management/`.

### Considered and rejected: per-subnet or per-ENI flow logs

Per-ENI flow logs give finer granularity — you can see exactly which pod or NAT gateway interface dropped a packet. However, ENI IDs are ephemeral (they change on node replacement), and filtering by ENI requires knowing the current ENI-to-pod mapping. VPC-level flow logs capture all traffic in the VPC and are queryable by source/destination IP, which is sufficient for every known debugging scenario in this platform. Per-ENI is a future refinement once the VPC-level baseline proves its value.

---

## 4. Files to change / create

| Path | What changes |
|------|-------------|
| `/home/user/k8-platform/terraform/base/vpc.tf` | Add `aws_cloudwatch_log_group`, `aws_iam_role`, `aws_iam_role_policy`, and `aws_flow_log` resources |
| `/home/user/k8-platform/terraform/base/outputs.tf` | Add `vpc_flow_log_group_name` output for test assertions |
| `/home/user/k8-platform/scripts/vpc-flow-grep.sh` | Create: helper that wraps the Logs Insights query for common SG-deny lookups |
| `/home/user/k8-platform/tests/unit/test_vpc_flow_logs.sh` | Create: unit test asserting flow log resources are present and correctly configured |

No files in `terraform/management/`, `crossplane/`, `argocd/`, `policies/`, or
`.github/workflows/` are touched by this spec.

---

## 5. Implementation notes

### 5.1 IAM role for flow log delivery

VPC flow logs require a role that the VPC service principal (`vpc-flow-logs.amazonaws.com`) can assume. The trust policy and permissions policy follow the AWS documentation canonical form exactly — no deviations.

```hcl
resource "aws_iam_role" "vpc_flow_log" {
  name               = "${local.name_prefix}-vpc-flow-log"
  assume_role_policy = data.aws_iam_policy_document.vpc_flow_log_trust.json

  tags = { Name = "${local.name_prefix}-vpc-flow-log-role" }
}

data "aws_iam_policy_document" "vpc_flow_log_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "vpc_flow_log" {
  name   = "flow-log-delivery"
  role   = aws_iam_role.vpc_flow_log.id
  policy = data.aws_iam_policy_document.vpc_flow_log_permissions.json
}

data "aws_iam_policy_document" "vpc_flow_log_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    # Scope to this log group only — no wildcard on the resource.
    resources = [
      "${aws_cloudwatch_log_group.vpc_flow_log.arn}",
      "${aws_cloudwatch_log_group.vpc_flow_log.arn}:*",
    ]
  }
}
```

Scoping the IAM policy resource to the specific log group ARN rather than
`arn:aws:logs:*:*:*` follows the principle of least privilege stated in
`AGENTS.md §10` ("nothing sensitive is ever committed") and
`ai/DESIGN.md §5.1` (IRSA roles scoped to minimum permissions).

The `aws_iam_role` resource uses a predictable name (`${local.name_prefix}-vpc-flow-log`)
so it is idempotent across account rotations — no account ID in the name,
consistent with `AGENTS.md §8.1`.

### 5.2 CloudWatch log group

```hcl
resource "aws_cloudwatch_log_group" "vpc_flow_log" {
  name              = "/aws/vpc/${local.name_prefix}/flow-logs"
  retention_in_days = 7

  tags = { Name = "${local.name_prefix}-vpc-flow-logs" }
}
```

Seven-day retention is the project requirement from brainstorm A1-004. It
aligns with the other CloudWatch log groups in the platform (EKS control-plane
logs also use 7 days in `terraform/management/`). Retention is enforced by
Terraform so each fresh account gets the same policy without manual console
clicks.

The log group name follows the AWS-conventional `/aws/vpc/<name>/flow-logs`
pattern, which is the path the Logs Insights console auto-suggests.

### 5.3 Flow log resource

```hcl
resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"        # See §3 — REJECT-only trade-off
  iam_role_arn    = aws_iam_role.vpc_flow_log.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_log.arn

  tags = { Name = "${local.name_prefix}-vpc-flow-log" }
}
```

`traffic_type = "ALL"` is chosen over `REJECT` — see the §3 discussion for
the full trade-off. The log destination is the CloudWatch Logs ARN (not an
S3 ARN), which controls the delivery path.

### 5.4 Output variable

```hcl
output "vpc_flow_log_group_name" {
  description = "CloudWatch log group name for VPC flow logs"
  value       = aws_cloudwatch_log_group.vpc_flow_log.name
}
```

The output is used in the integration test (`tests/integration/`) to
confirm the log group exists in the live account without hardcoding the
log group name in the test script. Consistent with `AGENTS.md §8.1`
(never hardcode account-derived values).

### 5.5 Helper script: `scripts/vpc-flow-grep.sh`

Cross-review A4→A1-004 noted that the most expensive part of diagnosing
a network issue is not finding the log group — it is remembering the
Logs Insights query schema. The helper encodes the two most useful queries:
all REJECT records for a source IP, and all traffic between two IPs.

Invocation shape:

```
vpc-flow-grep.sh reject <src-ip>           # all REJECTs from src
vpc-flow-grep.sh pair   <src-ip> <dst-ip>  # all flows between src and dst
```

The log group name is read from `terraform output -raw vpc_flow_log_group_name`
(no hardcoded account-specific value; consistent with `AGENTS.md §8.1`). The
`START_TIME` environment variable defaults to `-1h` and accepts any value
`date -d` understands.

Internally the script calls `aws logs start-query`, polls `get-query-results`
in a 2-second loop, and prints results as tab-separated values. Both Logs
Insights queries use the field set from the default flow log format v2:
`@timestamp, srcAddr, dstAddr, dstPort, protocol, action, bytes`.

The script is read-only and diagnostic. It follows the `scripts/` convention
established for `scripts/diag-component.sh` and similar diagnostic helpers.

### 5.6 Dependency and ordering

`aws_flow_log.main` depends on both the log group and the IAM role. Terraform
resolves these automatically via implicit references (`aws_vpc.main.id`,
`aws_iam_role.vpc_flow_log.arn`, `aws_cloudwatch_log_group.vpc_flow_log.arn`).
No explicit `depends_on` is needed.

The IAM role policy document references `aws_cloudwatch_log_group.vpc_flow_log.arn`
before the log group exists at plan time. Terraform handles this correctly
because it resolves resource references within a single module in dependency
order.

### 5.7 Sandbox compliance

VPC flow logs incur CloudWatch Logs ingestion costs. At the Pluralsight
sandbox scale — one VPC, ≤9 EC2 instances, two AZs, NAT gateway pair,
EKS control plane — estimated daily ingestion is under 100 MB. CloudWatch
Logs pricing is $0.50 per GB ingested; at 100 MB/day this is $0.005/day,
well within any sandbox budget. The 7-day retention cap bounds total storage.
No service not listed in `ai/aws-test-environment-limitations.md §Safe-by-default`
is used: CloudWatch, Logs, and IAM roles are all explicitly listed as safe.

---

## 6. Tests required

Per `AGENTS.md §6.1` (maximal coverage):

| Layer | File | Assertion |
|-------|------|-----------|
| Unit | `tests/unit/test_vpc_flow_logs.sh` | Parse `terraform/base/vpc.tf` with `grep` / `hcl2` and assert: `aws_flow_log` resource exists; `traffic_type = "ALL"`; `log_destination` references the CloudWatch log group (not an S3 ARN); `aws_cloudwatch_log_group` has `retention_in_days = 7`; IAM role policy resources are present and reference the log group ARN, not a wildcard |
| Unit | `tests/unit/test_vpc_flow_logs.sh` | Assert `vpc_flow_log_group_name` appears in `terraform/base/outputs.tf` |
| Unit | `tests/unit/test_vpc_flow_logs.sh` | Assert `scripts/vpc-flow-grep.sh` is executable and passes `bash -n` (syntax check) |
| Integration | `tests/integration/13_vpc_flow_logs.sh` | After `terraform apply`, query `aws logs describe-log-groups` and assert the log group exists with `retentionInDays == 7`; query `aws ec2 describe-flow-logs` and assert `FlowLogStatus == ACTIVE` for the platform VPC |

The unit test runs as part of `tests/unit/run.sh` without any AWS credentials
and completes in under 2 seconds.

The integration test is opt-in (flagged in `run.sh` as requiring live AWS),
consistent with the convention for `tests/integration/`.

Per `AGENTS.md §6.4`, when the implementation PR authors the test plan above,
a single adversarial-reviewer subagent must review it with the brief from
§6.4. The reviewer should specifically challenge:

- "What if the IAM role's resource-level ARN contains the log group name
  before the log group is created? Does the plan work?"
- "What if `terraform output -raw vpc_flow_log_group_name` in the helper
  script fails because state does not exist yet — does the script exit
  gracefully?"
- "Does the unit test actually catch a `REJECT`-only misconfiguration, or
  would it pass with `traffic_type = "REJECT"`?"

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

1. `test_vpc_flow_logs.sh` — `terraform validate` against `terraform/base/` passes (no schema errors introduced by the new resources).
2. `test_vpc_flow_logs.sh` — Assert that the IAM policy document does NOT contain `"*"` as a resource ARN (enforces least-privilege intent).
3. `test_vpc_flow_logs.sh` — Assert `scripts/vpc-flow-grep.sh` contains both the `reject` and `pair` subcommands and that the Logs Insights `fields` list includes `action`.
4. `test_vpc_flow_logs.sh` — Assert `aws_flow_log` is in `terraform/base/vpc.tf` and not in `terraform/management/` (the spec limits scope to base).

### Integration

1. `tests/integration/13_vpc_flow_logs.sh` — Describe flow logs via AWS CLI, confirm `FlowLogStatus = ACTIVE` and `LogGroupName` matches the Terraform output.
2. `tests/integration/13_vpc_flow_logs.sh` — Confirm the log group's `retentionInDays` is exactly 7 (not unset, not 30 — the sandbox must not accumulate unbounded log data).
3. `tests/integration/13_vpc_flow_logs.sh` — Dispatch a `ping` from one node to another's private IP (or use `kubectl exec` into a pod), wait 15 minutes for the 10-minute aggregation window to close, then query CloudWatch Logs Insights and assert at least one ACCEPT record appeared. This confirms end-to-end delivery, not just resource existence.

The 15-minute wait makes test 3 expensive; it should be run explicitly by the
implementing agent as a smoke test rather than on every CI run.

### E2E

E2E coverage is not applicable for this spec. VPC flow logs are an
infrastructure-layer observability primitive. There is no Chainsaw scenario
that naturally validates them (Chainsaw runs against a kind cluster that does
not have VPC flow logs), and the full-stack proof is the integration test
asserting delivery above. A future spec that adds a CloudWatch metric alarm
on REJECT count (brainstorm A1-005) would be the appropriate E2E hook.

---

## 8. Documentation updates

- **`ai/aws-test-environment-limitations.md` §Safe-by-default** — already lists "CloudWatch + Logs + Alarms + Dashboards + Metric Filters + Insights". No change required; VPC flow logs to CloudWatch are covered.
- **`ai/handoff.md`** — When implementation lands, add a bullet under "What was done" noting that flow logs are active and referencing `scripts/vpc-flow-grep.sh` as the query entry point. Future sessions should not spend time re-discovering the log group name.
- **`docs/operations.md`** (if it exists) — Add a "Network debugging" section with the `vpc-flow-grep.sh reject <ip>` usage pattern. Future operators should land on this runbook when diagnosing a connectivity problem, not on raw CloudWatch Logs console.
- **`AGENTS.md §8.1`** — No change required; the constraint against hardcoding account-derived values is already documented. The implementation must comply by reading the log group name via `terraform output` rather than a literal string.

---

## 9. Workflow / auto-invocation wiring

This spec is purely Terraform — it adds resources that are applied as part
of the existing `phase=base, action=apply` step in
`.github/workflows/terraform-test.yml`. No new workflow files, no new
triggers. The flow log is active for the entire lifetime of the base
environment and is destroyed automatically when `terraform destroy` runs on
the base module.

The helper script (`scripts/vpc-flow-grep.sh`) is a manual runbook tool.
It does not need wiring into CI. Future sessions invoke it interactively
when diagnosing a network issue.

---

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_vpc_flow_logs.sh` runs on
   every push via `.github/workflows/unit-tests.yml`. If the `aws_flow_log`
   resource is removed from `vpc.tf` or the retention period is changed,
   the unit test fails CI red before the PR can be reviewed.

2. **Documentation pointer** — `ai/handoff.md`'s "What was done" section
   (updated by the implementing agent) names `scripts/vpc-flow-grep.sh`.
   Any session that reads `ai/handoff.md` first (per `AGENTS.md §1`) will
   find the pointer within the first 30 lines. The brainstorm catalogue
   (`ai/brainstorming/A1-debug-tools-max-capability.md` row A1-004) also
   cross-references this spec once it is written.

3. **Adversarial-review trigger** — `AGENTS.md §6.4`'s adversarial-reviewer
   brief for any Phase 5 or Phase 6 test plan should include "confirm VPC
   flow logs are active and queryable" as a network-layer contract. Any
   plan that does not mention flow logs will be flagged by the adversarial
   reviewer as missing a diagnostic baseline.

---

## 11. Verification checklist

The implementing agent runs all of the following after authoring the code:

- [ ] `terraform validate` in `/home/user/k8-platform/terraform/base/` exits 0 with the new resources present.
- [ ] `bash tests/unit/run.sh` passes locally with no new failures.
- [ ] `tests/unit/test_vpc_flow_logs.sh` exists and all assertions pass (including the `traffic_type`, `retention_in_days`, and no-wildcard-ARN checks).
- [ ] `bash -n scripts/vpc-flow-grep.sh` exits 0 (syntax valid). `shellcheck scripts/vpc-flow-grep.sh` exits 0 or documents any suppressed warnings in the script.
- [ ] `scripts/vpc-flow-grep.sh` is executable (`chmod +x`).
- [ ] `terraform/base/outputs.tf` contains a `vpc_flow_log_group_name` output.
- [ ] After `terraform apply` on the base module: `aws ec2 describe-flow-logs --filter Name=resource-id,Values=$(terraform -chdir=terraform/base output -raw vpc_id)` returns a record with `FlowLogStatus = ACTIVE`.
- [ ] After `terraform apply`: `aws logs describe-log-groups --log-group-name-prefix /aws/vpc/k8-platform` returns the log group with `retentionInDays = 7`.
- [ ] `scripts/vpc-flow-grep.sh reject 10.0.0.1` runs without error (it may return zero results — that is acceptable; the test is that the script exits 0 and the query submits successfully).
- [ ] `terraform destroy` on the base module removes the flow log, IAM role, and log group without errors (confirm with `aws ec2 describe-flow-logs` returning empty after destroy).

---

## 12. Rollout notes

- **Backward compatibility** — Flow logs are additive. No existing resource is modified; the VPC, subnets, NAT gateways, and route tables are untouched. A `terraform plan` against an account that already has the base module applied will show exactly 4 resources to add: `aws_cloudwatch_log_group.vpc_flow_log`, `aws_iam_role.vpc_flow_log`, `aws_iam_role_policy.vpc_flow_log`, `aws_flow_log.main`.

- **Audit before merge** — The only audit required is confirming `tests/unit/test_vpc_flow_logs.sh` passes in `tests/unit/run.sh`. No existing tests are broken by this change.

- **Sandbox compliance** — CloudWatch Logs is listed as safe in `ai/aws-test-environment-limitations.md`. No new region, no new instance, no IAM user. The IAM role is an additional role; the sandbox does not constrain IAM role counts. VPC flow log delivery costs are negligible at sandbox scale (see §5.7).

- **Account rotation** — On every fresh account, `terraform apply` on base creates the log group and flow log from scratch. The 7-day retention is enforced by the Terraform resource, not by a console setting. Consistent with `AGENTS.md §8.1`.

- **Coordination with in-flight branches** — No current in-flight branch modifies `terraform/base/vpc.tf` or `terraform/base/outputs.tf`. This spec is orthogonal to the Crossplane 2.3.0 work (PRs #72, #74) and to any Phase 2 branch currently open.

- **Branch sequencing** — This spec is Tier C and does not block any Phase 2, 3, or 4 work. It can land in any order relative to other base-module improvements. Suggested: implement after Bug 3 (slow provider-family-aws) is resolved, since that bug currently blocks Phase 2 bring-up and should be the active focus.

---

## 13. Estimated effort

**S** (small, ≤1 hour).

- Terraform resources (`vpc.tf`, `outputs.tf`): ~20 minutes. The HCL is
  standard; the IAM policy document shape for VPC flow logs is documented
  by AWS and unchanged since flow logs launched.
- Helper script (`scripts/vpc-flow-grep.sh`): ~20 minutes. The Logs
  Insights query schema is fixed; the polling loop is a standard pattern
  already present in other scripts.
- Unit test (`tests/unit/test_vpc_flow_logs.sh`): ~20 minutes. Four
  assertions, all `grep` or `hcl2json | jq` patterns.
- Integration test stub (`tests/integration/13_vpc_flow_logs.sh`): ~15
  minutes. Two AWS CLI describe calls with `jq` assertions.
- Docs update (`ai/handoff.md` bullet + `docs/operations.md` snippet): ~10
  minutes.
- Adversarial review (`AGENTS.md §6.4`): ~15 minutes for a single subagent
  on a small-scope addition.

Total: approximately 1.5 hours including the adversarial review cycle. The
rollout-audit cost is near zero — no existing files are modified and the
new unit test covers only new resources.
