# SPEC-LB8 — Kyverno apiVersion + fail-open lint

Tier: B | Brainstorm ID: A3-058 (extended by A1→A3-010) | CLUSTERING-REVIEW.md Cluster 2

## 1. Summary

Extend `tests/unit/test_kyverno_policy_lint.sh` with two new check blocks
that assert (a) every Kyverno ClusterPolicy in `policies/audit/` and
`crossplane/policies/` declares `apiVersion: kyverno.io/v1` — no
`v1beta1` or any other version — and (b) an explicit `failurePolicy: Fail`
anywhere in a policy is accompanied by both `kyverno.io/fail-open-reviewed: "true"`
and `kyverno.io/fail-open-reason: <text>` in `metadata.annotations`. Check
(a) is API-drift detection: cheap, static, `yq`-based, under one second.
Check (b) defends against the silent-half-brick failure mode where a
`failurePolicy: Fail` webhook setting blocks all admission cluster-wide
when Kyverno is unreachable, with no PolicyReport emitted. Both checks
fire on every push via the existing `unit-tests.yml` workflow. No new
files are needed beyond four fixture stubs; everything wires through the
existing lint runner.

## 2. Retro pain killed

- **PR #64, Bug 3 (ArgoCD OutOfSync drift)** — `crossplane/policies/09-platform-secret-namespace-allowed.yaml`
  was authored without `spec.admission` and `pod-policies.kyverno.io/autogen-controllers`
  explicitly set (`retrospective/2026-05-25-70.md`, Phase 2 cleanup). The
  existing checks §3/§4 catch that class. LB8 adds the analogous
  authoring-time guard for the two remaining unchecked fields: `apiVersion`
  and `failurePolicy`.

- **Silent fail-open class (brainstorm A1→A3-010)** — a Kyverno webhook in
  `Fail` mode that becomes temporarily unreachable (crash-loop, rolling
  upgrade) blocks all admission with no PolicyReport and no auto-recovery.
  The existing check §3 asserts `validationFailureAction: Audit` — that
  field governs what happens on a policy *match*; `failurePolicy` governs
  what happens when the webhook is *down*. Orthogonal risk surface, zero
  coverage today.

- **`v1beta1` API drift gap (brainstorm A3-058)** — Kyverno removed
  `v1beta1` in 1.9; applying a policy with the old apiVersion produces
  "no matches for kind ClusterPolicy" instead of a clear error. The
  existing lint does not assert `apiVersion` at all, so a community
  ClusterPolicy copied with the wrong apiVersion passes the unit suite
  and only fails during a live management bring-up, costing a full
  apply round.

- **`test_kyverno_policy_lint.sh` coverage gap on new fields** — the
  four existing checks cover JMESPath backtick literals, metadata.name,
  validationFailureAction, and drift-defense fields. Two common authoring
  mistakes — wrong apiVersion and unreviewed `failurePolicy: Fail` — are
  unchecked. LB8 closes both.

## 3. Out of scope

- **Mandating `failurePolicy: Ignore`.** LB8 does not prescribe the value;
  it only fires when `Fail` is explicit and the reviewed annotation pair is
  absent. The value choice is a per-policy design decision.

- **Auditing live `ValidatingWebhookConfiguration` objects.** Checking the
  webhook object Kyverno creates is an integration-layer concern; LB8 is a
  unit lint over YAML source.

- **`kyverno.io/v2` or pre-release versions.** The lint asserts `kyverno.io/v1`
  exclusively, matching the currently installed version and all nine existing
  policies. When Kyverno publishes a stable v2, update the constant.

- **Kyverno YAML outside `policies/audit/` and `crossplane/policies/`.**
  Chainsaw test YAML references Kyverno kinds but is not a ClusterPolicy;
  the lint skips files where `.kind != ClusterPolicy`.

### Considered and rejected

- **New standalone `test_kyverno_apiversion_lint.sh`.** Rejected — the
  existing file already iterates the same `POLICY_DIRS`, uses the same `yq`
  idiom, and is already in `run.sh`. Two small checks do not warrant a new
  file. Pattern mirrors SPEC-B1's consolidation from two files into one.

- **`kyverno cli` or `kyverno-json` for validation.** Rejected — neither
  binary is pinned in the repo; `yq` already covers the two field checks
  without a new toolchain dependency.

- **Annotation key `policies.kyverno.io/fail-open-reviewed`.** Rejected —
  the `policies.kyverno.io/` namespace is already used for title/category/
  severity/description metadata. The `kyverno.io/` prefix is the
  conventional namespace for operational annotations, consistent with
  `pod-policies.kyverno.io/autogen-controllers` in the existing policies.

## 4. Files to change / create

| Path | What changes |
|------|-------------|
| `/home/user/k8-platform/tests/unit/test_kyverno_policy_lint.sh` | Append check §5 (apiVersion) and check §6 (failurePolicy annotation pair) after the existing §4 block. No existing checks touched. |
| `/home/user/k8-platform/tests/unit/fixtures/kyverno_policy_lint/should_fail_wrong_apiversion.yaml` | New fixture: ClusterPolicy with `apiVersion: kyverno.io/v1beta1`. |
| `/home/user/k8-platform/tests/unit/fixtures/kyverno_policy_lint/should_pass_correct_apiversion.yaml` | New fixture: ClusterPolicy with `apiVersion: kyverno.io/v1`. |
| `/home/user/k8-platform/tests/unit/fixtures/kyverno_policy_lint/should_fail_fail_policy_no_annotation.yaml` | New fixture: ClusterPolicy with `failurePolicy: Fail`, no reviewed annotations. |
| `/home/user/k8-platform/tests/unit/fixtures/kyverno_policy_lint/should_pass_fail_policy_annotated.yaml` | New fixture: ClusterPolicy with `failurePolicy: Fail` and both required annotations present. |

No changes to `tests/unit/run.sh` or `.github/workflows/unit-tests.yml` —
the existing `run_suite` line and `test_kyverno_policy_lint` CI step already
pick up the extended script.

## 5. Implementation notes

### Check §5 — apiVersion must be `kyverno.io/v1`

Iterates `POLICY_DIRS` (same bash array as checks 1–4). For each file
with `.kind == ClusterPolicy`, reads `.apiVersion` via `yq -r` and
compares against the constant `EXPECTED_APIVERSION="kyverno.io/v1"`. On
mismatch, calls `_fail` with the filename and the observed value. Pattern
is identical to the existing check §3 (`validationFailureAction`) with one
field substituted. Performance: negligible — `yq` reads on nine files
complete in well under one second.

### Check §6 — `failurePolicy: Fail` requires reviewed annotation pair

`failurePolicy` may appear at `spec.failurePolicy` (top-level) or at
`spec.rules[N].failurePolicy` (per-rule override). The check extracts
both locations:

```bash
top_fp=$(yq -r '.spec.failurePolicy // "unset"' "$yaml_path")
rule_fp=$(yq -r '.spec.rules[].failurePolicy // empty' "$yaml_path" | sort -u)
```

If either yields `Fail`, the check reads:

```bash
reviewed=$(yq -r '.metadata.annotations["kyverno.io/fail-open-reviewed"] // ""' "$yaml_path")
reason=$(yq -r  '.metadata.annotations["kyverno.io/fail-open-reason"]    // ""' "$yaml_path")
```

Pass condition: `reviewed == "true"` AND `reason` is non-empty and not
`"null"`. Otherwise `_fail` emits a message naming the file and the
missing annotation keys.

**Annotation pattern for intentional `failurePolicy: Fail`:**

```yaml
metadata:
  annotations:
    kyverno.io/fail-open-reviewed: "true"
    kyverno.io/fail-open-reason: >-
      This policy enforces namespace isolation for XRD claims. A bypassed
      webhook would allow unconstrained claim creation. Kyverno runs with
      PodDisruptionBudget minAvailable=1 (platform-services/kyverno/values.yaml).
      Reviewed 2026-05-25. See ADR-XXX.
spec:
  failurePolicy: Fail
```

The `fail-open-reason` value is free text; the lint asserts non-empty only.
Prose quality is a code-review concern.

**Policies that omit `failurePolicy` entirely do not need any annotation.**
Kyverno's effective default for audit-mode background scans is `Ignore`,
which is the safe posture. Only an explicit `Fail` triggers the check.

**Cross-reference:** check §3 (validationFailureAction) and LB8 check §6
are orthogonal. §3 guards what happens on a policy *match*; §6 guards what
happens when the webhook is *down*.

**Output budget:** each violation emits one `FAIL:` line via the existing
`_fail` helper, under 200 characters, naming the file and the missing keys.
`assert_summary` at the script's end accumulates counts and exits 1.

## 6. Tests required

Per AGENTS.md §6.1 and §6.4:

| Layer | File | Assertion |
|-------|------|-----------|
| Unit (meta) | `test_kyverno_policy_lint.sh` | Lint against `should_fail_wrong_apiversion.yaml` — exit 1, `FAIL: policy_apiversion_kyverno_v1:…` names `v1beta1`. |
| Unit (meta) | same | Lint against `should_pass_correct_apiversion.yaml` — exit 0, `PASS:` line present. |
| Unit (meta) | same | Lint against `should_fail_fail_policy_no_annotation.yaml` — exit 1, `FAIL: policy_failurepolicy_reviewed:…` names missing annotation pair. |
| Unit (meta) | same | Lint against `should_pass_fail_policy_annotated.yaml` — exit 0, `PASS:` line present. |
| Unit (regression) | same | All nine current `policies/audit/` and `crossplane/policies/` files pass both new checks without modification — zero-violation baseline. |

Each fixture *is* the bug; the lint *is* the catching test. If the `yq`
path or comparison logic regresses, the meta-fixture fails immediately
on the next push.

§6.4 adversarial-reviewer trigger: spawn one general-purpose subagent
before authoring check §6. Expected adversarial findings: `yq // empty`
vs `// "unset"` null-handling differences between yq 4.x and 3.x, and
a policy where `failurePolicy: Fail` appears at both levels simultaneously.

## 7. Testing suggestions (unit / integration / e2e)

### Unit

1. **v1beta1 in `crossplane/policies/` path.** A fixture scoped to the
   `crossplane/policies` scan path verifies both directory entries in
   `POLICY_DIRS` are exercised by check §5, not just `policies/audit/`.

2. **Per-rule `failurePolicy: Fail`, no top-level.** Fixture with `failurePolicy`
   set at `spec.rules[0].failurePolicy` only, no annotation. Asserts the
   per-rule extraction arm of check §6 fires independently of the top-level
   arm.

3. **Partial annotation (reviewed flag present, reason absent).** Fixture
   with only `kyverno.io/fail-open-reviewed: "true"`. Asserts the lint
   rejects the half-annotated case — prevents the "flag without
   justification" shortcut.

4. **Non-ClusterPolicy YAML skipped.** A `kind: Policy` (namespaced) file
   with `apiVersion: kyverno.io/v1beta1` — assert lint returns `PASS`,
   confirming the `.kind == ClusterPolicy` filter applies correctly.

5. **Future pre-release version rejected.** `apiVersion: kyverno.io/v2alpha1`
   in a ClusterPolicy — assert lint rejects it, keeping the pinned-version
   contract explicit.

### Integration

Not applicable. LB8 is a pure static lint over YAML sources; no live
cluster, Kyverno instance, or AWS API calls are required. The integration
layer for Kyverno policy correctness is the existing `scripts/kyverno-policies.sh`
and `scripts/kyverno-violations.sh` invoked from AGENTS.md §6.3 after
every fresh apply-and-verify. Adding an integration assertion for
`apiVersion` would duplicate the Kubernetes API server's own rejection
of a wrong-versioned resource — not a useful additional signal.

### E2E

Not applicable. A Chainsaw scenario verifying `apiVersion: kyverno.io/v1`
resolves at runtime tests the Kubernetes API server and CRD installation,
not the platform's authoring hygiene. The unit lint covers the
authoring-time contract; the live-cluster verification belongs to the
existing integration scripts.

## 8. Documentation updates

- `AGENTS.md §6.1` test-layers table — add a note to the "Kyverno audit
  policy" row: *"apiVersion and failurePolicy correctness enforced at unit
  time by checks §5–§6 of `test_kyverno_policy_lint.sh`. Any policy with
  `failurePolicy: Fail` requires the annotation pair
  `kyverno.io/fail-open-reviewed: "true"` and `kyverno.io/fail-open-reason: <text>`."*

- `ai/testing-guidelines.md` — add a "Kyverno policy authoring constraints"
  subsection listing all six lint invariants (checks 1–4 existing, 5–6 new)
  with the annotation syntax for the `failurePolicy: Fail` reviewed pair.

- `policies/audit/README.md` — add one sentence to the Authoring section:
  *"Every ClusterPolicy must use `apiVersion: kyverno.io/v1`. Any policy
  declaring `failurePolicy: Fail` must carry the annotation pair
  `kyverno.io/fail-open-reviewed: "true"` + `kyverno.io/fail-open-reason` — see SPEC-LB8."*

## 9. Workflow / auto-invocation wiring

No new wiring is required. The existing chain covers all three trigger
points:

1. **CI on every push** — `.github/workflows/unit-tests.yml` runs the
   `test_kyverno_policy_lint` step; the two new checks are in the same
   script, fire automatically, no step changes needed.

2. **Local pre-apply** — `tests/unit/run.sh` already includes
   `run_suite tests/unit/test_kyverno_policy_lint.sh`; authors see
   violations before pushing.

3. **Management bring-up gate** — AGENTS.md §6.3 requires `tests/unit/run.sh`
   as step 1 of the full test bundle after every fresh apply-and-verify.

## 10. Discoverability

1. **Mechanical enforcement.** A ClusterPolicy with `apiVersion: kyverno.io/v1beta1`
   or with `failurePolicy: Fail` and no annotation fails the
   `unit-tests.yml` workflow on the first push. The `FAIL:` line names
   the file, the check name, and the violation. No human memory required.

2. **Documentation pointer.** AGENTS.md §6.1's test-layers table (after
   the §8 update) lists the Kyverno policy lint and the `failurePolicy`
   annotation requirement. A future agent scanning §6.1 for "what tests
   cover Kyverno policies?" lands on the rule without reading this spec.

3. **Adversarial-review trigger.** AGENTS.md §6.4's known-bug-classes
   table should list the `failurePolicy: Fail` silent-half-brick class
   so any future spec proposing a new enforcing policy is challenged to
   explain why `Fail` is safe in that context before the test plan is
   accepted.

## 11. Verification checklist

- [ ] `bash tests/unit/test_kyverno_policy_lint.sh` exits 0 on the current
  repo state. New `PASS:` lines for `policy_apiversion_kyverno_v1:*` and
  `policy_failurepolicy_reviewed:*` are visible for all nine existing files.

- [ ] `bash tests/unit/run.sh` exits 0 and includes the above output.

- [ ] Manual probe — apiVersion: temporarily change `apiVersion: kyverno.io/v1`
  to `apiVersion: kyverno.io/v1beta1` in `policies/audit/01-argocd-server-irsa.yaml`,
  run the lint, confirm exit 1 and
  `FAIL: policy_apiversion_kyverno_v1:01-argocd-server-irsa.yaml`. Revert.

- [ ] Manual probe — failurePolicy: temporarily add `failurePolicy: Fail`
  under `spec:` in `crossplane/policies/09-platform-secret-namespace-allowed.yaml`,
  run the lint, confirm exit 1 and
  `FAIL: policy_failurepolicy_reviewed:09-platform-secret-namespace-allowed.yaml`
  naming the missing annotation pair. Revert.

- [ ] Add both required annotations to the same policy alongside
  `failurePolicy: Fail`, re-run the lint, confirm exit 0. Revert.

- [ ] With `POLICY_DIRS=("tests/unit/fixtures/kyverno_policy_lint")` each
  of the four new fixtures produces the expected `PASS:` or `FAIL:` outcome.

- [ ] `grep -r "kyverno.io/v1beta1" /home/user/k8-platform/policies/ \
  /home/user/k8-platform/crossplane/policies/ --include="*.yaml"` returns
  zero results.

- [ ] `.github/workflows/unit-tests.yml` `test_kyverno_policy_lint` step is
  unchanged — no new step added.

## 12. Rollout notes

**Backward compatibility.** All nine existing ClusterPolicies use
`apiVersion: kyverno.io/v1` and none set `failurePolicy: Fail`. The new
checks pass on day one with no fix pass required — same zero-cost-rollout
pattern as checks §3 and §4 in the existing lint.

**Audit before merge.** Run these two greps before opening the PR:

```
grep -r "kyverno.io/v1beta1"  /home/user/k8-platform/ --include="*.yaml"
grep -rn "failurePolicy: Fail" /home/user/k8-platform/policies/ \
  /home/user/k8-platform/crossplane/policies/ --include="*.yaml"
```

Expected: zero results on both. Any hit must be fixed or annotated in the
same PR before the CI step is wired.

**Triage of all existing ClusterPolicies:**

| File | apiVersion | failurePolicy: Fail? | Action |
|------|-----------|----------------------|--------|
| `policies/audit/01-argocd-server-irsa.yaml` | `kyverno.io/v1` | No | No change. |
| `policies/audit/02-ingress-must-have-class.yaml` | `kyverno.io/v1` | No | No change. |
| `policies/audit/03-ingress-managed-by-external-dns.yaml` | `kyverno.io/v1` | No | No change. |
| `policies/audit/04-irsa-rolearn-format.yaml` | `kyverno.io/v1` | No | No change. |
| `policies/audit/05-no-default-sa-with-workload.yaml` | `kyverno.io/v1` | No | No change. |
| `policies/audit/06-image-tag-not-latest.yaml` | `kyverno.io/v1` | No | No change. |
| `policies/audit/07-helm-release-labels-required.yaml` | `kyverno.io/v1` | No | No change. |
| `policies/audit/08-external-dns-annotation-on-services.yaml` | `kyverno.io/v1` | No | No change. |
| `crossplane/policies/09-platform-secret-namespace-allowed.yaml` | `kyverno.io/v1` | No | No change. |

**Future policies.** Any policy warranting `failurePolicy: Fail` (most
likely a namespace-isolation or security-enforcement rule) must include the
annotation pair in the same commit. The annotation forces the decision into
git history at point-of-introduction rather than discovery in a
post-incident review.

**Sandbox constraints.** Pure unit-time lint; no EC2, no AWS API calls,
no Bedrock/Marketplace dependency. Orthogonal to Pluralsight sandbox
constraints.

**Branch sequencing.** No dependency on any in-flight SPEC or PR. Land on
`feat/kyverno-apiversion-failpolicy-lint` off `main` independently.

## 13. Estimated effort

**S** — small (≤1 hr).

The bash pattern for both checks is established by the existing four checks;
each new check is ~15 lines of `yq` + `_pass`/`_fail` calls. The four
fixture stubs are ~15 lines each. The rollout audit (two `grep` calls
against nine known-clean files) is five minutes. Documentation updates are
one paragraph each across three files. The adversarial-reviewer subagent
dispatch adds ~10 minutes. The manual smoke-test (§11 temporary edits)
adds ~15 minutes. Total: approximately 60 minutes. Effort is `S` because
the implementing agent inherits all scaffolding — lint runner, fixture
directory, CI wiring, `yq` idiom — from the existing
`test_kyverno_policy_lint.sh`. The only genuinely new design surface is
the annotation key convention for `failurePolicy: Fail`, fully specified
in §5.
