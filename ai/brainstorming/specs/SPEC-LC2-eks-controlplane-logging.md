# SPEC-LC2 — Enable EKS control-plane logging (api, audit, authenticator, controllerManager, scheduler)

Status: DRAFT (spec only — no implementation in this PR)
Tier: C (observability foundations)
Brainstorm ID: A1-003
Branch: spec/top-15-immediate-changes
Owner: next agent picking up observability foundation work

---

## 1. Summary

Add `enabled_cluster_log_types` to the `module "eks"` block in
`/home/user/k8-platform/terraform/management/eks.tf`, enabling all five EKS
control-plane log streams: `api`, `audit`, `authenticator`,
`controllerManager`, and `scheduler`. A companion
`aws_cloudwatch_log_group` resource in the same file sets 7-day
retention on the auto-created log group `/aws/eks/<cluster_name>/cluster`
so the sandbox account does not accumulate unbounded CloudWatch Logs storage
across sessions. This is a Tier C observability foundation (see
`ai/brainstorming/specs/larger-list-preferences.md` §C2). It is the
prerequisite for SPEC-S8's CloudWatch Logs Insights RBAC-denial query
(`A1-007`). Without these logs, every IRSA and RBAC debug cycle
devolves into inference from pod-side events and kubectl output rather
than the authoritative audit record.

---

## 2. Retro pain killed

- **PR #66, #67, #68 — multi-session IRSA SA-name cascade**
  (`retrospective/2026-05-25-70.md`, Phase 2). Root cause: OIDC subject
  mismatch (`crossplane-system:provider-family-aws-24aaab54a3a0` vs.
  expected `crossplane-system:upbound-provider-family-aws`). The
  `authenticator` stream records every `AssumeRoleWithWebIdentity` call,
  including failures, with the OIDC subject. Had logging been enabled, the
  mismatch would have appeared immediately; instead three PRs and multiple
  dispatch cycles were needed to triangulate from side-channel evidence.

- **Phase-1 IRSA silent failures — ArgoCD SA on wrong component SA,
  ExternalDNS missing `ListHostedZones`** (`retrospective/2026-05-23-36.md`
  line 54). Both produced `AccessDenied` in pod logs with no corresponding
  audit entry visible. The `audit` stream records every API-server request
  with authenticated user and result; RBAC denials appear at rejection time
  rather than surfacing only when pod-side scraping catches them.

- **Phase-1 RBAC propagation race** (`retrospective/2026-05-23-36.md`
  line 50): `serviceaccounts is forbidden` on ingress-nginx's first call.
  Resolved with a retry, but diagnosing recurrence required polling pod logs
  manually. The `audit` stream makes failed RBAC checks durable and queryable
  after the fact, removing the "caught it in pod logs" vs. "missed it" lottery.

- **Crossplane RBAC deny for ExternalSecrets** (`retrospective/2026-05-23-36.md`
  line 47): `crossplane-system:crossplane is not allowed to … externalsecrets`.
  The fix required reading controller logs during the failure window. An audit
  log entry provides authenticated subject, verb, resource, and namespace in
  a single queryable record, independent of pod-log capture timing.

- **General pattern** (`retrospective/2026-05-25-70.md` line 53):
  "every IRSA/RBAC debug becomes a guess." The retro names absence of audit
  evidence as the forcing function behind the multi-PR cascade. Logging
  converts every future IRSA or RBAC failure from a guessing exercise into
  a lookup.

---

## 3. Out of scope

- **Log shipping / forwarding outside CloudWatch.** This spec delivers
  logs to CloudWatch only. Streaming to an external SIEM, Elasticsearch,
  or S3 archive is a future concern. Sandboxes are ephemeral; the
  7-day retention window is more than sufficient for session-scoped
  postmortems.

- **SPEC-S8 (CloudWatch Logs Insights saved queries).** That spec
  consumes the log groups this spec creates. The two specs are
  intentionally sequenced: this one (infrastructure) before S8
  (queries). Do not author Logs Insights resources here.

- **VPC flow logs (A1-004 / SPEC-LC3).** Those belong in
  `terraform/base/` and address a different failure class
  (network-level drops). Referenced in the preferences doc as C3
  but outside this spec's scope.

- **CloudWatch alarms or metric filters on the log streams.** Useful
  for phase 4+ observability but adds cost surface above the
  sandbox-safe baseline and is outside this spec's narrow goal.

- **Control-plane node-to-controller-manager latency metrics.** EKS
  Control Plane Metrics (separate from Logs) are not covered here.

### Considered and rejected

- **Subset of log types** (e.g. `audit` + `authenticator` only). Rejected:
  at sandbox scale all five are free. Selective enabling complicates Logs
  Insights queries that correlate `api` and `audit` request IDs. The module
  accepts the full list in one attribute; no implementation cost difference.
  Omitting any type trades zero savings for reduced coverage.

- **Longer retention (14 days or indefinite).** Rejected: sandbox sessions
  are a few hours (`ai/aws-test-environment-limitations.md`); 7 days matches
  the companion CloudTrail spec C1. Longer retention accumulates cost across
  rotations for zero benefit.

- **Rely on EKS auto-create for the log group** (no explicit resource).
  Rejected: EKS auto-creates the group with no retention policy, causing
  indefinite accumulation. An explicit `aws_cloudwatch_log_group` with
  `retention_in_days = 7` is required.

### Cost considerations

At sandbox-scale traffic (one management cluster, 3–6 nodes, no real user
traffic), all five log types combined produce a few hundred MB per session.
CloudWatch Logs ingestion is $0.50/GB; combined cost is well under $0.01
per session. The 7-day retention cap prevents cross-session accumulation.
This is the correct default for a debug-heavy environment where postmortem
evidence is the primary deliverable.

---

## 4. Files to change / create

### Modify

| Path | What changes |
|------|--------------|
| `/home/user/k8-platform/terraform/management/eks.tf` | Add `enabled_cluster_log_types` to `module "eks"` block; add `aws_cloudwatch_log_group` resource with 7-day retention and `depends_on` |

### Create

| Path | What changes |
|------|--------------|
| `/home/user/k8-platform/tests/unit/test_eks_controlplane_logging.sh` | Unit test asserting the `enabled_cluster_log_types` attribute and log group retention are present in `eks.tf` |

No other directories or files are touched by this spec.

---

## 5. Implementation notes

### `enabled_cluster_log_types` attribute

Add to the `module "eks"` block in
`/home/user/k8-platform/terraform/management/eks.tf`:

```hcl
  # audit + authenticator are the authoritative source for IRSA and RBAC denials.
  # All five enabled; at sandbox-scale traffic combined cost is < $0.01/session.
  # Prerequisite for SPEC-S8 Logs Insights saved queries (A1-006, A1-007).
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
```

Note: `terraform-aws-modules/eks/aws` v20.x exposes `cluster_enabled_log_types`
(note the `cluster_` prefix, distinct from the raw resource attribute
`enabled_cluster_log_types`). The implementing agent must confirm the exact
variable name against the module version in `versions.tf` before applying.

### CloudWatch log group retention

EKS auto-creates the log group `/aws/eks/<cluster_name>/cluster` when
the first log type is enabled. Without an explicit resource, the group
carries no retention policy and logs accumulate indefinitely. Add
after the module block:

```hcl
# Explicit retention on the EKS control-plane log group.
# Without this, EKS auto-creates the group with no retention policy.
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 7
  depends_on        = [module.eks]
  tags              = { Cluster = var.cluster_name }
}
```

`depends_on = [module.eks]` makes the intent explicit: Terraform creates
the cluster (and AWS auto-creates the log group) before this resource
takes ownership and sets retention. Either creation order is valid at
the AWS level; the `depends_on` prevents Terraform from ever racing
ahead and trying to set retention on a log group that does not yet exist.

### Idempotency and backward compatibility

EKS supports enabling log types on a running cluster with no downtime.
A `terraform plan` will show a change only to `cluster_enabled_log_types`
and the new `aws_cloudwatch_log_group` resource. No node groups, IAM
roles, subnets, or OIDC providers are affected.

### Cross-reference

SPEC-S8's Logs Insights query resources must reference
`/aws/eks/${var.cluster_name}/cluster` (the log group name produced
here). Consume via `aws_cloudwatch_log_group.eks_cluster.name` rather
than repeating the literal string.

---

## 6. Tests required

Per `AGENTS.md §6.1` (maximal coverage) and `§6.4` (adversarial
review before test authoring).

### Unit (must-have)

`/home/user/k8-platform/tests/unit/test_eks_controlplane_logging.sh`

Asserts (using `grep` / `hcl_extract` against `eks.tf`):

1. The literal `cluster_enabled_log_types` attribute is present in
   `eks.tf` and contains all five values: `api`, `audit`,
   `authenticator`, `controllerManager`, `scheduler`. Failure mode:
   the attribute is missing or a log type was accidentally dropped.
2. An `aws_cloudwatch_log_group` resource named `eks_cluster` exists
   in `eks.tf`. Failure mode: the log group was never added, causing
   unbounded retention.
3. The `retention_in_days` value is `7`. Failure mode: retention was
   set to a value that accumulates excessive cost in sandbox (e.g.,
   `0` = never expire).
4. The log group `name` field references `var.cluster_name`, not a
   hardcoded string. Failure mode: hardcoded name breaks reuse across
   accounts or cluster rename.

This test is pure-local (no AWS, no cluster). Runs as part of
`tests/unit/run.sh` in under 5 seconds.

### Adversarial subagent review

Per `AGENTS.md §6.4`: before the implementation PR, spawn one adversarial
subagent. Brief: (1) what ships — one `cluster_enabled_log_types` addition,
one `aws_cloudwatch_log_group` resource; (2) current test plan — four
assertions above; (3) bug history — IRSA SA-name cascade PR #66–#68 and
RBAC race (`retrospective/2026-05-23-36.md`); (4) job — *"Tear the test plan
apart; propose five or more tests with layer + file + assertion; be ruthless
about what silently passes with logging disabled"*; (5) skip — AWS API
rate-limiting, multi-region.

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast local assertions against static HCL. Each runs in `tests/unit/run.sh`.

- `test_eks_controlplane_logging.sh` (gate test from §6): all five log types
  listed, retention = 7, log group name uses `var.cluster_name`.
- Extension: assert EKS module version in `versions.tf` is `~> 20.0` or
  higher — `cluster_enabled_log_types` was introduced in v18; guards against
  accidental downgrade silently dropping the attribute.
- Extension: assert `aws_cloudwatch_log_group.eks_cluster` carries a
  `tags` block with the `Cluster` key, consistent with `module "eks"` tagging.

### Integration

Tests against a live EKS cluster. Lives at
`tests/integration/NN_eks_controlplane_logs.sh`.

- After `terraform apply`, assert `aws eks describe-cluster --name <cluster>
  --query 'cluster.logging.clusterLogging[?enabled==\`true\`].types'`
  returns all five types. Failure mode: attribute accepted by module but not
  propagated to the EKS API.
- Assert `/aws/eks/<cluster>/cluster` log group exists and `retentionInDays`
  is `7`: `aws logs describe-log-groups --log-group-name-prefix
  /aws/eks/<cluster>/cluster --query 'logGroups[0].retentionInDays'`.
- (Inspired by A2→A1-003 cross-review): run `kubectl auth can-i --as
  system:anonymous get pods` (will deny), then assert that within 60 seconds
  at least one new log event appears in the audit stream containing
  `system:anonymous`. Proves the pipeline emits, not just that the cluster
  claims logging is enabled.

### E2E

- Chainsaw scenario: **deliberately not applicable.** Control-plane logging
  is an EKS cluster attribute, not a Crossplane claim-to-managed-resource
  chain. Chainsaw tests exercise XRD compositions; the integration script
  above covers the observable contract at the appropriate layer.
- Post-apply e2e assertion in the `[management] e2e-verify` workflow step:
  add an `aws eks describe-cluster` probe asserting all five log types are
  enabled. Fires on every `apply-and-verify` run, preventing silent
  regression if a future EKS module upgrade resets the attribute to the
  module default (empty list).

---

## 8. Documentation updates

- **`AGENTS.md §5`** — no change; control-plane logging is transparent to
  the phase procedure.
- **`ai/handoff.md`** Phase 1 checklist — add: "EKS control-plane logging
  all five types: `aws eks describe-cluster --name <cluster> --query
  'cluster.logging.clusterLogging[?enabled].types'`".
- **`ai/brainstorming/specs/larger-list-preferences.md` §C2** — annotate
  "spec at SPEC-LC2" so future sessions do not re-derive the design.

---

## 9. Workflow / auto-invocation wiring

Rides on the existing `apply-and-verify` workflow (`phase=management`).
No new workflow, hook, or trigger needed. Integration assertions wire into
`tests/integration/run.sh` (full test bundle per `AGENTS.md §6.3`). The
e2e probe lands in `[management] e2e-verify` and fires on every CI run.

---

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_eks_controlplane_logging.sh`
   runs in `tests/unit/run.sh` (required by every PR per `AGENTS.md §6.1`).
   Removing `cluster_enabled_log_types` from `eks.tf` fails the unit test,
   which fails CI. A future agent cannot silently drop the logging config.

2. **Documentation pointer** — `ai/brainstorming/specs/larger-list-preferences.md`
   §C2 cites SPEC-LC2 / A1-003; any agent orienting for Tier C work lands
   here directly. The `ai/handoff.md` Phase 1 checklist bullet (§8 above)
   names the `aws eks describe-cluster` probe, embedding the requirement in
   the phase-1 bring-up procedure itself.

3. **Adversarial-review trigger** — `AGENTS.md §6.4` requires an adversarial
   reviewer before drafting tests for any new infrastructure. The brief in §6
   explicitly cites the IRSA SA-name cascade and RBAC race. Any future EKS
   module expansion triggers the §6.4 gate, surfacing this spec as prior art.

---

## 11. Verification checklist

Steps the implementing agent runs after applying the spec.

- [ ] `grep -n "cluster_enabled_log_types" /home/user/k8-platform/terraform/management/eks.tf`
      returns a line containing all five log types in the same list.

- [ ] `grep -n "aws_cloudwatch_log_group" /home/user/k8-platform/terraform/management/eks.tf`
      returns at least one match confirming the resource is present.

- [ ] `grep -n "retention_in_days" /home/user/k8-platform/terraform/management/eks.tf`
      returns `7` (not `0` or absent).

- [ ] `bash tests/unit/run.sh` exits 0 with the new
      `test_eks_controlplane_logging.sh` included and passing.

- [ ] `terraform -chdir=/home/user/k8-platform/terraform/management plan`
      shows only `~ module.eks` (log type update) and
      `+ aws_cloudwatch_log_group.eks_cluster`. No destroys, no node changes.

- [ ] After `terraform apply`, `aws eks describe-cluster --name <cluster>
      --query 'cluster.logging.clusterLogging[?enabled==\`true\`].types'`
      returns all five types (order may vary).

- [ ] `aws logs describe-log-groups --log-group-name-prefix /aws/eks/<cluster>/cluster
      --query 'logGroups[0].retentionInDays'` returns `7`.

- [ ] 2 minutes after apply: `aws logs describe-log-streams --log-group-name
      /aws/eks/<cluster>/cluster --order-by LastEventTime --descending
      --max-items 5` returns at least one stream (proves EKS writes into the group).

- [ ] Adversarial-reviewer subagent from §6 run; findings adopted or
      dismissed in the implementation PR body.

---

## 12. Rollout notes

- **Backward compatibility.** Enabling log types on a running EKS cluster is
  a non-destructive in-place update. Node groups, OIDC provider, IRSA roles,
  and in-cluster workloads are unaffected. `terraform plan` shows a change
  only to `cluster_enabled_log_types` and the new log group resource.

- **Audit-before-merge.** No existing files assert that `cluster_enabled_log_types`
  is absent. The new unit test is added in the same PR as the HCL change so
  CI lands green immediately without any backfill audit.

- **Pluralsight sandbox constraints.** CloudWatch Logs is on the
  safe-by-default services list in `ai/aws-test-environment-limitations.md`.
  No EC2, no IAM users, no VPCs, no NAT gateways added. Storage cost at
  sandbox scale is under $0.01 per session.

- **Coordination.** This spec touches only `terraform/management/eks.tf`.
  No conflict with Crossplane, ArgoCD, or Kyverno work. Standalone PR off
  `main`; no stacking required. SPEC-S8 is the downstream consumer but is
  not in the current immediate-changes batch.

---

## 13. Estimated effort

**S** (small, ≤1 hour).

- HCL edit to `eks.tf`: 15 minutes. One attribute addition to the module
  block, one new `aws_cloudwatch_log_group` resource block.
- Unit test `test_eks_controlplane_logging.sh`: 20 minutes. Four grep-based
  assertions matching the pattern of existing tests in `tests/unit/`.
- Adversarial subagent review (§6.4): 15 minutes to brief and adopt/dismiss.
- Documentation updates (§8): 10 minutes.
- Live-cluster verification (§11 items 5–8): absorbed into the next
  `apply-and-verify` dispatch; zero extra session time.

Total: approximately 45–60 minutes. No rollout-audit cost — no existing
files need editing to satisfy the new unit test, which asserts presence of
new HCL rather than absence of old HCL.
