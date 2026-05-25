# SPEC-LB6 — `test_drc_sa_pinned.sh`: every IRSA-bearing DeploymentRuntimeConfig has a non-empty SA name pin

**Brainstorm ID:** A3-019  
**Larger-list tier:** B6  
**Suite membership:** "IRSA binding integrity" — pairs with SPEC-B2 (`test_irsa_sa_pinned.sh`) and
shares the `tests/unit/_lib/hcl_extract.sh` parser helper introduced by SPEC-B3.  
**Priority:** B-tier (priority directive from user, 2026-05-25)

---

## 1. Summary

Add a pure-local unit test that statically validates every `DeploymentRuntimeConfig` manifest
in the repository — whether stored as a standalone YAML file under `crossplane/` or inlined as
an HCL `local.*_manifest` heredoc in `terraform/management/helm.tf` — has a non-empty string
at `spec.serviceAccountTemplate.metadata.name`. A missing or empty name is the direct
authoring-time condition that caused Bug 5 / PR #66: Crossplane generated a revision-hash-suffixed
SA (`provider-family-aws-24aaab54a3a0`) because the pin was absent, the IRSA trust policy's
`StringEquals` on `crossplane-system:upbound-provider-family-aws` rejected every
`AssumeRoleWithWebIdentity`, and every ASM Secret MR stalled `Ready=False` with no
`atProvider.arn`. This spec is the direct-defending lint for that exact omission.

The test lives at `tests/unit/test_drc_sa_pinned.sh`, reuses the
`tests/unit/_lib/hcl_extract.sh` helper (introduced by SPEC-B3 for HCL block extraction) to
parse inline heredoc manifests from `helm.tf`, and uses `yq` to parse standalone YAML files.
It is one of three interlocking tests in the IRSA binding integrity suite: SPEC-B2 checks that
every IRSA role has a matching SA pin somewhere in-repo; this spec checks that the DRC itself
carries the pin; and SPEC-B4 (Kyverno audit policy) checks the live cluster continuously at
runtime. Part of Cluster 2 per `CLUSTERING-REVIEW.md`.

---

## 2. Retro pain killed

- **PR #66 — direct root cause.** `retrospective/2026-05-25-70.md` Phase 2: the
  `DeploymentRuntimeConfig` in `local.crossplane_aws_provider_manifest` had no
  `spec.serviceAccountTemplate.metadata.name` field. Crossplane defaulted to a
  revision-hash-derived SA name (`provider-family-aws-24aaab54a3a0`). The IRSA trust policy
  (irsa.tf:98) bound to `crossplane-system:upbound-provider-family-aws` rejected every
  `AssumeRoleWithWebIdentity`. Symptom: every ASM Secret MR stalled `Ready=False`, no
  `atProvider.arn`, PlatformSecret claims sat `Waiting` forever. Diagnosed only via subagent
  extraction of 166 KB logs from phase-2-diagnose run 26353150253.
- **PR #67 — compounded miss.** The PR #66 fix edited the manifest body but
  `triggers_replace` did not hash the manifest local, so the apply silently no-op'd
  (`Apply complete! 0 added, 0 changed, 0 destroyed` on run 26354235231). PR #67 added the
  hash. This spec catches the upstream omission (no SA pin) before the triggers_replace
  question even arises.
- **PR #68 — third link.** Even after the pin applied, the running pod was still mounted on
  the old SA because Crossplane's Provider controller only re-renders its Deployment when the
  Provider object changes. PR #68 added a `kubectl delete deploy` step. This spec fires at
  authoring time and prevents the whole three-PR cascade from starting.
- **Silent failure class.** `retrospective/2026-05-25-70.md` metrics: "Apply success is
  necessary, not sufficient." This lint catches the omission before any apply, bypassing the
  apply-then-diagnose cycle entirely.
- **A6 cross-comment (brainstorm.json A6→A3-008).** A3-018 and A3-019 "collapse into one IRSA
  binding integrity suite." This spec implements that: the test is registered adjacent to
  `test_irsa_sa_pinned.sh` in `run.sh` so the two fire as a logical group.

---

## 3. Out of scope

- **Does NOT validate the IRSA trust policy itself.** Whether the `Condition.StringEquals`
  subject in `irsa.tf` is syntactically correct, or whether the OIDC provider ARN resolves, is
  out of scope. `test_irsa_sa_pinned.sh` (SPEC-B2) owns the cross-check that the DRC's pinned
  name matches the IRSA trust subject.
- **Does NOT check that the IRSA annotation is present on the `serviceAccountTemplate`.**
  The `eks.amazonaws.com/role-arn` annotation is a separate concern. SPEC-B2's source (1) check
  and the Kyverno audit policy (SPEC-B4) cover that side.
- **Does NOT verify the SA exists at runtime.** Live cluster state is SPEC-B4's domain.
  This test fires at PR-author time on a cold checkout.
- **Does NOT lint `DeploymentRuntimeConfig` fields other than the SA name pin.** Toleration
  settings, resource requests, extra volumes — those are policy concerns, not IRSA binding
  concerns.
- **Does NOT cover Crossplane `ControllerConfig` (deprecated v1 API).** The repo has migrated
  to `DeploymentRuntimeConfig` (v1beta1). If a `ControllerConfig` resurfaces, it belongs to a
  separate spec.

### Considered and rejected

- **Use `yq` for all parsing including the HCL heredoc.** Requires stripping `${...}`
  interpolations or a live backend. The `hcl_extract.sh` helper from SPEC-B3 handles this
  cleanly without a network call. Reusing it is the right choice.
- **Combine this test into `test_irsa_sa_pinned.sh` (SPEC-B2).** The two tests have different
  parse sources: SPEC-B2 parses `irsa.tf` for trust subjects and searches for matching pins;
  this spec parses DRC manifests and asserts the field is non-empty. Keeping them separate
  keeps each failure message focused. The A6 "collapse into a suite" comment is satisfied by
  co-locating them in `run.sh`.
- **Single giant regex over all `.tf` and `.yaml` files.** Unmaintainable and misses
  multi-document YAML where a DRC is document 1 of N. The document-walking approach is more
  robust.

---

## 4. Files to create / modify

### Create

| Path | What |
|---|---|
| `/home/user/k8-platform/tests/unit/test_drc_sa_pinned.sh` | Main lint script (see §5) |
| `/home/user/k8-platform/tests/unit/fixtures/drc_sa_pinned/` | Fixture corpus (see §6) |
| `/home/user/k8-platform/tests/unit/fixtures/drc_sa_pinned/passing/drc_with_pin.yaml` | Single DRC with `metadata.name` set — test must pass |
| `/home/user/k8-platform/tests/unit/fixtures/drc_sa_pinned/passing/multi_doc_with_pin.yaml` | Two-document YAML (DRC + Provider) mirroring the actual `crossplane_aws_provider_manifest` shape — test must pass |
| `/home/user/k8-platform/tests/unit/fixtures/drc_sa_pinned/failing/drc_missing_sa_name.yaml` | DRC with `spec.serviceAccountTemplate.metadata.name` absent — test must fail naming the resource |
| `/home/user/k8-platform/tests/unit/fixtures/drc_sa_pinned/failing/drc_empty_sa_name.yaml` | DRC with `spec.serviceAccountTemplate.metadata.name: ""` — test must fail |
| `/home/user/k8-platform/tests/unit/fixtures/drc_sa_pinned/failing/pr66_repro.yaml` | Exact pre-PR #66 shape: `aws-provider-config` DRC with no `spec.serviceAccountTemplate` at all — the TDD bug reproduction |
| `/home/user/k8-platform/tests/unit/fixtures/drc_sa_pinned/passing/drc_no_irsa_annotation.yaml` | DRC with SA name pinned but no IRSA annotation — test must pass (IRSA annotation is out of scope for this lint) |

### Modify

| Path | What |
|---|---|
| `/home/user/k8-platform/tests/unit/run.sh` | Add `run_suite tests/unit/test_drc_sa_pinned.sh` adjacent to the `test_irsa_sa_pinned.sh` line |

---

## 5. Implementation notes

### 5.1 Two manifest sources

Every `DeploymentRuntimeConfig` in the repo appears in one of two forms:

1. **Standalone YAML** under `crossplane/`. Use `yq` to walk each file for documents of
   `kind: DeploymentRuntimeConfig` and extract `.spec.serviceAccountTemplate.metadata.name`.
2. **Inline heredoc** in `terraform/management/helm.tf` — the `local.crossplane_aws_provider_manifest`
   local value. Use `tests/unit/_lib/hcl_extract.sh` (introduced by SPEC-B3) to extract the
   raw YAML content between the `<<-MANIFEST` / `MANIFEST` markers, then pipe to `yq` for the
   same field extraction.

For source (2), the heredoc contains Terraform interpolation sequences (`${...}`). Strip them
with `sed 's/\${[^}]*}//g'` before handing to `yq`. This produces syntactically valid YAML
with empty strings at the interpolated positions — sufficient for structural field presence
checks.

### 5.2 Algorithm sketch

```
FAIL_COUNT=0

# --- Source 1: standalone YAML files ---
for yaml_file in $(find "${DRC_YAML_ROOT:-crossplane/}" -name "*.yaml"); do
  # yq multi-document walk: emit one line per DRC document
  while IFS= read -r sa_name; do
    if [[ -z "$sa_name" || "$sa_name" == "null" ]]; then
      fail "$yaml_file: DeploymentRuntimeConfig has empty or missing" \
           "spec.serviceAccountTemplate.metadata.name"
      (( FAIL_COUNT++ ))
    else
      pass "$yaml_file: DRC SA name pinned to '$sa_name'"
    fi
  done < <(yq eval-all \
    'select(.kind == "DeploymentRuntimeConfig") |
     .spec.serviceAccountTemplate.metadata.name // ""' \
    "$yaml_file")
done

# --- Source 2: inline heredocs in helm.tf ---
# hcl_extract.sh prints each local.*_manifest heredoc body to stdout,
# prefixed by the local name. The caller splits on that prefix.
while IFS= read -r manifest_body; do
  stripped=$(printf '%s' "$manifest_body" | sed 's/\${[^}]*}//g')
  while IFS= read -r sa_name; do
    if [[ -z "$sa_name" || "$sa_name" == "null" ]]; then
      fail "helm.tf (inline manifest): DeploymentRuntimeConfig has empty" \
           "or missing spec.serviceAccountTemplate.metadata.name"
      (( FAIL_COUNT++ ))
    else
      pass "helm.tf (inline manifest): DRC SA name pinned to '$sa_name'"
    fi
  done < <(printf '%s' "$stripped" | yq eval-all \
    'select(.kind == "DeploymentRuntimeConfig") |
     .spec.serviceAccountTemplate.metadata.name // ""' -)
done < <("${SCRIPT_DIR}/_lib/hcl_extract.sh" \
  "${HCL_TARGET:-terraform/management/helm.tf}" "_manifest")

[[ $FAIL_COUNT -eq 0 ]]
```

### 5.3 Dependency on `hcl_extract.sh`

`tests/unit/_lib/hcl_extract.sh` is introduced by SPEC-B3. If SPEC-B3 is not yet merged, stub
the helper for the `*_manifest` call shape in the same PR. Prefer the stub over inlining the
full extraction logic — it keeps the test self-contained and the stub is a one-function shim.

### 5.4 yq multi-document handling

The manifest local in `helm.tf` is a two-document YAML (DRC followed by Provider). `yq
eval-all 'select(.kind == "DeploymentRuntimeConfig") | ...'` correctly handles multi-document
streams and emits only DRC documents. For the YAML fixture files, the same `eval-all` call is
used; single-document files work because `eval-all` is a superset of `eval`.

### 5.5 Output format

One `PASS` or `FAIL` line per DRC encountered, using `pass` / `fail` / `summary` from
`tests/unit/lib/test-helpers.sh`. FAIL lines include the file path and the field path that
is empty or absent, so the author has the fix recipe verbatim. Expected:

```
PASS: crossplane/providers/aws-provider-config.yaml: DRC SA name pinned to 'upbound-provider-family-aws'
FAIL: crossplane/providers/new-provider.yaml: DeploymentRuntimeConfig has empty or missing spec.serviceAccountTemplate.metadata.name
SUMMARY: 1 passed, 1 failed
```

### 5.6 Performance

The lint scans a handful of YAML files and one HCL file. Expected runtime < 1 second on a cold
checkout. No AWS calls, no cluster calls, no `terraform init`.

### 5.7 False-positive handling

A `DeploymentRuntimeConfig` that legitimately has no `serviceAccountTemplate` at all (e.g. a
DRC used only to set tolerations on a non-IRSA provider) would be flagged as a false positive.
In practice, every DRC in this repo is IRSA-bearing — the SA name pin is non-negotiable. If a
non-IRSA DRC is ever added, the correct response is to add a
`# lint:drc_sa_pinned:ignore reason:<text>` comment on the YAML document's first line. The lint
greps for this marker before evaluating the document. An ignore entry without a reason string
is itself a lint failure (mirroring the allowlist convention in SPEC-B2).

---

## 6. Tests required

Per AGENTS.md §6.1 (author tests alongside features) and §6.4 (adversarial subagent review):

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_drc_sa_pinned.sh` | With `DRC_YAML_ROOT` and `HCL_TARGET` pointing at `fixtures/drc_sa_pinned/passing/`, the script exits 0 and emits one `PASS` line per fixture document. |
| Unit | same | With paths pointing at `fixtures/drc_sa_pinned/failing/`, the script exits non-zero and emits one `FAIL` line per offending document. |
| Unit | same | **TDD PR #66 reproduction.** `fixtures/.../failing/pr66_repro.yaml` (no `serviceAccountTemplate`) — the lint must exit non-zero and name the resource. This fixture is authored *before* the main script and the meta-test asserts it fails for the right reason (per AGENTS.md §6.2 steps 1–2). |
| Unit | same | **Empty-string case.** `drc_empty_sa_name.yaml` — `name: ""` — must fail, not pass. This guards against `yq` treating an empty string as truthy. |
| Unit | same | **Ignore marker.** A YAML with the `# lint:drc_sa_pinned:ignore reason:non-irsa-toleration` header and a missing SA name must pass. A YAML with the marker but no `reason:` component must fail with a "missing reason" message. |
| Unit | same | **Live-repo smoke.** With `DRC_YAML_ROOT` and `HCL_TARGET` unset (defaults to `crossplane/` and `terraform/management/helm.tf`), the script exits 0. This is the actual contract; the fixture tests above guard against the lint itself regressing. |

The meta-test for the `--self-test` flag (or a parallel `test_drc_sa_pinned_meta.sh`, same
choice as SPEC-B2 §6.1) must exist at implementation time. Before authoring fixtures, dispatch
one adversarial subagent per AGENTS.md §6.4 with the brief: "What DRC shapes appear in
`crossplane/*.yaml` and inline in `helm.tf` today that the lint will silently skip or falsely
flag?" Add fixtures for any shape it surfaces.

---

## 7. Testing suggestions (unit / integration / e2e)

**Unit** — fast bash/lint tests, < 10 s each:

- `test_drc_sa_pinned.sh --self-test`: all six fixture cases pass and fail as declared. This is
  the meta-test.
- Mutation test: temporarily comment out the `name: upbound-provider-family-aws` line in
  `terraform/management/helm.tf`; the live-repo smoke invocation exits non-zero. Restore the
  line; smoke passes.
- Fuzz the ignore marker: no `reason:` field, `reason:` with empty value, `reason:` with
  whitespace only — all three must fail.

**Integration** — against a live cluster (kind or sandbox EKS):

- Not strictly applicable to this lint, which validates static authoring-time content only.
  However, if a future integration test runner validates the pre-apply invariants before each
  `tests/integration/` run, this lint should be one of them. Name it
  `tests/integration/00_preflight_lint.sh` and have it invoke `test_drc_sa_pinned.sh` so any
  DRC added to a feature branch is validated before the integration suite even starts.

**E2E** — full-stack chainsaw / cluster:

- The SPEC-B4 Kyverno audit policy is the runtime complement to this static lint. Once SPEC-B4
  is implemented, a chainsaw scenario `tests/chainsaw/irsa-binding-integrity/chainsaw-test.yaml`
  can assert that every live `DeploymentRuntimeConfig` in `crossplane-system` has
  `.spec.serviceAccountTemplate.metadata.name` non-empty — a real-cluster echo of this test.
  That chainsaw scenario is out of scope for this spec but is the natural next step per the
  A2 cross-comment (A2→A3-012: "runtime witness to the static lint").

---

## 8. Documentation updates

- `tests/unit/run.sh` comment block (above the new `run_suite` line): `# IRSA binding
  integrity suite — test_irsa_sa_pinned.sh + test_drc_sa_pinned.sh (SPEC-B2 + SPEC-LB6)`.
  One sentence; makes the logical grouping explicit.
- `ai/TESTING-PLAN.md` bug-to-test traceability matrix: add row `Bug 5 / PR #66 →
  unit / test_drc_sa_pinned.sh → authoring-time DRC SA name pin absent`.
- `terraform/management/helm.tf`: add a one-line comment above the `name:
  upbound-provider-family-aws` line: `# Required: test_drc_sa_pinned.sh asserts this is
  non-empty (SPEC-LB6).` This gives any future author editing the manifest an immediate pointer
  without reading the full spec.
- `AGENTS.md` §6.1: no edit needed — the new test slots into the existing `tests/unit/` row.

---

## 9. Workflow / auto-invocation wiring

- **`tests/unit/run.sh`** is the single entry point invoked by
  `.github/workflows/terraform-test.yml` at `phase=test, action=test-unit`. Adding one
  `run_suite tests/unit/test_drc_sa_pinned.sh` line auto-wires the new lint into every PR
  check and every local `tests/unit/run.sh` invocation. No new workflow file, no new job, no
  new permissions required.
- The test is pure-local. No AWS calls, no cluster calls, no `terraform init`. Safe to include
  in every push without adding latency.
- Position the new `run_suite` line immediately after the `test_irsa_sa_pinned.sh` line so the
  IRSA binding integrity suite appears as a visual block in the run log.

---

## 10. Discoverability

1. **Mechanical enforcement.** The `FAIL` line names the file path and the exact missing field:
   `FAIL: terraform/management/helm.tf (inline manifest): DeploymentRuntimeConfig has empty or
   missing spec.serviceAccountTemplate.metadata.name`. A future agent that adds a new
   `DeploymentRuntimeConfig` without a SA name pin sees this in CI immediately. No ambiguity
   about the fix.
2. **Documentation pointer.** The comment added to `helm.tf` above the existing pin (§8) is
   visible in every code-review diff for that line and points to `SPEC-LB6` by name. An agent
   looking at `terraform/management/helm.tf` for the first time reads the comment before
   editing the value.
3. **Adversarial-review trigger (AGENTS.md §6.4).** The adversarial reviewer's test-plan
   checklist item is: *"Does any new `DeploymentRuntimeConfig` manifest lack
   `spec.serviceAccountTemplate.metadata.name`? Would the PR #66 bug reproduce?"* This item
   should be added to the adversarial brief template whenever a `DeploymentRuntimeConfig` is
   introduced.

---

## 11. Verification checklist

The implementing agent runs these checks after coding the spec:

- [ ] `bash /home/user/k8-platform/tests/unit/test_drc_sa_pinned.sh` exits 0 on the current
      repo (PR #66 fix is already merged; `helm.tf` has `name: upbound-provider-family-aws`).
- [ ] `DRC_YAML_ROOT=tests/unit/fixtures/drc_sa_pinned/failing HCL_TARGET=/dev/null bash tests/unit/test_drc_sa_pinned.sh` exits non-zero and emits at least one `FAIL` line per fixture file in the `failing/` directory.
- [ ] `DRC_YAML_ROOT=tests/unit/fixtures/drc_sa_pinned/passing HCL_TARGET=/dev/null bash tests/unit/test_drc_sa_pinned.sh` exits 0 and emits one `PASS` line per DRC document.
- [ ] The `--self-test` flag (or meta-test driver) exits 0, covering all fixture cases
      including the ignore-marker variants.
- [ ] **PR #66 TDD reproduction:** temporarily remove the `name: upbound-provider-family-aws`
      line from `terraform/management/helm.tf` and run the script; it exits non-zero with a
      FAIL line containing `upbound-provider-family-aws` or the DRC name `aws-provider-config`.
      Restore the line; the script exits 0.
- [ ] `grep -c 'test_drc_sa_pinned' /home/user/k8-platform/tests/unit/run.sh` returns ≥ 1.
- [ ] `grep -c 'test_irsa_sa_pinned' /home/user/k8-platform/tests/unit/run.sh` returns ≥ 1 and
      both lines appear adjacent (within 3 lines of each other) — confirms the suite grouping.
- [ ] `bash /home/user/k8-platform/tests/unit/test_drc_sa_pinned.sh` completes in under 2
      seconds on a cold checkout.
- [ ] `grep 'SPEC-LB6' /home/user/k8-platform/terraform/management/helm.tf` returns the
      comment line added in §8.

---

## 12. Rollout notes

### Audit before merge

Before merging the implementation, audit every `DeploymentRuntimeConfig` in the repo to confirm
the lint lands green. As of 2026-05-25:

| Source | Resource name | File | SA name pinned? |
|---|---|---|---|
| Inline heredoc (`helm.tf`) | `aws-provider-config` | `terraform/management/helm.tf` ~line 180 | Yes — `upbound-provider-family-aws` (PR #66 fix) |
| Standalone YAML (if any exist) | — | `crossplane/` (scan at implementation time) | Verify at implementation |

The `crossplane/` directory should be scanned at implementation time with
`grep -r 'DeploymentRuntimeConfig' crossplane/` to confirm no standalone DRC files have been
added since this spec was authored. If any are found, check them against the lint before
merging.

### Backward compatibility

Adding this lint cannot break anything that worked before. It only fails CI on manifests that
lack a SA name pin — which is exactly the authoring-time omission that caused PR #66. The only
risk is a false positive on a legitimately pin-free DRC (see the ignore-marker mechanism in
§5.7).

### Sequencing with in-flight branches

This spec depends on `tests/unit/_lib/hcl_extract.sh`, which is introduced by SPEC-B3. If
SPEC-B3 is not merged when this spec is implemented, stub `hcl_extract.sh` locally and stack
the PRs:

1. SPEC-B3 (`test_terraform_data_hashes_manifest.sh` + `_lib/hcl_extract.sh`) — parent branch
2. SPEC-LB6 (`test_drc_sa_pinned.sh`) — child branch, base = SPEC-B3 branch

If SPEC-B3 is already merged, implement this spec directly off `main`.

### Pluralsight sandbox constraints

Orthogonal. This lint never calls AWS, never runs `terraform init`, never touches the cluster.
Sandbox instance-type and region restrictions are irrelevant.

### CLUSTERING-REVIEW.md placement

This spec belongs to Cluster 2 (IRSA binding integrity: SPEC-B2 + SPEC-LB6 + SPEC-B4). Branch
sequencing per the cluster: SPEC-B2 → SPEC-LB6 → SPEC-B4 (Kyverno audit). SPEC-LB6 may be
implemented in parallel with SPEC-B2 if `_lib/hcl_extract.sh` is already available from
SPEC-B3.

---

## 13. Estimated effort

**S** (small, ≤ 1 hr).

~20 min for the ~100-line script (simpler than `test_irsa_sa_pinned.sh` — no cross-file
matching, just "is this field present and non-empty?"); ~15 min for six YAML fixtures + a
meta-test driver; ~15 min rollout audit (`grep -r 'DeploymentRuntimeConfig' crossplane/` +
one visual check of `helm.tf` — one known DRC in the repo today); ~5 min adversarial
subagent brief; ~5 min §11 smoke-test checklist. Total well under one hour from a standing
start.
