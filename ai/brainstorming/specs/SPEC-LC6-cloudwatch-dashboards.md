# SPEC-LC6 — Three CloudWatch dashboards: overview, IRSA debug, Crossplane provisioning

Tier: C — item LC6  
Brainstorm IDs: A1-014, A1-015, A1-016  
Depends on: SPEC-LC1 (management Terraform baseline), SPEC-LC2 (IRSA patterns)

---

## 1. Summary

Add three CloudWatch dashboards — "k8-platform overview", "IRSA debug", and
"Crossplane provisioning" — as Terraform-managed JSON bodies applied by the
`terraform/management/` module. Each targets one of the three highest-debug-
volume areas that have burned session time: EKS/NLB node health, IRSA
AssumeRole rejections, and Crossplane XR/MR reconcile state. JSON bodies live
under `terraform/management/dashboards/` and are referenced by a new
`terraform/management/cloudwatch.tf`. All three `aws_cloudwatch_dashboard`
puts are independent and can run in a single `terraform apply` (brainstorm
A5→A1-004). Value is modest today with one management cluster but grows
sharply at phase 6 when multiple workload clusters feed the same region.

---

## 2. Retro pain killed

- **PR #66 / retrospective/2026-05-25-70.md Phase 2 (IRSA cascade)** —
  diagnosing the `AssumeRoleWithWebIdentity` rejection required opening IAM
  console tabs, Logs Insights queries, and dispatching `phase-2-diagnose.yml`.
  The IRSA debug dashboard surfaces per-role failure counts in one widget.

- **PR #67 / PR #68 — SA-name mismatch iteration** — three sequential PRs to
  confirm the Crossplane IRSA fix actually took. A live failure-count graph
  at 1-min resolution would have confirmed fix effectiveness in one deploy
  cycle rather than three PR iterations.

- **retrospective/2026-05-24-62.md Phase 4 — "XR zero conditions"** — five
  chainsaw failures across PR #52/#53 with PlatformSecret claims stuck
  `Ready=False reason=Waiting` and no visibility into XR state. The
  Crossplane dashboard's "XR Ready ratio" and "Composition function errors"
  widgets provide a passive signal for that silent-failure mode.

- **`ai/handoff.md` Bug 3** — provider-family-aws v1.12.0 slow under
  Crossplane 2.3.0; `CreatedExternalResource` delayed 2+ minutes. An MR
  reconcile-error widget would have surfaced the slowdown as a metric
  deviation rather than requiring a log-grep across chainsaw output.

---

## 3. Out of scope

- **Fancy widgets, custom metrics, or CloudWatch EMF.** Standard AWS-vended
  metrics (ContainerInsights, AWS/NetworkELB, CloudTrail Logs Insights) only.
  Functional visibility, not visual polish. No SNS alarms — threshold tuning
  is not justified yet.

- **Per-workload-cluster dashboard fan-out.** With one cluster, a `for_each`
  loop produces widgets identical to the current ones. Defer the Terraform
  `for_each` + `templatefile()` extension to phase 6.

- **Grafana.** CloudWatch native dashboards are sufficient. Grafana adds
  an extra Helm release and IAM plumbing not warranted at this scale.

### Considered and rejected

- **`templatefile()` for JSON bodies** — adds a rendering step the
  implementing agent must debug. Static JSON with literal cluster names is
  simpler; `templatefile()` is the natural phase-6 extension when `for_each`
  over clusters is needed.

- **Single combined dashboard** — IRSA debug is needed during any IRSA
  incident regardless of Crossplane state; a combined board is unwieldy to
  scroll. Three `aws_cloudwatch_dashboard` resources cost the same `apply`.

---

## 4. Files to change / create

**Create:**

| Path | Purpose |
|---|---|
| `/home/user/k8-platform/terraform/management/cloudwatch.tf` | Three `aws_cloudwatch_dashboard` resources; reads JSON via `file()` |
| `/home/user/k8-platform/terraform/management/dashboards/k8-platform-overview.json` | EKS node CPU, NLB connections, ArgoCD sync |
| `/home/user/k8-platform/terraform/management/dashboards/irsa-debug.json` | AssumeRoleWithWebIdentity failures by role, CloudTrail table |
| `/home/user/k8-platform/terraform/management/dashboards/crossplane-provisioning.json` | Reconcile errors, XR zero-conditions, composition function errors |
| `/home/user/k8-platform/tests/unit/test_cloudwatch_dashboards.sh` | JSON parse + widget count assertions |

**Modify:**

| Path | Change |
|---|---|
| `/home/user/k8-platform/tests/unit/run.sh` | Add invocation of new unit test |

No changes to `terraform/base/`, `crossplane/`, `argocd/`, `clusters/`,
`platform-services/`, `policies/`, `scripts/`, `.github/`.

---

## 5. Implementation notes

### 5.1 `cloudwatch.tf`

```hcl
resource "aws_cloudwatch_dashboard" "overview" {
  dashboard_name = "${local.name_prefix}-overview"
  dashboard_body = file("${path.module}/dashboards/k8-platform-overview.json")
}

resource "aws_cloudwatch_dashboard" "irsa_debug" {
  dashboard_name = "${local.name_prefix}-irsa-debug"
  dashboard_body = file("${path.module}/dashboards/irsa-debug.json")
}

resource "aws_cloudwatch_dashboard" "crossplane_provisioning" {
  dashboard_name = "${local.name_prefix}-crossplane-provisioning"
  dashboard_body = file("${path.module}/dashboards/crossplane-provisioning.json")
}
```

`file()` is evaluated at plan time. No `templatefile()` substitution yet —
JSON files contain literal strings matching `k8-platform-mgmt` and
`crossplane-system`. At phase 6, replace `file()` with `templatefile()` and
thread `var.cluster_name`.

### 5.2 Dashboard 1 — overview (3 widgets)

**Widget 1 — EKS node CPU (line chart, ContainerInsights namespace):**
```json
{ "type": "metric", "properties": {
    "title": "EKS Node CPU Utilisation",
    "view": "timeSeries",
    "metrics": [[
      "ContainerInsights", "node_cpu_utilization",
      "ClusterName", "k8-platform-mgmt",
      { "stat": "Average", "period": 60 }
    ]]
}}
```

**Widget 2 — NLB active connections (AWS/NetworkELB namespace):**
```json
{ "type": "metric", "properties": {
    "title": "NLB Active Connections",
    "view": "timeSeries",
    "metrics": [[
      "AWS/NetworkELB", "ActiveFlowCount",
      "LoadBalancer", "net/k8-platform-mgmt/PLACEHOLDER",
      { "stat": "Sum", "period": 60 }
    ]]
}}
```

Note: the NLB ARN suffix is account-derived. Per AGENTS.md §8.1 do NOT hardcode
it. Leave `PLACEHOLDER` in the JSON; the widget renders as "no data" until the
implementing agent substitutes the real suffix (or drives it from a
`data.aws_lb` lookup + `templatefile()` — optional for the first apply).

**Widget 3 — ArgoCD apps not synced (Logs Insights table):**
```json
{ "type": "log", "properties": {
    "title": "ArgoCD Apps Not Synced",
    "query": "SOURCE '/aws/containerinsights/k8-platform-mgmt/application' | fields @timestamp, @message | filter @message like /OutOfSync/ | stats count(*) as count by bin(5m)",
    "view": "table"
}}
```

### 5.3 Dashboard 2 — IRSA debug (3 widgets)

**Widget 1 — AssumeRoleWithWebIdentity failures by role (line chart):**
```json
{ "type": "metric", "properties": {
    "title": "AssumeRoleWithWebIdentity Failures by Role",
    "view": "timeSeries",
    "metrics": [
      [ "AWS/STS", "AssumeRoleWithWebIdentityFailed",
        "RoleName", "k8-platform-mgmt-crossplane",
        { "stat": "Sum", "period": 60, "color": "#d62728" } ],
      [ "AWS/STS", "AssumeRoleWithWebIdentityFailed",
        "RoleName", "k8-platform-mgmt-eso",
        { "stat": "Sum", "period": 60, "color": "#ff7f0e" } ]
    ],
    "yAxis": { "left": { "min": 0 } }
}}
```

Note: `AWS/STS AssumeRoleWithWebIdentityFailed` requires a CloudWatch metric
filter on the CloudTrail log group. Add an `aws_cloudwatch_log_metric_filter`
resource in `cloudwatch.tf` (confirm log group via `aws cloudtrail describe-trails`).
Widget 3 (Logs Insights) is the zero-extra-resource fallback if the filter is
not yet in place.

**Widget 2 — success vs failure ratio for crossplane role (bar chart):**
```json
{ "type": "metric", "properties": {
    "title": "AssumeRoleWithWebIdentity Success vs Failure (crossplane)",
    "view": "bar",
    "metrics": [
      [ "AWS/STS", "AssumeRoleWithWebIdentity",
        "RoleName", "k8-platform-mgmt-crossplane",
        { "stat": "Sum", "period": 300, "color": "#2ca02c" } ],
      [ "AWS/STS", "AssumeRoleWithWebIdentityFailed",
        "RoleName", "k8-platform-mgmt-crossplane",
        { "stat": "Sum", "period": 300, "color": "#d62728" } ]
    ]
}}
```

**Widget 3 — CloudTrail Logs Insights: IRSA rejection details (table):**
```json
{ "type": "log", "properties": {
    "title": "IRSA Rejection Details (CloudTrail)",
    "query": "SOURCE 'aws-cloudtrail-logs' | fields @timestamp, requestParameters.roleArn, errorCode, errorMessage | filter eventName = 'AssumeRoleWithWebIdentity' and ispresent(errorCode) | sort @timestamp desc | limit 20",
    "view": "table"
}}
```

Adjust the log group name to the account's actual CloudTrail delivery group.
This widget fires without any extra metric filter resource.

### 5.4 Dashboard 3 — Crossplane provisioning (3 widgets)

**Widget 1 — Reconcile errors per 5 minutes (Logs Insights bar):**
```json
{ "type": "log", "properties": {
    "title": "Crossplane Reconcile Errors (per 5m)",
    "query": "SOURCE '/aws/containerinsights/k8-platform-mgmt/application' | fields @timestamp, @message | filter kubernetes.namespace_name = 'crossplane-system' and @message like /reconcile error/ | stats count(*) by bin(5m)",
    "view": "bar"
}}
```

**Widget 2 — XRs with zero conditions (Logs Insights table, catches the §2 silent-failure mode):**
```json
{ "type": "log", "properties": {
    "title": "XRs with Zero Conditions (last 30m)",
    "query": "SOURCE '/aws/containerinsights/k8-platform-mgmt/application' | fields @timestamp, @message | filter kubernetes.namespace_name = 'crossplane-system' and @message like /no conditions/ | sort @timestamp desc | limit 10",
    "view": "table"
}}
```

**Widget 3 — Composition function Fatal errors (Logs Insights table):**
```json
{ "type": "log", "properties": {
    "title": "Composition Function Fatal Errors (last 1h)",
    "query": "SOURCE '/aws/containerinsights/k8-platform-mgmt/application' | fields @timestamp, @message | filter kubernetes.namespace_name = 'crossplane-system' and @message like /Fatal/ | sort @timestamp desc | limit 20",
    "view": "table"
}}
```

### 5.5 JSON validation before apply

```bash
for f in terraform/management/dashboards/*.json; do
  python3 -c "import json; json.load(open('$f'))" && echo "OK: $f"
done
terraform -chdir=terraform/management validate
```

Widgets that query `/aws/containerinsights/...` render as "no data" until
Container Insights is enabled — the apply succeeds regardless.

---

## 6. Tests required

Per AGENTS.md §6.1, applicable layers are unit (JSON parse, HCL validate) and
integration (apply + `aws cloudwatch get-dashboard` confirm).

**Unit — `tests/unit/test_cloudwatch_dashboards.sh` (new, required):**

1. Each JSON file exists and parses:
   `python3 -c "import json; json.load(open(...))"` exits 0 for all three.
2. Each JSON body has `widgets` array with ≥ 3 items:
   `python3 -c "... assert len(d['widgets']) >= 3"`.
3. `cloudwatch.tf` contains all three `aws_cloudwatch_dashboard` resource names
   (grep for `k8-platform-mgmt-overview`, `-irsa-debug`, `-crossplane-provisioning`).
4. `terraform validate` passes for `terraform/management/`.

Meta-test: remove one JSON file and confirm the unit test exits 1 — verifies
the test actually fires.

**Kyverno:** N/A — no new cluster-resource pattern.

**Integration:** `terraform apply` + `aws cloudwatch get-dashboard` for each
dashboard (see §11 checklist). No new integration test script needed.

**Chainsaw:** N/A — no XRD or Composition added.

---

## 7. Testing suggestions (unit / integration / e2e)

**Unit:**

1. Corrupt one JSON file and confirm `test_cloudwatch_dashboards.sh` exits 1
   with the filename named in the error output.
2. Assert no widget `properties` block contains a hardcoded 12-digit account
   ID: `python3 -c "... assert not re.search(r'[0-9]{12}', body)"` — enforces
   AGENTS.md §8.1 at authoring time.
3. Assert widget `type` values are only `"metric"` or `"log"` — prevents
   accidentally shipping a `"text"` placeholder widget with no data.

**Integration:**

1. Post-apply: `aws cloudwatch get-dashboard --dashboard-name k8-platform-mgmt-irsa-debug`
   returns HTTP 200 and body length > 100 bytes.
2. Post-apply: `terraform plan` shows 0 changes (idempotency; no spurious
   drift from whitespace or key ordering).
3. Deliberate IRSA failure (temporarily remove trust subject): confirm the
   CloudTrail Logs Insights widget surfaces the rejection within 5 minutes.

**E2E:** Not applicable. Dashboard creation is an AWS control-plane operation
with no Kubernetes resource to assert against in a chainsaw scenario.

---

## 8. Documentation updates

- `ai/handoff.md` "Critical behavioral rules" table: add a row pointing at
  `k8-platform-mgmt-irsa-debug` as the first stop for IRSA incident response,
  before dispatching `phase-2-diagnose.yml`.
- `AGENTS.md §7` (Testing loops): add one bullet noting that after any
  `terraform apply` touching `terraform/management/`, the three CloudWatch
  dashboards should be accessible.
- `docs/operations.md`: add a short "Dashboards" section listing the three
  dashboard names and their primary use cases (if the file exists).

---

## 9. Workflow / auto-invocation wiring

Purely Terraform-managed. The dashboards are created and updated on every
`terraform apply` of `terraform/management/` — no additional workflow or hook.

`terraform validate` already runs in `.github/workflows/terraform-validate.yml`
on every push, covering `cloudwatch.tf` automatically.

The new unit test is wired into `tests/unit/run.sh` and therefore runs in
`.github/workflows/unit-tests.yml` on every push.

---

## 10. Discoverability

1. **Mechanical enforcement** — `test_cloudwatch_dashboards.sh` fails (via
   `unit-tests.yml` CI) if any JSON file is missing, unparseable, or if the
   `cloudwatch.tf` resource blocks are removed. A PR deleting a dashboard is
   blocked by a red unit-tests check.

2. **Documentation pointer** — `AGENTS.md §7` (after the §8 update) names
   the three dashboards and their URL pattern. A future agent reading §7 will
   find the dashboard names and know they are Terraform-managed under
   `terraform/management/dashboards/`.

3. **Adversarial-review trigger** — per AGENTS.md §6.4, any PR touching IRSA
   resources (`terraform/management/irsa.tf`) should confirm the IRSA debug
   dashboard was checked post-apply before the PR is marked verified.

---

## 11. Verification checklist

- [ ] `python3 -c "import json; json.load(open('terraform/management/dashboards/k8-platform-overview.json'))"` exits 0.
- [ ] Same for `irsa-debug.json` and `crossplane-provisioning.json`.
- [ ] `terraform -chdir=terraform/management validate` exits 0.
- [ ] `tests/unit/test_cloudwatch_dashboards.sh` exits 0 locally.
- [ ] `terraform plan` for `terraform/management/` shows exactly `3 to add` (new apply) or `0 changes` (re-apply).
- [ ] After apply: `aws cloudwatch get-dashboard --dashboard-name k8-platform-mgmt-overview` returns HTTP 200.
- [ ] After apply: same for `k8-platform-mgmt-irsa-debug` and `k8-platform-mgmt-crossplane-provisioning`.
- [ ] `aws cloudwatch get-dashboard --dashboard-name k8-platform-mgmt-overview --query DashboardBody --output text | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d['widgets']) >= 3"` exits 0.
- [ ] `terraform plan` post-apply shows `0 changes` (idempotency confirmed).
- [ ] `terraform destroy -target aws_cloudwatch_dashboard.overview` exits 0 and subsequent `get-dashboard` returns `ResourceNotFound`.

---

## 12. Rollout notes

**Timing and phase-6 value.** Apply now (phase 1+); value scales with cluster
count. IRSA debug dashboard is useful immediately. Overview dashboard peaks at
phase 6 when multiple workload clusters feed the same region. Build now — the
implementation cost (three JSON files + one .tf file) does not justify deferral.

**Backward compatibility.** Purely additive. No existing resource modified; no
state invalidated. `terraform destroy -target` removes the three dashboards
cleanly.

**Pluralsight sandbox constraints.** CloudWatch dashboards and Logs Insights are
not constrained by the instance-type whitelist or EC2 quota in
`ai/testing-guidelines.md §1`. No Bedrock or Marketplace dependencies.

**Container Insights prerequisite.** Logs Insights widgets render "no data" if
Container Insights is not enabled — the apply succeeds. Enabling is a follow-up
task orthogonal to this spec.

**Coordination.** No in-flight PRs as of 2026-05-25 touch `cloudwatch.tf` or
`dashboards/`. No stacking required.

---

## 13. Estimated effort

**M (1–3 hr)**

Breakdown: authoring three JSON bodies (3 widgets each, shapes provided in §5)
≈ 45 min; `cloudwatch.tf` resource block ≈ 10 min; unit test + `run.sh` wiring
≈ 15 min; JSON validation + `terraform validate` locally ≈ 5 min; `terraform
apply` on a live sandbox + `aws cloudwatch get-dashboard` checks ≈ 20 min;
documentation sentence edits + PR ≈ 20 min. Total ≈ 1 hr 55 min. Classified
`M` because the CloudTrail log group name discovery and the NLB ARN suffix
lookup add uncertainty that can push to the 2.5 hr upper end.
