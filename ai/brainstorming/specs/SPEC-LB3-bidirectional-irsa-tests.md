# SPEC-LB3 — Bidirectional IRSA invariant integration tests (A2-005 + A2-006)

Tier: B · Brainstorm IDs: A2-005, A2-006 · Pairs with SPEC-B2 (static lint) and SPEC-B4 (Kyverno audit)

## 1. Summary

Add two integration tests that together enforce the bidirectional IRSA
invariant against a live cluster: (A2-005) every IRSA role's trust policy
must list a `system:serviceaccount:<ns>:<sa>` subject for which a real SA
exists on the cluster; (A2-006) every SA annotated with
`eks.amazonaws.com/role-arn` must point at a role whose trust policy
contains that SA's `(namespace, name)`. Bug 5 (PR #66–#68 cascade) exposed
both directions in a single incident — the trust subject named a SA that did
not exist until the pin was added, and any SA with the correct annotation
would have been silently rejected by STS. These tests lock both directions
permanently against a live EKS cluster, complementing the static-lint
layer of SPEC-B2 and the Kyverno audit layer of SPEC-B4. The smallest
concrete artifacts are two new test scripts under
`tests/integration/` and a shared IAM-parsing helper in
`tests/integration/lib/irsa_trust.sh`.

## 2. Retro pain killed

- **`retrospective/2026-05-25-70.md` Phase 2 / PR #66 — root cause.**
  `irsa.tf:98` declared `crossplane-system:upbound-provider-family-aws` as
  the trust subject but Crossplane generated the hash-suffixed SA
  `provider-family-aws-24aaab54a3a0`. No test confirmed the named SA
  existed on the cluster. Three PRs and multiple dispatch cycles were
  consumed diagnosing what a single `kubectl get sa` against the trust
  subject would have surfaced immediately.
- **`retrospective/2026-05-25-70.md` Phase 2 / PR #68 — pod still mounted
  on old SA.** Even after the pin landed the running pod stayed on the
  hash-suffixed SA. The inverse check (A2-006: SA annotation → role trust)
  would have flagged the old SA — it carried the annotation but was not
  a trust subject — letting an agent immediately distinguish "right SA,
  wrong trust" from "wrong SA, right trust".
- **`ai/handoff.md` ~line 50 — silent STS rejection.** The OIDC rejection
  happened inside the provider pod and was visible only in controller logs;
  the XR sat `Ready=False` with no surface-level error. An integration test
  that calls `aws iam get-role` and compares trust subjects to live SAs
  would surface this class without any log spelunking.
- **`retrospective/2026-05-25-70.md` metrics row — no regression tests.**
  "Tests added (before / after) — `test_kyverno_policy_lint.sh` got a
  fourth section … no other unit tests touched." The PRs shipped fixes with
  no integration-level guard. These tests close that gap.
- **Brainstorm A2-005 justification** — "The PR #66 SA-hash bug went
  undetected because no test compared trust-subject to live SA list."
  LB3 is the direct implementation of that gap note.

## 3. Out of scope

- **Static-lint direction (SA pin in-repo).** SPEC-B2's
  `test_irsa_sa_pinned.sh` checks that every IRSA trust subject has a
  matching SA pin in the Terraform/Crossplane/Helm source files. LB3 is
  the runtime complement — it asks whether the SA actually exists on the
  live cluster at test time, not whether it is pinned in code. Both tests
  should be green simultaneously; they are not redundant because they fire
  in different environments (CI code-scan vs live-cluster integration suite).
- **Kyverno continuous audit (SPEC-B4).** SPEC-B4 fires on every SA
  admission and surfaces violations in `PolicyReport`. LB3 is a one-shot
  test in the scheduled integration suite. Both layers are maintained.
- **IAM permission correctness.** That is `test_iam_required_actions.sh`'s
  domain. LB3 checks only the trust relationship, not attached policies.
- **Cross-account roles.** `aws iam get-role` calls use the cluster's own
  credentials; cross-account role lookups fail — LB3 skips with `SKIP`
  rather than `FAIL` to avoid false positives.
- **Pod Identity (non-OIDC).** Out of scope; sibling spec if adopted.

### Considered and rejected

- **Single parameterized test instead of two scripts.** Brainstorm comment
  A6→A2-004 suggests collapsing A2-005 and A2-006 into one parameterized
  script. Rejected because the two invariants have different data sources
  (A2-005 reads from `irsa.tf` + IAM; A2-006 reads from the live SA
  registry + IAM) and different fix guidance. Two focused scripts with
  explicit names (`12_irsa_trust_subjects_exist.sh` and
  `13_irsa_sa_annotations_valid.sh`) produce clearer failure messages and
  allow independent re-running. A shared helper (`lib/irsa_trust.sh`)
  provides the common IAM-parsing logic, avoiding duplication.
- **Unit test rather than integration test.** The invariant requires both
  a live `aws iam get-role` call and a live `kubectl get sa`. That is
  inherently an integration-layer concern (per AGENTS.md §6.1 — "tests
  against a live cluster"). A unit test would require mocking both, which
  is covered by SPEC-B2's static approach. LB3 is the runtime layer, not
  a replacement for the static layer.

## 4. Files to change / create

**Create:**

- `/home/user/k8-platform/tests/integration/12_irsa_trust_subjects_exist.sh`
  — A2-005: for each `namespace_service_accounts` entry extracted from
  `terraform/management/irsa.tf`, call `aws iam get-role`, parse the trust
  policy, and assert the subject SA exists on the cluster.
- `/home/user/k8-platform/tests/integration/13_irsa_sa_annotations_valid.sh`
  — A2-006: for each SA with `eks.amazonaws.com/role-arn`, call
  `aws iam get-role`, extract trust subjects, and assert
  `system:serviceaccount:<ns>:<name>` appears in the trust.
- `/home/user/k8-platform/tests/integration/lib/irsa_trust.sh`
  — Shared helper: `irsa_trust_subjects_for_arn <role-arn>` outputs
  one `system:serviceaccount:<ns>:<sa>` string per line, derived from
  `aws iam get-role` output. Used by both test scripts.

**Modify:**

- `/home/user/k8-platform/tests/integration/run.sh`
  — Register both new scripts so they run as part of the standard
  integration suite.
- `/home/user/k8-platform/ai/TESTING-PLAN.md`
  — Add two rows to the bug-to-test traceability matrix: PR #66 / A2-005
  → `12_irsa_trust_subjects_exist.sh`; PR #66 / A2-006 →
  `13_irsa_sa_annotations_valid.sh`.

## 5. Implementation notes

### 5.1 IAM trust policy parsing

The test calls the AWS IAM API at runtime:

```bash
# In lib/irsa_trust.sh
irsa_trust_subjects_for_arn() {
  local role_arn="$1"
  local role_name="${role_arn##*/}"

  local trust_json
  trust_json=$(aws iam get-role \
    --role-name "$role_name" \
    --query 'Role.AssumeRolePolicyDocument' \
    --output json 2>/dev/null) || {
    echo "SKIP: cannot fetch role $role_name (cross-account or not found)" >&2
    return 1
  }

  # Extract every system:serviceaccount:* value from StringEquals / StringLike
  # conditions on the :sub claim across all trust statements.
  echo "$trust_json" | jq -r '
    .Statement[]
    | .Condition // {}
    | (.StringEquals // {}), (.StringLike // {})
    | to_entries[]
    | select(.key | endswith(":sub"))
    | .value
    | if type == "array" then .[] else . end
    | select(startswith("system:serviceaccount:"))
  '
}
```

This tolerates `StringEquals` and `StringLike`, both single-string and
array-string `:sub` values, and any number of trust statements. The
`endswith(":sub")` match covers the canonical OIDC key
`oidc.eks.<region>.amazonaws.com/id/<id>:sub` without requiring the
cluster's OIDC provider URL. No account ID or OIDC ARN is hardcoded
(AGENTS.md §8.1); the role ARN is derived at runtime.

### 5.2 A2-005: trust subject → SA existence (test 12)

Algorithm:

1. Extract all `namespace_service_accounts` values from
   `terraform/management/irsa.tf` using the same `grep -oE` regex as
   SPEC-B2 (`"[a-z0-9-]+:[a-z0-9-]+"` within `namespace_service_accounts`
   blocks). For each `<ns>:<sa>`:
2. Resolve the IRSA role ARN: prefer `terraform output -json irsa_role_arns`
   when state is accessible; fall back to `aws iam list-roles
   --path-prefix /k8-platform-mgmt-` and match by name prefix.
3. Call `irsa_trust_subjects_for_arn` from `lib/irsa_trust.sh`.
4. Assert the result list contains `system:serviceaccount:<ns>:<sa>`.
5. Assert `kubectl get sa -n <ns> <sa>` exits 0.

Both assertions must pass for a subject to pass. Either failure names the
offending subject in the `FAIL` message.

Failure message format (for operator clarity):

```
FAIL [A2-005]: trust subject crossplane-system:upbound-provider-family-aws
  → role arn:aws:iam::<acct>:role/k8-platform-mgmt-crossplane
  → SA crossplane-system/upbound-provider-family-aws: not found on cluster
  → This is the PR #66 class of bug. Fix: pin the SA name in the
    DeploymentRuntimeConfig or Helm values before applying.
```

### 5.3 A2-006: SA annotation → role trust (test 13)

Algorithm:

1. List every SA with the annotation:
   ```bash
   kubectl get sa -A -o json \
     | jq -r '.items[]
       | select(.metadata.annotations["eks.amazonaws.com/role-arn"] != null)
       | .metadata.namespace + ":" + .metadata.name + " "
         + .metadata.annotations["eks.amazonaws.com/role-arn"]'
   ```
2. For each `(<ns>, <sa>, <role-arn>)` triple:
   - Call `irsa_trust_subjects_for_arn <role-arn>`.
   - Assert the result list contains
     `system:serviceaccount:<ns>:<sa>`.

Failure message format:

```
FAIL [A2-006]: SA external-dns/external-dns
  annotated with role arn:aws:iam::<acct>:role/k8-platform-mgmt-external-dns
  but system:serviceaccount:external-dns:external-dns is NOT in that role's
  trust policy.
  → STS will reject AssumeRoleWithWebIdentity for this SA.
  → Trust subjects found: [system:serviceaccount:external-dns:ext-dns-old]
  → Fix: update the IRSA trust policy or correct the SA annotation.
```

### 5.4 Prerequisites and skip conditions

Both tests source `tests/integration/lib/helpers.sh` (`ok`/`fail`/`skip`/
`summary`) and require: `kubectl` configured to the management cluster;
`jq` on PATH; `aws iam get-role` accessible (skip with
`skip "IAM read unavailable"` if the first call fails); phase 1 deployed.
Each test uses the `phase_deployed_or_skip 1` guard pattern from
`08_irsa_sts_round_trip.sh`.

### 5.5 Performance and output budget

Test 12 calls `aws iam get-role` once per IRSA role (4 in the current
repo). Test 13 calls it once per unique role ARN found via `kubectl get
sa -A`. Both complete under 20s. `FAIL` output is capped at ≤10 lines per
subject; if more than 5 subjects fail, the first 5 are shown in full and
a summary line "... N more failures suppressed, re-run with
`IRSA_VERBOSE=1`" is appended.

### 5.6 Relationship to SPEC-B2 and SPEC-B4

These integration tests are the middle layer of a three-layer defense:
SPEC-B2 (static lint, PR author time) → LB3 (integration, scheduled) →
SPEC-B4 (Kyverno audit, continuous). If B2 passes and LB3 fails, the SA
pin is in source but was not created on the cluster. If B4 also fires,
both name the same defect: Kyverno names the SA, LB3 names the role ARN.

## 6. Tests required

Per AGENTS.md §6.1 and §6.2, the following tests must exist before the
spec is considered complete.

| Layer | File | Assertion |
|---|---|---|
| Integration | `tests/integration/12_irsa_trust_subjects_exist.sh` | For every `namespace_service_accounts` entry in `irsa.tf`, the named SA exists on the cluster AND the role's trust policy lists it. Exits 1 if any subject fails either check. |
| Integration | `tests/integration/13_irsa_sa_annotations_valid.sh` | For every IRSA-annotated SA on the cluster, the annotated role's trust policy contains `system:serviceaccount:<ns>:<sa>`. Exits 1 if any SA fails. |
| Unit (meta) | `tests/unit/test_irsa_trust_helper.sh` | Static checks on `lib/irsa_trust.sh`: (a) given a fixture JSON produced by `aws iam get-role`, `irsa_trust_subjects_for_arn` outputs the correct `system:serviceaccount:` strings; (b) an empty or missing Condition block produces zero output without error; (c) an array-valued `:sub` entry is expanded correctly (covers the StringEquals multi-value case). Uses a fixture JSON file — no live AWS call. |
| Unit (meta) | extend `tests/unit/test_irsa_helm_linkage.sh` or add separate driver | TDD reproduction: a fixture irsa.tf with a `namespace_service_accounts = ["ghost:missing-sa"]` entry passes the static SPEC-B2 lint (no pin required by B2) but has no SA on the cluster — confirm test 12's logic would flag it. Fixture-based, no cluster needed. |

TDD sequence (§6.2): author the fixture JSON for `test_irsa_trust_helper.sh`
first; run against a stub helper that always returns empty — confirm red;
implement the helper — confirm green. Land unit meta-test and integration
scripts in the same PR.

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast, fixture-based, no cluster or AWS credentials needed.

- Case 1 — **StringEquals single string**: fixture trust JSON with one
  `:sub` value; assert helper outputs
  `system:serviceaccount:crossplane-system:upbound-provider-family-aws`.
- Case 2 — **StringEquals array**: `:sub` is a JSON array of two subjects;
  assert both are emitted on separate lines.
- Case 3 — **StringLike**: wildcard subject is extracted without error.
- Case 4 — **no Condition block**: trust statement without `Condition`
  produces zero output and exits 0.
- Case 5 — **cross-account skip**: `aws iam get-role` exits non-zero
  (simulated); helper writes a `SKIP:` line to stderr, returns 1, no
  stdout output.

### Integration

Live management cluster required; phase 1 must be deployed.
Numbers slot after existing test 11.

- `12_irsa_trust_subjects_exist.sh` happy path: all four current IRSA roles
  (`argocd`, `crossplane`, `eso`, `external-dns`) resolve to live SAs —
  all checks pass.
- `12_irsa_trust_subjects_exist.sh` with `IRSA_SA_OVERRIDE=test-ns:ghost-sa`
  (manual regression flag): exits 1 with a message containing `ghost-sa`.
  Document in the script header; not run by the automated suite.
- `13_irsa_sa_annotations_valid.sh` happy path: all IRSA-annotated SAs have
  `(ns, name)` in the trust policy of the annotated role.
- `13_irsa_sa_annotations_valid.sh` negative probe: annotate
  `default/probe-bad` with the crossplane role ARN (trust subject is
  `crossplane-system`, not `default`) — exits 1. Manual step; clean up
  the probe SA after.
- Both tests after a fresh `terraform apply` that changes an IRSA trust
  policy — confirm no stale subjects remain.

### E2E

E2E coverage is already wired: `terraform-test.yml`'s `[management]
e2e-verify` step dispatches `tests/integration/run.sh`; both LB3 tests run
automatically after a phase-1 apply. No new chainsaw scenario is needed —
the bidirectional invariant is not a Crossplane Composition or XRD (see
AGENTS.md §6.1 chainsaw scope). A future extension could add an
`03-integration-invariants/` step to SPEC-B4's existing
`tests/chainsaw/irsa-sa-trust-existence/` scenario to cover the PR #68
class (pod mounted on wrong SA at claim-ready time). Advisory, not a gate.

## 8. Documentation updates

- `/home/user/k8-platform/ai/TESTING-PLAN.md` — add two rows to the
  bug-to-test traceability matrix: PR #66 / Bug 5 → integration /
  `12_irsa_trust_subjects_exist.sh` (A2-005); PR #66 / Bug 5 → integration
  / `13_irsa_sa_annotations_valid.sh` (A2-006).
- `/home/user/k8-platform/tests/integration/README.md` — add rows for
  tests 12 and 13 to the test-table, with the one-line contract for each.
- `/home/user/k8-platform/ai/handoff.md` — under "IRSA failure checklist"
  (or create if absent), add: "Run `tests/integration/12_irsa_trust_subjects_exist.sh`
  and `13_irsa_sa_annotations_valid.sh` first — they name the exact SA and
  role where the invariant is broken."
- `/home/user/k8-platform/AGENTS.md` §6.1 — no structural change needed;
  the implementing PR description should cite this spec and brainstorm IDs
  A2-005 / A2-006.

## 9. Workflow / auto-invocation wiring

- **`tests/integration/run.sh`**: the existing runner auto-discovers
  `[0-9][0-9]_*.sh` via `ls | sort`; dropping the files in the directory
  is sufficient — no explicit registration line needed.
- **`terraform-test.yml` `[management] e2e-verify` step**: already
  dispatches `run.sh` after apply; no workflow YAML change required.
- **Manual regression dispatch**: both scripts run standalone from any
  environment with `kubectl` + `aws` configured. Document in each header.
- No pre-commit hook needed; the unit meta-test fires on every push via
  `.github/workflows/unit-tests.yml`.

## 10. Discoverability

1. **Mechanical enforcement**: `tests/integration/run.sh` is dispatched in
   the `[management] e2e-verify` CI step; either invariant violation turns
   the job red and names the exact SA and role in the failure message.
2. **Documentation pointer**: `ai/TESTING-PLAN.md` rows for PR #66 / Bug 5
   cite both test files with brainstorm IDs A2-005 / A2-006; any agent
   triaging a new IRSA failure lands on the canonical test to run.
3. **Adversarial-review trigger**: AGENTS.md §6.4 asks "does this test cover
   both directions of the failure?" — bidirectional framing (trust→SA and
   SA→trust) is the required answer for any IRSA invariant test added in
   future; LB3 is the template.

## 11. Verification checklist

- [ ] `bash tests/unit/test_irsa_trust_helper.sh` exits 0 with all five
      fixture cases passing.
- [ ] `bash tests/unit/run.sh` exits 0 with no existing-suite regressions.
- [ ] `bash tests/integration/12_irsa_trust_subjects_exist.sh` exits 0 on a
      correctly-deployed phase-1 cluster.
- [ ] `bash tests/integration/13_irsa_sa_annotations_valid.sh` exits 0 on the
      same cluster.
- [ ] `ls tests/integration/12_*.sh tests/integration/13_*.sh` confirms both
      files exist; `bash tests/integration/run.sh` picks them up automatically.
- [ ] Negative probe: `kubectl annotate sa -n default probe-bad eks.amazonaws.com/role-arn=<crossplane-role-arn>` → test 13 exits 1 with message containing `default:probe-bad`. Clean up: `kubectl delete sa -n default probe-bad`.
- [ ] `IRSA_VERBOSE=1 bash tests/integration/12_irsa_trust_subjects_exist.sh`
      prints one line per subject checked.
- [ ] `grep "A2-005\|A2-006" ai/TESTING-PLAN.md` returns two rows.
- [ ] `grep -E '[0-9]{12}' tests/integration/12_*.sh tests/integration/13_*.sh`
      returns empty (no hardcoded account IDs, per AGENTS.md §8.1).

## 12. Rollout notes

- **Backward compatible**: both tests are read-only against the cluster (no
  mutations). Adding them to `run.sh` cannot break existing passing suites
  unless the cluster already has an IRSA invariant violation — in which case
  the test is doing its job.
- **Audit before merge**: before merging, run both tests against the live
  cluster to confirm they pass green. If either fails, that is a latent Bug 5
  recurrence; fix the cluster state in the same PR or open a blocking bug.
- **Pluralsight sandbox constraints** (per AGENTS.md): these tests run in
  us-east-1 / us-west-2 with standard EKS access; no Bedrock or Marketplace
  dependency; no EC2 changes; fully orthogonal to sandbox constraints.
- **Coordination / branch sequencing**: LB3 is independent of SPEC-B2 and
  SPEC-B4; the implementing branch can be cut from `main` at any time and
  merged in any order. Per `CLUSTERING-REVIEW.md`, all three are Tier-B
  items with no code dependency between them.

## 13. Estimated effort

**M** (1–3 hours).

Breakdown: `lib/irsa_trust.sh` helper (jq parsing, skip handling) ~30 min;
`12_irsa_trust_subjects_exist.sh` (irsa.tf regex + SA existence) ~45 min;
`13_irsa_sa_annotations_valid.sh` (kubectl scan + trust lookup) ~30 min;
`test_irsa_trust_helper.sh` with five fixture cases ~30 min; rollout audit
on live cluster (both tests green, negative probe red) ~20 min; doc updates
and adversarial-review cycle (AGENTS.md §6.4) ~15 min. Total ~3 hours —
upper end of `M`. Dominant cost is the rollout audit, which requires a
deployed phase-1 environment; if the account was rotated, add ~30 min for
a fresh apply before running the integration suite.
