# SPEC-S8 — CloudWatch Logs Insights saved queries: IRSA failure digest (A1-006) + EKS RBAC deny digest (A1-007)

Status: DRAFT (spec only — no implementation in this PR)
Brainstorm IDs: A1-006, A1-007
Tier: S (immediate return; unlocked by Tier C foundations)
Owner: next agent picking up observability work

---

## 1. Summary

Add two CloudWatch Logs Insights saved queries as Terraform
`aws_cloudwatch_query_definition` resources in
`terraform/management/observability.tf` (new file). Query A1-006
targets the CloudTrail log group and surfaces every
`AssumeRoleWithWebIdentity` failure from the last hour, grouped by
IAM role ARN and OIDC subject — the canonical IRSA-misconfiguration
signature. Query A1-007 targets the EKS control-plane audit log
group and surfaces every authorization denial from the last hour,
grouped by user, group, verb, and resource — RBAC misconfiguration
visible in five seconds. Both queries are deep-linkable from the
AWS Console and from CI scripts. This spec depends on SPEC-LC1
(CloudTrail → CloudWatch log group, A1-005) and SPEC-LC2 (EKS
control-plane logging enabled, A1-003); neither query has a usable
log group without those foundations in place.

---

## 2. Retro pain killed

- **PR #66 IRSA debug loop** — the SA-name vs. trust-doc mismatch
  was found by hand-authoring `aws iam get-role` queries inside the
  PR debug iteration. A1-006 would have surfaced the exact OIDC
  subject that was rejected in CloudTrail before any manual IAM
  traversal. SPEC-A3 §2 records the same pain; A1-006 is the
  post-hoc CloudTrail read that makes the ad-hoc lookup unnecessary.

- **PR #68 provider Deployment debug** — confirming the wrong
  service account was in use required ad-hoc pod-log grepping.
  A1-006 would have shown the `AssumeRoleWithWebIdentity` failure
  with the rejected subject immediately, eliminating that loop.

- **`ai/handoff.md` "Behavioral rule additions"** — *"It applied
  successfully ≠ the change reached the cluster."* A1-006 is an
  independent post-apply signal: failures drop to zero when IRSA
  wiring is correct. Zero rows is affirmative evidence, not noise.

- **EKS RBAC denials diagnosed by guess** — every session touching
  ClusterRoleBindings required a chainsaw retry loop or `kubectl
  auth can-i` walk. A1-007 exposes the full deny record (user,
  group, verb, resource, namespace) in one query, eliminating the
  guessing. `larger-list-preferences.md` §S8 explicitly records
  that without EKS audit logging every RBAC debug "becomes a guess."

---

## 3. Out of scope

- **Creating the CloudTrail trail or CloudWatch log group.** That
  is SPEC-LC1 (A1-005). This spec assumes SPEC-LC1 has run and
  the CloudTrail log group ARN is resolvable.

- **Enabling EKS control-plane logging.** That is SPEC-LC2
  (A1-003). The `audit` log type must be in `enabled_cluster_log_types`
  for A1-007 to have events. The implementing agent must confirm
  SPEC-LC2 is applied before testing this spec.

- **Alarm creation on top of saved queries.** CloudWatch metric
  filters or composite alarms are a follow-on; scope here is the
  saved query definitions only.

- **Dashboard widgets.** SPEC-LC1 §C6 (dashboards, A1-014..A1-016)
  is a separate Tier C item; it should reference these query names
  once both specs land.

- **`irsa-failure-quick-quote.sh` helper script.** Brainstorm
  comment A4→A1-006 proposes this script; it is a follow-on that
  invokes the saved query. This spec delivers the Terraform-managed
  definitions the helper would reference.

### Considered and rejected

- **Inline bash in `phase-2-diagnose.yml` instead of a Terraform
  resource.** Rejected: saved queries are a first-class AWS
  resource; Terraform-managed means version-controlled and
  drift-detectable by SPEC-C1's post-apply plan. A bare
  `aws logs start-query` call in the workflow produces no
  persistent artifact and would drift silently.

- **`aws_cloudwatch_log_metric_filter` instead of
  `aws_cloudwatch_query_definition`.** Rejected: metric filters
  produce counters for alarming; saved queries produce a browsable
  result set for diagnosis. The use case here is diagnosis.

- **Single combined query for both IRSA and RBAC events.**
  Rejected: the two queries target different log groups (CloudTrail
  vs. EKS audit). One `aws_cloudwatch_query_definition` resource
  maps to one log group pattern; they cannot be combined.

---

## 4. Files to change / create

| Path | What changes |
|---|---|
| `/home/user/k8-platform/terraform/management/observability.tf` | Create. Two `aws_cloudwatch_query_definition` resources + log group name locals. |
| `/home/user/k8-platform/terraform/management/outputs.tf` | Modify. Add `logs_insights_irsa_query_arn` and `logs_insights_rbac_deny_query_arn` outputs. |
| `/home/user/k8-platform/tests/unit/test_observability_queries.sh` | Create. Unit test assertions (see §6). |
| `/home/user/k8-platform/tests/unit/run.sh` | Modify. Wire new unit test (one line). |

No changes to `crossplane/`, `argocd/`, `clusters/`, `platform-services/`,
`policies/`, `scripts/`, or any workflow file.

---

## 5. Implementation notes

### 5.1 Log group name resolution

Names are not hardcoded; they are resolved from variables:

```hcl
locals {
  cloudtrail_log_group_name = var.cloudtrail_log_group_name
  eks_audit_log_group_name  = "/aws/eks/${var.cluster_name}/cluster"
}
```

`var.cloudtrail_log_group_name` must be added to
`variables.tf` with a description pointing to SPEC-LC1 as the
provider. The EKS audit name follows the AWS standard pattern and
is derivable from `var.cluster_name`, which already exists.

### 5.2 Query A1-006 — IRSA AssumeRoleWithWebIdentity failures

```hcl
resource "aws_cloudwatch_query_definition" "irsa_failures" {
  name            = "k8-platform/irsa-assumerolewithwebidentity-failures"
  log_group_names = [local.cloudtrail_log_group_name]

  query_string = <<-EOQ
    fields @timestamp, errorCode, errorMessage,
           requestParameters.roleArn as role_arn,
           requestParameters.roleSessionName as sa_subject
    | filter eventName = "AssumeRoleWithWebIdentity"
    | filter ispresent(errorCode)
    | stats count(*) as failures,
            earliest(@timestamp) as first_seen,
            latest(@timestamp)   as last_seen
        by role_arn, sa_subject
    | sort failures desc
    | limit 50
  EOQ
}
```

Group-by axes are `role_arn` (the IAM role the pod is trying to
assume) and `sa_subject` (the `roleSessionName` CloudTrail field,
which EKS IRSA sets to the OIDC subject —
`system:serviceaccount:<ns>:<sa-name>`). When the subject does
not match the role's trust policy, `errorCode` is `AccessDenied`.
This combination is the canonical IRSA-misconfig signature: each
row in the result names the role and the exact SA that was
rejected. `limit 50` caps output; sandbox realistic row count
is 1–5.

Time range: no embedded range in the saved definition. AWS Console
default is the last hour. For CI, pass
`--start-time "$(date -d '1 hour ago' +%s)000"` and
`--end-time "$(date +%s)000"` to `aws logs start-query`.

### 5.3 Query A1-007 — EKS audit log RBAC denies

```hcl
resource "aws_cloudwatch_query_definition" "rbac_denies" {
  name            = "k8-platform/eks-audit-rbac-denies"
  log_group_names = [local.eks_audit_log_group_name]

  query_string = <<-EOQ
    fields @timestamp,
           user.username      as username,
           user.groups.0      as primary_group,
           verb,
           objectRef.resource as resource,
           objectRef.namespace as namespace,
           responseStatus.code as http_code
    | filter responseStatus.code in [403]
    | filter verb not in ["watch", "list"]
    | stats count(*) as deny_count,
            earliest(@timestamp) as first_seen,
            latest(@timestamp)   as last_seen
        by username, primary_group, verb, resource, namespace
    | sort deny_count desc
    | limit 50
  EOQ
}
```

`filter verb not in ["watch", "list"]` suppresses high-volume
background LIST/WATCH traffic that is almost always intentional,
keeping the result focused on actionable `create`/`delete`/`update`
denies. HTTP code `403` is the only authorization-deny code in EKS
audit logs; `401` (unauthenticated) is a distinct failure class and
is excluded. `user.groups.0` captures the first group (e.g.
`system:masters`, or a custom ClusterRoleBinding group); a full
multi-group expansion is a follow-on.

### 5.4 Outputs

```hcl
output "logs_insights_irsa_query_arn" {
  description = "ID of the A1-006 IRSA failure Logs Insights saved query."
  value       = aws_cloudwatch_query_definition.irsa_failures.id
}

output "logs_insights_rbac_deny_query_arn" {
  description = "ID of the A1-007 EKS RBAC deny Logs Insights saved query."
  value       = aws_cloudwatch_query_definition.rbac_denies.id
}
```

Note: `.id` is the query definition UUID, not a true ARN; the
resource exposes no `arn` attribute. The `_arn` suffix is kept for
output-naming symmetry; downstream consumers pass the value to
`aws logs start-query --query-definition-id`.

### 5.5 Cross-references

- SPEC-A3 §2 records the same IRSA debug pain. A1-006 is the
  post-hoc CloudTrail read; SPEC-A3's diagnose workflow is the
  live-cluster SA dump. When both are in place, the canonical
  order is: run A1-006 first (what CloudTrail saw), then SPEC-A3
  workflow (what the live SA state is).
- SPEC-C1 (post-apply drift check) will catch any console edit
  to the query strings out of band — the saved query body diffs
  are detectable by Terraform plan.

---

## 6. Tests required

Per AGENTS.md §6.1 — maximal coverage at applicable layers.

### Unit (required, runs on every push)

`/home/user/k8-platform/tests/unit/test_observability_queries.sh`
asserts:

1. `terraform validate` in `terraform/management/` exits 0.
2. `grep -c 'aws_cloudwatch_query_definition' terraform/management/observability.tf`
   returns `2`.
3. `grep 'AssumeRoleWithWebIdentity' terraform/management/observability.tf`
   exits 0.
4. `grep 'responseStatus.code' terraform/management/observability.tf`
   exits 0.
5. `grep 'logs_insights_irsa_query_arn' terraform/management/outputs.tf`
   exits 0.
6. `grep 'logs_insights_rbac_deny_query_arn' terraform/management/outputs.tf`
   exits 0.
7. No hardcoded 12-digit account ID: `grep -E '[0-9]{12}'
   terraform/management/observability.tf` exits non-zero.

Pure-local lint; no AWS credentials required.

### Adversarial subagent review (per AGENTS.md §6.4)

Minimum questions: (a) If SPEC-LC1's log group does not exist yet,
does `terraform apply` fail cleanly or create a query silently
pointing at nothing? (b) Does the GitHub Actions role have
`logs:PutQueryDefinition`? (c) Does the `verb not in [...]` filter
suppress any actionable deny in the real bring-up scenario?

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

1. **HCL syntax** — `terraform validate` exits 0 (catches query
   string typos before apply).
2. **Resource count** — exactly two `aws_cloudwatch_query_definition`
   blocks; prevents accidental merge into one resource.
3. **No hardcoded account IDs** — mirrors SPEC-B5 account-ID lint.
4. **Output presence** — both output names in `outputs.tf` (prevents
   the dashboard spec from seeing a missing output at plan time).
5. **Query string non-empty** — each query string is ≥80 characters
   (a placeholder query passes `terraform validate` but is useless
   at runtime).

### Integration

Against a live management cluster with SPEC-LC1 and SPEC-LC2 applied:

1. **Definitions visible in AWS** — `aws logs describe-query-definitions
   --query-definition-name-prefix k8-platform/` returns exactly two
   entries with the expected names.
2. **A1-006 executes without error** — `aws logs start-query` with
   the saved query ID returns a query ID; `get-query-results` returns
   `status: Complete` (not `Failed`).
3. **A1-007 executes without error** — same pattern against the EKS
   audit log group.
4. **Post-apply drift is zero** — `terraform plan -detailed-exitcode`
   after apply exits 0 (SPEC-C1 contract).

Integration tests are opt-in and run during management phase
bring-up, not the standard unit suite.

### E2E

Not applicable in the chainsaw sense: these are passive observability
resources, not XRDs or Compositions; there is no claim to apply and
wait for. A future E2E scenario could inject a deliberate IRSA
misconfiguration, wait 30 seconds, run A1-006, and assert at least
one row — but that is a follow-on to the `irsa-failure-quick-quote.sh`
helper (brainstorm A4→A1-006) and is out of scope here.

---

## 8. Documentation updates

- **`ai/handoff.md` NEW SESSION QUICKSTART** — add one sentence
  before the manual IAM traversal step: "Run the two saved Logs
  Insights queries (`k8-platform/irsa-assumerolewithwebidentity-failures`
  and `k8-platform/eks-audit-rbac-denies`) before hand-authoring
  any IRSA or RBAC lookup — they return a failure table with SA
  subjects and deny context in under 10 seconds."

- **`AGENTS.md` §7** (Testing loops — companion skills) — one
  sentence under the IRSA debug toolchain: A1-006 is the CloudTrail
  post-hoc read and is the first step before the SPEC-A3
  live-cluster dump.

- **`ai/brainstorming/specs/larger-list-preferences.md` §S8** —
  mark `Status: IMPLEMENTED` once the PR lands.

---

## 9. Workflow / auto-invocation wiring

These are passive Terraform resources. Once applied, the saved
queries appear in the AWS Console under CloudWatch → Logs Insights
→ Saved queries → `k8-platform/` prefix, with no new workflow step.

For CI consumption, any step can resolve the query definition ID
from Terraform outputs and pass it to `aws logs start-query
--query-definition-id`. This is the pattern the proposed
`irsa-failure-quick-quote.sh` (brainstorm A4→A1-006) should follow.

The resources are applied as part of the existing `apply-and-verify
management` workflow dispatch. No separate observability workflow
is needed.

---

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_observability_queries.sh`
   asserts both `aws_cloudwatch_query_definition` resources are present.
   Deleting or renaming either causes `tests/unit/run.sh` to turn red.
   SPEC-C1's post-apply drift check catches any out-of-band console
   edit to the query strings.

2. **Documentation pointer** — `ai/handoff.md` QUICKSTART (updated
   per §8) directs the next agent to run these named queries before
   any manual IRSA or RBAC traversal. The `k8-platform/` prefix makes
   them discoverable in the AWS Console without knowing the Terraform
   resource name.

3. **Adversarial-review trigger** — AGENTS.md §6.4's checklist item
   "does the implementation produce observable evidence a future agent
   can verify without re-authoring the lookup?" directly surfaces both
   queries: A1-006 produces a row with the exact OIDC subject rejected;
   A1-007 produces a row with the exact verb and resource refused.

---

## 11. Verification checklist

- [ ] `terraform validate` in `terraform/management/` exits 0.
- [ ] `tests/unit/test_observability_queries.sh` exists, is wired
      into `tests/unit/run.sh`, and passes locally without AWS
      credentials.
- [ ] `terraform plan` (management module, sandbox account) shows
      exactly two `aws_cloudwatch_query_definition` resources to
      create and no unexpected changes to existing resources.
- [ ] `terraform apply` completes; `terraform plan -detailed-exitcode`
      immediately after exits 0 (SPEC-C1 post-apply drift contract).
- [ ] `aws logs describe-query-definitions --query-definition-name-prefix k8-platform/`
      returns exactly two items with names
      `k8-platform/irsa-assumerolewithwebidentity-failures` and
      `k8-platform/eks-audit-rbac-denies`.
- [ ] Running A1-006 in the AWS Console returns either zero rows
      (healthy state) or rows with `role_arn` and `sa_subject` columns
      — no schema error.
- [ ] Running A1-007 in the AWS Console returns either zero rows or
      rows with `username`, `verb`, and `resource` columns — no schema
      error.
- [ ] `terraform output logs_insights_irsa_query_arn` and
      `terraform output logs_insights_rbac_deny_query_arn` both return
      non-empty strings.
- [ ] Adversarial subagent review (§6) completed; findings adopted
      or dismissed in the PR body.
- [ ] PR description confirms whether SPEC-LC1 and SPEC-LC2 are
      applied in the target account before this apply.

---

## 12. Rollout notes

- **Dependency sequencing** — SPEC-LC1 and SPEC-LC2 must land before
  this spec. `terraform apply` will succeed without them (the
  `aws_cloudwatch_query_definition` resource does not validate the log
  group's existence at creation time), but queries will return no data
  until the log groups exist. Document this in the PR if landing out
  of order.
- **Backward compatibility** — additive Terraform resource only. No
  existing resource is modified; no existing test breaks.
  `tests/unit/run.sh` gains one line; the new test requires no
  credentials.
- **Sandbox compliance** — `aws_cloudwatch_query_definition` creates
  no EC2 instances, IAM roles, or resources subject to Pluralsight
  sandbox caps. Adds zero cost (saved queries are free). No region
  constraint beyond the management module's us-east-1 / us-west-2
  scope.
- **Coordination** — no conflict with any currently described in-flight
  spec. If SPEC-LC1 / SPEC-LC2 are on a parallel branch, stack this
  spec on top of that branch rather than off `main` directly.

---

## 13. Estimated effort

**S** (small — under 1 hour).

- Authoring `terraform/management/observability.tf`: ~20 min. Two
  resource blocks with the literal query strings from §5.
- Updating `terraform/management/outputs.tf`: ~5 min.
- Authoring `tests/unit/test_observability_queries.sh` + wiring
  into `run.sh`: ~15 min. Seven grep/validate-level assertions.
- Documentation sentence edits (§8): ~10 min.
- Adversarial review + adoption (§6): ~15 min given narrow scope.

Total: 60–75 minutes. Break-even is the first bring-up session
where an IRSA or RBAC failure would have otherwise required 5–10
minutes of manual log hunting — typically the very next session
after the management cluster is stood up.
