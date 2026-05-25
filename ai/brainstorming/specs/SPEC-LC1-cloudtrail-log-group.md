# SPEC-LC1 — CloudTrail trail to dedicated CloudWatch log group, 7-day retention

Status: DRAFT (spec only — no implementation in this PR)
Branch: pending
Brainstorm ID: A1-005
Tier: C (observability foundation — set up once, query forever)
Owner: next agent picking up observability work

---

## 1. Summary

Add a CloudTrail trail and a dedicated CloudWatch Logs log group to
`terraform/base/cloudtrail.tf` (new file). The trail sends every
management-API event in the account to the log group; the log group
retains events for 7 days and then discards them automatically,
staying within Pluralsight sandbox caps. A companion IAM role grants
CloudTrail permission to write to CloudWatch Logs. The resulting log
group becomes the data source for SPEC-S8's Logs Insights saved
queries (A1-006 and A1-007) and for any future "what did the agent
actually do" post-mortem. Without this foundation, IRSA and API
debugging requires hand-assembling `aws cloudtrail lookup-events`
calls that cover only the last 90 days and return at most 50 events
per page — a slow, lossy path compared to a single Logs Insights query.
Part of `larger-list-preferences.md` Tier C, item C1.

---

## 2. Retro pain killed

- **PR #66 IRSA SA-name debug loop** (`retrospective/2026-05-25-70.md`
  Phase 2). The root cause — `AssumeRoleWithWebIdentity` rejecting
  a hash-suffixed SA subject — took a 166 KB diagnostic workflow log
  and a dedicated subagent extraction loop to identify. A CloudTrail
  log group pointed at by the A1-006 Logs Insights query would have
  surfaced the rejected OIDC subject (`provider-family-aws-24aaab54a3a0`)
  in one query execution, before any manual IAM traversal.

- **PR #68 provider Deployment still on wrong SA**
  (`retrospective/2026-05-25-70.md`, Phase 2, last paragraph of the
  phase). Confirmation that the provider pod was still using the old
  hash-suffixed service account required a second subagent extraction
  against a 170 KB log. A running CloudTrail trail would have shown
  the continued `AssumeRoleWithWebIdentity` failure stream — and its
  eventual silence after the Deployment was restarted — as a two-row
  Logs Insights table.

- **ExternalDNS IRSA `route53:ListHostedZones` missing**
  (`retrospective/2026-05-23-36.md` line 54). The missing IAM action
  "started fine, then every reconcile loop logged `AccessDenied` —
  caught only after I added pod-log dumps to the failure path in
  the e2e step." CloudTrail would have logged the `ListHostedZones`
  `AccessDenied` event immediately; Logs Insights query A1-006 (once
  it lands with SPEC-S8) would have surfaced it without needing to
  instrument the e2e step.

- **"What did the agent actually do" question has no answer without
  CloudTrail** (`larger-list-preferences.md` §C1). Every debug session
  that reached `aws iam get-role` or `aws sts get-caller-identity`
  to reconstruct what happened is a session that would have been
  shorter with a pre-existing CloudTrail log group. The trail makes
  the account's API call history queryable from the moment of apply
  instead of only from the moment the agent remembers to turn it on.

- **`ai/aws-test-environment-limitations.md` lists CloudTrail as an
  explicitly safe service** for this sandbox. The risk of not having
  it exceeds the risk of the sandbox cap violation of having it.

---

## 3. Out of scope

- **S3 bucket for CloudTrail archive.** CloudTrail can deliver events
  to both a CloudWatch log group and an S3 bucket simultaneously.
  This spec uses only the CloudWatch path. The Pluralsight sandbox
  account is ephemeral (session-lifetime) and S3 retention past
  the session is meaningless; the 7-day CloudWatch window covers
  the entire typical session lifetime. An S3 archive would add a
  bucket, a bucket policy, and a data lifecycle rule with zero
  diagnostic payoff inside a sandbox session.

- **CloudTrail data events (S3 object reads/writes, Lambda invokes,
  DynamoDB API calls).** Management events only. Data events increase
  event volume by several orders of magnitude in a busy account and
  would exhaust the 7-day log group quickly. The IRSA and API failure
  use cases need management events (STS, IAM, EC2, EKS, Route53) —
  not data-plane events.

- **Enabling EKS control-plane logging** (SPEC-LC2, brainstorm A1-003).
  That spec enables the EKS `audit`, `api`, `authenticator`,
  `controllerManager`, and `scheduler` log types. Those logs land
  in a separate AWS-managed log group (`/aws/eks/<cluster>/cluster`),
  not in the CloudTrail log group this spec creates. SPEC-S8 depends
  on both; they are separate infrastructure items.

- **Saved Logs Insights query definitions.** Those are SPEC-S8 (A1-006,
  A1-007). This spec creates the log group; SPEC-S8 creates the
  `aws_cloudwatch_query_definition` resources that query it.

- **CloudWatch metric filters or alarms on CloudTrail events.** The
  alarm use case (e.g. alert on root-account API calls) is a separate
  observability spec. This spec delivers the log group and the trail;
  everything built on top of them is follow-on work.

### Considered and rejected

- **`aws_cloudtrail_event_data_store` (Lake) instead of a classic trail.**
  CloudTrail Lake provides a SQL query interface but requires explicit
  enablement of the CloudTrail Lake feature and incurs per-event
  ingestion cost that is not listed as sandbox-safe in
  `ai/aws-test-environment-limitations.md`. Classic trail →
  CloudWatch Logs is the tested-safe path and sufficient for the
  Logs Insights use case.

- **Placing the resources in `terraform/management/` instead of
  `terraform/base/`.** CloudTrail is an account-level service; it
  logs all management API calls regardless of which EKS cluster or
  Crossplane resource generated them. The base module is the right
  owner because it manages account-wide shared infrastructure
  (VPC, Route53, ACM, Cognito). The management module applies
  after the base module; placing the trail there would leave a gap
  during the base-only apply phase.

---

## 4. Files to change / create

**Create:**

| Path | What |
|------|------|
| `/home/user/k8-platform/terraform/base/cloudtrail.tf` | New file. `aws_cloudwatch_log_group`, `aws_cloudtrail`, `aws_iam_role`, `aws_iam_role_policy` resources plus `data.aws_caller_identity.current` and `data.aws_iam_policy_document` sources. |
| `/home/user/k8-platform/tests/unit/test_cloudtrail_tf.sh` | Unit test assertions (see §6). |

**Modify:**

| Path | What |
|------|------|
| `/home/user/k8-platform/terraform/base/outputs.tf` | Add `cloudtrail_log_group_name` and `cloudtrail_log_group_arn` outputs so SPEC-S8's management module can consume them without hardcoding. |
| `/home/user/k8-platform/tests/unit/run.sh` | Wire in `test_cloudtrail_tf.sh` (one line, same convention as existing tests). |

No changes to `crossplane/`, `argocd/`, `clusters/`, `platform-services/`,
`policies/`, `scripts/`, `terraform/management/`, or any workflow file.

---

## 5. Implementation notes

### 5.1 CloudWatch log group

```hcl
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/k8-platform/cloudtrail"
  retention_in_days = 7

  tags = {
    Component = "cloudtrail"
  }
}
```

`retention_in_days = 7` is the deliberate sandbox-safety choice: events
are retained for the full typical session window and are then purged
automatically, preventing unbounded storage accumulation across
rotations. CloudWatch Logs bills per ingested GB and per stored GB-month;
7-day retention keeps both costs within sandbox tolerance.

The log group name `/k8-platform/cloudtrail` is deterministic and does
not embed an account ID, per `AGENTS.md §8.1`.

### 5.2 IAM role for CloudTrail → CloudWatch Logs delivery

CloudTrail must be granted `logs:CreateLogStream` and `logs:PutLogEvents`
on the target log group. The role's trust policy allows only the
`cloudtrail.amazonaws.com` service principal.

```hcl
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "cloudtrail_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.cloudtrail.arn}:*",
    ]
  }
}

resource "aws_iam_role" "cloudtrail_cw" {
  name               = "${local.name_prefix}-cloudtrail-cw"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume.json
}

resource "aws_iam_role_policy" "cloudtrail_cw" {
  name   = "cloudwatch-delivery"
  role   = aws_iam_role.cloudtrail_cw.id
  policy = data.aws_iam_policy_document.cloudtrail_logs.json
}
```

Inline policy (`aws_iam_role_policy`) rather than a standalone
`aws_iam_policy` because the policy is single-use and does not need
to be attachable to other roles.

### 5.3 CloudTrail trail

```hcl
resource "aws_cloudtrail" "main" {
  name                          = "${local.name_prefix}-trail"
  s3_bucket_name                = null   # No S3 delivery — see §3
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = false  # Only relevant for S3 delivery

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cw.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # No data_resource blocks — management events only (see §3).
  }
}
```

`include_global_service_events = true` ensures that STS API calls
(AssumeRole, AssumeRoleWithWebIdentity) are captured even though they
hit a global endpoint. Without this flag, the IRSA failure use case —
the primary motivation for this spec — would produce no CloudTrail events.

`is_multi_region_trail = false` keeps the trail scoped to the deployed
region (us-east-1 or us-west-2). The sandbox runs in exactly one region
per session (`ai/aws-test-environment-limitations.md`); a multi-region
trail would duplicate global-service events and adds no value here.

`s3_bucket_name = null` is explicit to make the "no S3 archive" choice
visible in code review; the AWS provider does not require this field but
an empty value documents the decision better than an absent field.

### 5.4 Outputs

```hcl
output "cloudtrail_log_group_name" {
  description = "Name of the CloudTrail CloudWatch log group (consumed by SPEC-S8 observability.tf)"
  value       = aws_cloudwatch_log_group.cloudtrail.name
}

output "cloudtrail_log_group_arn" {
  description = "ARN of the CloudTrail CloudWatch log group"
  value       = aws_cloudwatch_log_group.cloudtrail.arn
}
```

These outputs allow SPEC-S8's `terraform/management/observability.tf`
to resolve the log group name from base module state rather than
hardcoding the string. The implementing agent for SPEC-S8 passes
the name through a variable or a remote state data source.

### 5.5 Idempotency and failure modes

CloudTrail trails have a per-account, per-region name uniqueness
constraint. If a prior session left a trail named
`k8-platform-trail` in a stale state, `terraform apply` will fail
with `TrailAlreadyExistsException`. The correct remediation is
`terraform import aws_cloudtrail.main k8-platform-trail` to bring
the existing trail under management, then re-apply.

The `aws_cloudwatch_log_group` resource is idempotent: if the group
already exists (e.g. a prior session's apply that was never torn down),
Terraform imports it silently via the name match.

The IAM role follows the `name = "${local.name_prefix}-cloudtrail-cw"`
pattern used by all other roles in the base module. If the account
was rotated between sessions, the old role is gone and Terraform
creates a new one cleanly.

### 5.6 Cross-references

- SPEC-S8 (`SPEC-S8-logs-insights-queries.md` §3 and §5.1) explicitly
  depends on this spec's log group being present before its
  `aws_cloudwatch_query_definition` resources are applied. The
  implementing agent for SPEC-S8 must confirm this spec is applied
  first.
- SPEC-C1's post-apply `terraform plan -detailed-exitcode` step will
  catch any out-of-band change to the trail or log group retention
  setting made in the AWS Console between sessions.
- `larger-list-preferences.md` §C1 is the source authority for the
  prioritization and effort estimate.

---

## 6. Tests required

Per `AGENTS.md §6.1` (maximal coverage) — the applicable layers for a
Terraform resource addition are unit (HCL shape) and integration
(resources actually created in AWS).

### Unit (required, runs on every push)

`/home/user/k8-platform/tests/unit/test_cloudtrail_tf.sh` — asserts:

1. `terraform validate` in `terraform/base/` exits 0 with
   `cloudtrail.tf` present (HCL syntax is valid).
2. `grep -c 'aws_cloudtrail' terraform/base/cloudtrail.tf` returns
   at least `1` (trail resource is declared).
3. `grep 'aws_cloudwatch_log_group' terraform/base/cloudtrail.tf`
   exits 0 (log group resource is declared).
4. `grep 'retention_in_days.*=.*7' terraform/base/cloudtrail.tf`
   exits 0 (7-day retention is set — the sandbox-safety invariant).
5. `grep 'include_global_service_events.*=.*true' terraform/base/cloudtrail.tf`
   exits 0 (STS/global events are captured — required for IRSA
   AssumeRoleWithWebIdentity events).
6. `grep 'cloudtrail_log_group_name' terraform/base/outputs.tf`
   exits 0 (log group name is exported for SPEC-S8).
7. `grep -E '[0-9]{12}' terraform/base/cloudtrail.tf` exits
   non-zero (no hardcoded account IDs, per `AGENTS.md §8.1`).
8. `grep 's3_bucket_name' terraform/base/cloudtrail.tf` exits 0
   AND `grep 's3_bucket_name.*=.*null' terraform/base/cloudtrail.tf`
   exits 0 (the no-S3-archive decision is explicit in code).

These are pure-local lint assertions; no AWS credentials are required.
Run as part of `tests/unit/run.sh`.

### Adversarial subagent review

Per `AGENTS.md §6.4`, the implementing PR must spawn an adversarial-
reviewer subagent. Minimum questions to address:

- "Does `include_global_service_events = true` actually capture
  `AssumeRoleWithWebIdentity` events from the OIDC endpoint, or are
  those delivered to the us-east-1 global trail only?"
- "If the base module apply fails partway through, with the log group
  created but the trail not yet created — does the next apply
  recover cleanly or produce a duplicate log group?"
- "Does the GitHub Actions IAM role already have
  `cloudtrail:CreateTrail`, `cloudtrail:StartLogging`,
  `logs:CreateLogGroup`, and `iam:CreateRole` — or do these need
  to be added to the CI role's policy?"
- "What happens if `aws_cloudtrail.main` tries to deliver to the log
  group before the IAM role policy has propagated? Does the trail
  start in a failed-delivery state or retry silently?"

Adopt every concrete suggestion or document a one-line dismissal in
the PR body.

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast (<10 s each). Name pattern: `tests/unit/test_cloudtrail_tf.sh`.

1. **HCL syntax** — `terraform validate` exits 0 (catches structural
   errors in the new file that `grep`-based assertions can miss).
2. **Retention hardcoded to 7** — assert `retention_in_days = 7` is
   literal (not a variable), preventing accidental promotion to a
   longer window that violates sandbox caps.
3. **Global service events enabled** — assert
   `include_global_service_events = true`; without it the STS
   AssumeRoleWithWebIdentity calls that SPEC-S8 queries will not
   appear in the log group.
4. **No account-ID literals** — mirrors the SPEC-B5 account-ID lint,
   applied locally to `cloudtrail.tf`.
5. **Output presence** — `cloudtrail_log_group_name` exists in
   `outputs.tf` (prevents SPEC-S8 from failing its plan because the
   output it depends on is missing).

### Integration

Against a live base module apply in the sandbox. Name pattern:
`tests/integration/NN_cloudtrail_live.sh`.

1. **Trail exists in AWS** — after `terraform apply`,
   `aws cloudtrail describe-trails --include-shadow-trails false`
   returns exactly one trail named `k8-platform-trail` with
   `CloudWatchLogsLogGroupArn` populated.
2. **Log group exists and has correct retention** —
   `aws logs describe-log-groups --log-group-name-prefix /k8-platform/cloudtrail`
   returns one group with `retentionInDays` equal to `7`.
3. **Trail is logging** —
   `aws cloudtrail get-trail-status --name k8-platform-trail`
   returns `IsLogging: true`.
4. **CloudTrail writes arrive within 15 minutes** — call
   `aws sts get-caller-identity` (a management API event), wait
   up to 15 minutes, then run
   `aws logs filter-log-events --log-group-name /k8-platform/cloudtrail --filter-pattern "GetCallerIdentity"`
   and assert at least one event is returned. This confirms the
   IAM role, log group ARN suffix `:*`, and trail configuration
   are wired correctly end-to-end.
5. **Post-apply drift is zero** — `terraform plan -detailed-exitcode`
   immediately after apply exits 0 (SPEC-C1 contract).

Integration tests are opt-in and are run during the base phase
bring-up; they are not part of the standard unit suite.

### E2E

Not applicable in the chainsaw sense. CloudTrail is an account-level
AWS service, not a Kubernetes resource. There is no XRD, Composition,
or Claim to apply. The integration layer above covers the full
create-verify-plan round-trip.

A future scenario could instrument a deliberate IRSA misconfiguration,
wait for CloudTrail delivery lag (typically 5–15 minutes), then run
the A1-006 Logs Insights query and assert it returns at least one row.
That is a follow-on spec (SPEC-S8 §7 E2E section sketches this).

---

## 8. Documentation updates

- **`ai/handoff.md` NEW SESSION QUICKSTART** — add a preflight check
  under "diagnose" noting that the CloudTrail log group
  `/k8-platform/cloudtrail` is the first read for any IAM or API
  failure. One sentence: "CloudTrail events land in
  `/k8-platform/cloudtrail` with 7-day retention; use the SPEC-S8
  Logs Insights saved queries to surface failures before doing any
  manual IAM traversal."

- **`ai/aws-test-environment-limitations.md` "Safe-by-default services"**
  — CloudTrail is already listed. No change needed, but the implementing
  agent should verify the entry is present before merging the PR.

- **`ai/brainstorming/specs/larger-list-preferences.md` §C1** —
  mark as `Status: IMPLEMENTED` once the PR lands (one-word edit).

- **`AGENTS.md` §8.1** — the existing rule says not to hardcode account-
  derived values. The `cloudtrail.tf` implementation must be cited as
  a positive example of the data-source pattern
  (`data.aws_caller_identity.current`) that replaces hardcoded IDs. One
  sentence addition if the section is updated.

No new docs file. No ADR required.

---

## 9. Workflow / auto-invocation wiring

The new resources are applied as part of the standard
`apply-and-verify base` workflow dispatch (`.github/workflows/terraform-test.yml`,
`phase=base`). No new workflow step is required; the base apply already
runs `terraform apply` in `terraform/base/`.

The trail begins delivering events automatically when `IsLogging: true`
after apply. There is no agent action required to activate it.

SPEC-C1's post-apply `terraform plan -detailed-exitcode` step (already
wired into `terraform-test.yml` per that spec) will catch any out-of-band
change to the trail or log group. No additional wiring is needed.

---

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_cloudtrail_tf.sh`
   asserts that `retention_in_days = 7` and
   `include_global_service_events = true` are both literally present
   in `cloudtrail.tf`. If either is removed or changed, `tests/unit/run.sh`
   turns red and blocks any CI push. The 7-day retention invariant
   is load-bearing for sandbox compliance; the global-events flag is
   load-bearing for the IRSA use case. Both are enforced at authoring
   time, not just at apply time.

2. **Documentation pointer** — `ai/handoff.md` QUICKSTART (updated
   per §8) points agents to the log group name before any manual
   IAM traversal. SPEC-S8 §3 explicitly states "the implementing
   agent must land SPEC-LC1 first", making the dependency visible
   in the first file an agent reads when picking up SPEC-S8.

3. **Adversarial-review trigger** — `AGENTS.md §6.4` checklist item
   "does the implementation produce observable evidence that a future
   agent can verify without re-authoring the lookup?" directly surfaces
   this spec: the log group must be queryable to fulfill SPEC-S8's
   IRSA failure diagnosis promise. If the trail is not delivering or
   `include_global_service_events` is false, the query returns zero
   rows on a failing cluster — an ambiguous signal. The adversarial
   reviewer should probe this exact ambiguity.

---

## 11. Verification checklist

The implementing agent runs these checks after coding the spec:

- [ ] `terraform validate` in `terraform/base/` exits 0.
- [ ] `tests/unit/test_cloudtrail_tf.sh` exists, is wired into
      `tests/unit/run.sh`, and passes locally without AWS credentials.
- [ ] `terraform plan` (base module, against the sandbox account) shows
      exactly the three new resources: `aws_cloudwatch_log_group.cloudtrail`,
      `aws_iam_role.cloudtrail_cw`, `aws_iam_role_policy.cloudtrail_cw`,
      and `aws_cloudtrail.main` — four resources total, no unexpected
      changes to existing resources.
- [ ] `terraform apply` completes; `terraform plan -detailed-exitcode`
      immediately after exits 0 (SPEC-C1 post-apply drift contract).
- [ ] `aws cloudtrail describe-trails --include-shadow-trails false`
      returns one trail with `Name: k8-platform-trail` and
      `CloudWatchLogsLogGroupArn` set (non-empty).
- [ ] `aws cloudtrail get-trail-status --name k8-platform-trail`
      returns `IsLogging: true`.
- [ ] `aws logs describe-log-groups --log-group-name-prefix /k8-platform/cloudtrail`
      returns one group with `retentionInDays: 7`.
- [ ] `terraform output cloudtrail_log_group_name` returns
      `/k8-platform/cloudtrail` (non-empty, no account ID embedded).
- [ ] Wait up to 15 minutes; run
      `aws logs filter-log-events --log-group-name /k8-platform/cloudtrail --max-items 1`
      and confirm at least one event is present (trail is actively
      delivering).
- [ ] Adversarial subagent review (§6) completed; findings either
      adopted or dismissed in the PR body.
- [ ] PR description notes that SPEC-S8 depends on this apply being
      present in the target account before the management module apply
      that creates the Logs Insights query definitions.

---

## 12. Rollout notes

- **Backward compatibility** — additive Terraform resources only.
  No existing resource is modified. No existing test breaks.
  `tests/unit/run.sh` gains one new invocation line; the new test
  makes no AWS calls and passes without credentials.

- **Sandbox compliance** — CloudTrail is listed as a safe service in
  `ai/aws-test-environment-limitations.md`. The log group retention
  is explicitly capped at 7 days. No EC2 instances, EBS volumes, or
  VPC resources are created. The IAM role is a new role (not a new
  IAM user, which is blocked). Total new resource count: 4 Terraform
  resources, all within sandbox limits.

- **IAM permission gap risk** — the GitHub Actions OIDC role may
  not yet have `cloudtrail:CreateTrail`, `cloudtrail:StartLogging`,
  `cloudtrail:PutEventSelectors`, `logs:CreateLogGroup`,
  `logs:PutRetentionPolicy`, `iam:CreateRole`, `iam:PutRolePolicy`,
  and `iam:PassRole` in its policy. The implementing agent must audit
  the CI role's permissions before the first apply and add any missing
  actions. `iam:PassRole` is particularly easy to miss; CloudTrail
  requires it to bind the delivery role.

- **TrailAlreadyExistsException on re-apply** — if a prior sandbox
  session left an unmanaged trail, `terraform apply` will error. The
  fix is `terraform import aws_cloudtrail.main <trail-name>` before
  applying. Document this in the PR if it occurs.

- **Coordination with in-flight branches** — this spec targets
  `terraform/base/` exclusively. Any in-flight branch touching
  `terraform/base/` should merge or rebase before this branch to
  avoid conflict on the base module. SPEC-S8 must stack on top of
  this spec's branch (it reads `cloudtrail_log_group_name` from
  base outputs).

- **Branch sequencing** — per `larger-list-preferences.md` Tier C
  ordering, C1 (this spec) must land before C2 (EKS logging, SPEC-LC2)
  and before SPEC-S8. C3 (VPC flow logs) is independent.

---

## 13. Estimated effort

**S** (small — under 1 hour).

- Authoring `terraform/base/cloudtrail.tf`: ~20 minutes. Four
  resource blocks and two data sources; the HCL shapes are given
  in §5 and need only minor formatting.
- Updating `terraform/base/outputs.tf`: ~5 minutes. Two output blocks.
- Authoring `tests/unit/test_cloudtrail_tf.sh` and wiring it into
  `tests/unit/run.sh`: ~15 minutes. Eight assertions, all
  grep/terraform-validate level.
- IAM permission audit for the CI role: ~10 minutes. Check the
  existing role policy against the list in §12.
- Documentation sentence-level edits (§8): ~10 minutes.
- Adversarial review (§6) + adoption: ~15 minutes given the
  narrow scope.

Total realistic implementation time: 60–75 minutes. Break-even is
the first bring-up session that encounters an IRSA or API failure
and has a queryable CloudTrail log group instead of a 90-day
`lookup-events` pagination loop. Given the frequency of IRSA issues
documented in the retrospectives (three in a single session, PR #66,
#67, #68), break-even is essentially guaranteed on the next phase
bring-up.
