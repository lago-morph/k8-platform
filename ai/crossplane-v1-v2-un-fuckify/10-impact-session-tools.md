# 10 — Impact trace: session-built tools

**Author:** sonnet impact-tracer
**Scope:** the 10 session tools (SPEC-S2, S3, S4, S5, S6, S7, S9, S10, A4, C4)

---

## Tool impact matrix

| Spec | Files | v1 API group refs | v1 XRD refs | v1 Composition syntax | Uses kubeconform-schemas | Hardcoded v1 patterns | Verdict |
|---|---|---|---|---|---|---|---|
| SPEC-S4 | `scripts/whereami.sh`, `scripts/_lib/aws-cli-helpers.sh` | 0 | 0 | 0 | no | 0 | OK-SYNTACTIC |
| SPEC-S5 | `scripts/phase-status.sh` (on branch, not yet on main) | 0 | 0 | 0 | no | 1 (probes `platformsecrets` CRD which v2 removes) | BROKEN-INERT |
| SPEC-S6 | `tests/unit/test_kubeconform_manifests.sh`, `scripts/fetch-crds-for-kubeconform.sh`, `kubeconform-schemas/**` | 7 (in fetch script CRD URLs) | 1 (claimNames read) | 0 | YES (9 v1 schema files) | 7 (pinned v1.12.0 URLs) | BROKEN-RUNTIME |
| SPEC-S7 | `scripts/wait-for-claim.sh`, `scripts/_lib/k8s-helpers.sh` | 0 | 0 | 0 | no | 0 | OK-SYNTACTIC |
| SPEC-S2 | `scripts/crossplane-trace.sh` + fixtures in `tests/unit/fixtures/crossplane-trace/` | 1 (script) + 17 (fixtures) = 18 | 0 | 0 | no | 1 (case pattern line 215) | BROKEN-FIXTURES |
| SPEC-S3 | `scripts/irsa_trust_validator.py` + fixtures in `tests/unit/fixtures/irsa_trust_validator/` | 0 | 0 | 0 | no | 0 | OK-SYNTACTIC |
| SPEC-S9 | `scripts/composition-render.sh`, `crossplane/xrds/*/render-fixtures/`, `tests/unit/fixtures/composition-render/` | 1 (composition-render fixture) | 0 | 2 (deletionPolicy + providerConfigRef in fixture) | no | 0 | BROKEN-FIXTURES |
| SPEC-S10 | `docs/runbooks/runbook-apply-zero-resources.md` | 0 | 0 | 0 | no | 0 | OK-SYNTACTIC |
| SPEC-A4 | `tests/chainsaw/_lib/catch-block.yaml`, `tests/chainsaw/meta-catch-fires/chainsaw-test.yaml`, `tests/chainsaw/run.sh` modifications, `tests/unit/test_chainsaw_catch_block.sh` | 1 (run.sh line 230) | 0 | 0 | no | 1 | BROKEN-INERT |
| SPEC-C4 | `tests/chainsaw/platform-secret/{00,01,02}/expected/asm-secret.yaml`, `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`, golden-file unit tests | 9 (3 asm-secret goldens × 3 refs) + 1 (composition-drift) = 10 | 0 | 9 (deletionPolicy + providerConfigRef in 3 goldens × 3 fields) | no | 1 (kubectl get `secret.secretsmanager.aws.upbound.io` in composition-drift) | BROKEN-FIXTURES |

---

## Per-tool detail

### SPEC-S4 — whereami.sh + aws-cli-helpers.sh

**Files:** `scripts/whereami.sh`, `scripts/_lib/aws-cli-helpers.sh`

No reference to any Crossplane API group, XRD model, MR syntax, or schema store. Collects AWS account/region/EKS/zone/kubectl-ctx/ArgoCD URL/Crossplane version via `aws` CLI and `kubectl`. All queries are generic (`kubectl get deployment crossplane -n crossplane-system`). No v1-specific strings.

**v1 API group refs:** 0  
**v1 XRD refs:** 0  
**v1 Composition syntax:** 0  
**kubeconform-schemas:** no  
**Hardcoded v1 patterns:** 0  
**Verdict: OK-SYNTACTIC**

---

### SPEC-S5 — phase-status.sh

**Files:** `scripts/phase-status.sh` (branch `origin/claude/auto-run-2026-05-25-phase-1-S5`; not merged to main as of 2026-05-26)

No references to `aws.upbound.io` API groups, `deletionPolicy`, or `providerConfigRef`. However, the Phase 2 probe at line 230 issues:

```bash
kubectl get crd platformsecrets.platform.k8-platform.io
```

and line 246:

```bash
kubectl get crd xplatformsecrets.platform.k8-platform.io
```

Under v2, the `claimNames` block is removed from the XRD, which causes Crossplane to stop installing the `platformsecrets` CRD (claim CRDs are only generated when `claimNames` is present). After migration, `kubectl get crd platformsecrets.platform.k8-platform.io` will return not-found, and Phase 2 will report "CRD platformsecrets absent" even on a healthy v2 cluster. The sentinel for Phase 2 transitions from "CRD platformsecrets OK" to a false negative. The tool still invokes without error, but Phase 2 classification will be wrong.

**v1 API group refs:** 0  
**v1 XRD refs:** 0 (CRD name references `platform.k8-platform.io`, not AWS API groups)  
**v1 Composition syntax:** 0  
**kubeconform-schemas:** no  
**Hardcoded v1 patterns:** 1 — probes claim CRD (`platformsecrets.platform.k8-platform.io`) that v2 removes  
**Verdict: BROKEN-INERT** — tool invokes without crashing; Phase 2 output will be wrong on v2 cluster

---

### SPEC-S6 — kubeconform pre-commit hook

**Files:** `tests/unit/test_kubeconform_manifests.sh`, `scripts/fetch-crds-for-kubeconform.sh`, `kubeconform-schemas/**`

**fetch-crds-for-kubeconform.sh** hard-codes 7 CRD download URLs pinned to `v1.12.0` of `crossplane-contrib/provider-upjet-aws` (lines 131–137):

```
"https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v1.12.0/package/crds/secretsmanager.aws.upbound.io_secrets.yaml"
"https://raw.githubusercontent.com/crossplane-contrib/provider-upjet-aws/v1.12.0/package/crds/ec2.aws.upbound.io_vpcs.yaml"
... (5 more at v1.12.0)
```

The function-patch-and-transform URL is also pinned to `v0.8.2` (line 141). The XRD extraction loop at line 210 reads `spec.get("claimNames")` — a v1 XRD field — to extract the claim kind schema. On v2 XRDs with no `claimNames`, this is a no-op (returns `None`), so it won't crash but won't generate claim schemas either.

**kubeconform-schemas/** contains **9 schema JSON files** under v1 group directories:
- `secretsmanager.aws.upbound.io/secret_v1beta1.json`
- `ec2.aws.upbound.io/subnet_v1beta1.json`, `vpc_v1beta1.json`
- `eks.aws.upbound.io/cluster_v1beta1.json`, `cluster_v1beta2.json`, `nodegroup_v1beta1.json`, `nodegroup_v1beta2.json`
- `iam.aws.upbound.io/role_v1beta1.json`, `rolepolicyattachment_v1beta1.json`

After migration, manifests under `crossplane/` will reference `secretsmanager.aws.m.upbound.io` group. The store has no schemas for `*.m.upbound.io` groups. Kubeconform will emit `statusSkipped` for all MR bases in Compositions (not `statusInvalid`), which the audit phase treats as a `NOTICE` rather than a FAIL. The composition fixture `should_pass_composition.yaml` references `secretsmanager.aws.upbound.io/v1beta1` — after API group migration the fixture will still pass (the schema still validates the old group), but the real composition will be skipped.

The critical failure mode: `fetch-crds-for-kubeconform.sh` will re-download v1.12.0 CRDs and overwrite the store with v1 schemas, making the store permanently stale relative to the v2 cluster. Re-running the fetch script is what regenerates schemas — but it will produce the wrong result because the URLs are wrong.

**v1 API group refs:** 7 (in fetch script) + 5 (in kubeconform test fixtures) = 12  
**v1 XRD refs:** 1 (`claimNames` in fetch script XRD extractor, line 210)  
**v1 Composition syntax:** 0 (in scripts; fixtures have deletionPolicy — counted under S9)  
**kubeconform-schemas:** YES — 9 v1-group schema files exist; schema store must be regenerated  
**Hardcoded v1 patterns:** 7 (pinned v1.12.0 CRD URLs in fetch script)  
**Verdict: BROKEN-RUNTIME** — re-running `fetch-crds-for-kubeconform.sh` downloads v1.12.0 CRDs; kubeconform emits statusSkipped for all MR bases in v2 manifests (wrong-group schemas produce no-match rather than pass)

---

### SPEC-S7 — wait-for-claim.sh + k8s-helpers.sh

**Files:** `scripts/wait-for-claim.sh`, `scripts/_lib/k8s-helpers.sh`

No Crossplane API group references. Both files operate on generic `kubectl get <kind>/<name>` calls using jsonpath condition queries. The `kind` argument is passed by the caller at invocation time; the script does not hardcode `PlatformSecret`, `secretsmanager.aws.upbound.io`, or any v1-specific string. The claim concept (waiting for `Ready=True`) is unchanged between v1 and v2 — wait-for-claim will work identically against v2 XRs (which now live in namespaces rather than cluster scope) provided callers pass the correct namespace.

**v1 API group refs:** 0  
**v1 XRD refs:** 0  
**v1 Composition syntax:** 0  
**kubeconform-schemas:** no  
**Hardcoded v1 patterns:** 0  
**Verdict: OK-SYNTACTIC**

---

### SPEC-S2 — crossplane-trace.sh + fixtures

**Files:** `scripts/crossplane-trace.sh`, `tests/unit/fixtures/crossplane-trace/*.json`

**Script:** One hardcoded v1 pattern in the `provider_for_apiversion()` function (line 215):

```bash
secretsmanager.aws.upbound.io|*.aws.upbound.io|aws.upbound.io)
  echo "upbound-provider-family-aws" ;;
```

After migration, MR `apiVersion` fields will be `secretsmanager.aws.m.upbound.io/v1beta1`. The glob `*.aws.upbound.io` will NOT match `secretsmanager.aws.m.upbound.io` (the `.m.` segment breaks the glob). The function will fall through to the else branch and attempt to derive a provider name heuristically — likely returning an empty or incorrect string. The PROVIDER and IRSA layers of the trace output will be absent for all v2 MRs. Tool does not crash; output is incomplete.

**Fixtures:** 6 JSON files with `secretsmanager.aws.upbound.io/v1beta1` apiVersion entries (17 occurrences total):
- `mr-access-denied.json:2` — `"apiVersion": "secretsmanager.aws.upbound.io/v1beta1"`
- `mr-failing-long.json:2` — same
- `mr-ok.json:2` — same
- `xr-ok.json:11` — same
- `xr-with-mrs.json:11` — same
- `xr-12-refs.json:10–21` — 12 entries, all `secretsmanager.aws.upbound.io/v1beta1`

These fixtures are mock kubectl responses. Post-migration, real cluster responses will return `secretsmanager.aws.m.upbound.io` groups. Unit tests that use these fixtures will still pass (fixtures don't change), but they will not exercise the code path that handles v2 API groups.

**v1 API group refs:** 1 (script) + 17 (fixtures) = 18  
**v1 XRD refs:** 0  
**v1 Composition syntax:** 0  
**kubeconform-schemas:** no  
**Hardcoded v1 patterns:** 1 — case pattern `secretsmanager.aws.upbound.io|*.aws.upbound.io|aws.upbound.io` fails to match v2 `.m.upbound.io` groups  
**Verdict: BROKEN-FIXTURES** — script logic has a dead case branch on v2 MRs; fixtures all use v1 apiVersions; unit tests pass but don't cover v2 behavior

---

### SPEC-S3 — irsa_trust_validator.py + fixtures

**Files:** `scripts/irsa_trust_validator.py`, `tests/unit/fixtures/irsa_trust_validator/**`

No reference to `aws.upbound.io` API groups, `claimNames`, `deletionPolicy`, or `providerConfigRef`. The validator reads IAM trust policies and Kubernetes ServiceAccount annotations (`eks.amazonaws.com/role-arn`); it does not interact with Crossplane MR API groups, XRD models, or the kubeconform schema store. The mock fixture directories (`getrole-error`, `match-all`, `mismatch-pr66`, `multi-subject`, `stale-pod-pr68`, `unparseable-sub`) contain AWS IAM and SA JSON with no Crossplane API group references.

**v1 API group refs:** 0  
**v1 XRD refs:** 0  
**v1 Composition syntax:** 0  
**kubeconform-schemas:** no  
**Hardcoded v1 patterns:** 0  
**Verdict: OK-SYNTACTIC**

---

### SPEC-S9 — composition-render.sh + fixtures

**Files:** `scripts/composition-render.sh`, `crossplane/xrds/platform-secret/render-fixtures/input.yaml`, `crossplane/xrds/platform-cluster/render-fixtures/input.yaml`, `tests/unit/fixtures/composition-render/composition-missing-string-type.yaml`

**Script:** No direct `aws.upbound.io` references. The function version is read dynamically from `tests/chainsaw/versions.env` (variable `FUNCTION_PATCH_AND_TRANSFORM_VERSION`), so bumping that file is sufficient to update the function pin. The normalization step (`normalize_stream`) strips volatile fields but does not contain API-group-specific logic.

**Render fixture inputs:** `crossplane/xrds/platform-secret/render-fixtures/input.yaml` and `platform-cluster/render-fixtures/input.yaml` use `platform.k8-platform.io` group for the XR — no AWS API group references. No `expected.yaml` golden files exist for either fixture (bootstrap mode only).

**Meta-test fixture:** `tests/unit/fixtures/composition-render/composition-missing-string-type.yaml` contains (lines 35, 41, 42):

```yaml
apiVersion: secretsmanager.aws.upbound.io/v1beta1
...
deletionPolicy: Delete
providerConfigRef:
  name: default
```

This is a deliberately broken Composition used by the SPEC-S9 meta-test to assert that `crossplane render` returns non-zero on a buggy input (missing `type: Format`). The test does NOT assert on the specific API group — it asserts that the render exits non-zero. After v2 migration:
1. `deletionPolicy: Delete` and bare `providerConfigRef: name:` are v1 syntax the v2 provider no longer accepts.
2. `crossplane render` offline validation of function inputs will still reject the missing `type: Format` regardless of API group changes — the function-input validator is not API-group-sensitive.
3. However, if `crossplane render` against a v2 composition tries to validate the base resource against a v2 schema and finds v1 syntax (`deletionPolicy`, bare `providerConfigRef`), it may produce a different error before reaching the `string transform type is required` error. This could make the meta-test pass for the wrong reason, or fail unexpectedly.

**v1 API group refs:** 1 (meta-test fixture line 35)  
**v1 XRD refs:** 0  
**v1 Composition syntax:** 2 (meta-test fixture: `deletionPolicy: Delete` line 41, bare `providerConfigRef: name:` line 42)  
**kubeconform-schemas:** no  
**Hardcoded v1 patterns:** 0  
**Verdict: BROKEN-FIXTURES** — meta-test fixture contains v1 MR syntax; render behavior against v2 function-input validator may diverge; no expected.yaml goldens exist to regenerate (bootstrap mode), but the meta-test fixture needs updating to v2 syntax

---

### SPEC-S10 — runbook-apply-zero-resources.md

**Files:** `docs/runbooks/runbook-apply-zero-resources.md`

One reference to `upbound-provider-family-aws` (line 159 in a `kubectl get deploy` example command), which is the provider deployment name — this name is unchanged between v1 and v2 provider packages. No `aws.upbound.io` API group references, no `claimNames`, no MR syntax.

**v1 API group refs:** 0  
**v1 XRD refs:** 0  
**v1 Composition syntax:** 0  
**kubeconform-schemas:** no  
**Hardcoded v1 patterns:** 0  
**Verdict: OK-SYNTACTIC**

---

### SPEC-A4 — chainsaw catch hook

**Files (on branch `origin/claude/auto-run-2026-05-25-phase-2-A4`):** `tests/chainsaw/_lib/catch-block.yaml`, `tests/chainsaw/meta-catch-fires/chainsaw-test.yaml`, `tests/chainsaw/run.sh` modifications, `tests/unit/test_chainsaw_catch_block.sh`

**catch-block.yaml:** No v1 API group references. The catch block iterates `kubectl get platformsecret` and `platformcluster` (using generic k8s API names) and describes XRs by walking `spec.resourceRefs`. All kubectl commands are resource-type-agnostic.

**meta-catch-fires/chainsaw-test.yaml:** No v1 API group references.

**test_chainsaw_catch_block.sh:** No v1 API group references.

**run.sh** (line 230): One v1 API group reference in the ProviderConfig bootstrap block used for kind-cluster testing:

```yaml
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-creds
      key: creds
```

Under v2, `ProviderConfig` API group changes to `aws.m.upbound.io/v1beta1` (or `ClusterProviderConfig`). The kind bootstrap will fail to create the ProviderConfig on a v2 cluster: `kubectl apply` against the v1 API group will produce a "no matches for kind" error if the v1 CRD is not installed.

The catch-block logic itself is unaffected by v2 — the XR walk via `spec.resourceRefs` works identically. Only the run.sh ProviderConfig creation is broken.

**v1 API group refs:** 1 (run.sh line 230)  
**v1 XRD refs:** 0  
**v1 Composition syntax:** 0  
**kubeconform-schemas:** no  
**Hardcoded v1 patterns:** 1 — `apiVersion: aws.upbound.io/v1beta1` for ProviderConfig kind bootstrap  
**Verdict: BROKEN-INERT** — catch-block itself is fine; run.sh kind bootstrap creates a ProviderConfig with wrong API group, which will be silently accepted (no-error) OR rejected with "no matches for kind" depending on whether the v1 CRD is still installed; cluster-level tests will behave incorrectly but the unit test passes

---

### SPEC-C4 — chainsaw golden-file assertions

**Files (on branch `origin/claude/auto-run-2026-05-25-phase-2-C4`):** `tests/chainsaw/platform-secret/{00,01,02}/expected/asm-secret.yaml`, `tests/chainsaw/platform-secret/{00,01,02}/expected/external-secret.yaml`, `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`, golden-file unit tests

**asm-secret.yaml golden files (3 files, each containing 3 v1 pattern instances):**

`00-claim-creates-secret/expected/asm-secret.yaml` (lines 11, 14–15):
```yaml
apiVersion: secretsmanager.aws.upbound.io/v1beta1
kind: Secret
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: default
```

`01-claim-deletion-cleanup/expected/asm-secret.yaml` — identical structure (lines 4, 7–8)  
`02-data-rotation/expected/asm-secret.yaml` — identical structure (lines 3, 6–7)

After v2 migration, the live MR will have:
- `apiVersion: secretsmanager.aws.m.upbound.io/v1beta1`
- no `deletionPolicy` field
- `providerConfigRef: {name: default, kind: ClusterProviderConfig}` (or equivalent)

Chainsaw partial-match assertions will fail: the golden `apiVersion` will not match the live resource's `apiVersion`, and the extra fields (`deletionPolicy`) will be present in the golden but absent on the live MR. All three scenario assertions (00, 01, 02) will produce assertion failures.

**external-secret.yaml golden files:** No v1 API group references (0 occurrences in all 3 files).

**composition-drift/chainsaw-test.yaml** (line 112): One kubectl command embedding v1 API group:

```bash
region=$(kubectl get secret.secretsmanager.aws.upbound.io \
  -l "crossplane.io/composite=$xr" \
  -o jsonpath='{.items[0].spec.forProvider.region}')
```

After v2 migration, `kubectl get secret.secretsmanager.aws.upbound.io` returns empty (resource not found under v1 group); the region comparison fails; the meta-test incorrectly reports `FAIL: mutation did NOT propagate` when in fact the resource exists under the v2 group.

**v1 API group refs:** 9 (3 asm-secret golden files × 1 apiVersion each) + 1 (composition-drift kubectl command) = 10  
**v1 XRD refs:** 0  
**v1 Composition syntax:** 9 (`deletionPolicy` × 3 + `providerConfigRef` without `kind` × 3 = 6 fields across 3 golden files; counted separately from apiVersion above)  
**kubeconform-schemas:** no  
**Hardcoded v1 patterns:** 1 (`kubectl get secret.secretsmanager.aws.upbound.io` in composition-drift)  
**Verdict: BROKEN-FIXTURES** — all 3 asm-secret golden files assert v1 API group and v1 MR fields; chainsaw will hard-fail on assert mismatch; composition-drift meta-test will produce wrong verdict

---

## Cross-cutting observations

### Files shared by more than one session tool

- `scripts/_lib/k8s-helpers.sh` — owned by SPEC-S7; also sourced by SPEC-S2 (`crossplane-trace.sh`). Neither file has v1 API group refs, so the shared dependency is not a v1-migration hot spot.
- `tests/chainsaw/run.sh` — modified by both SPEC-A4 and the harness bootstrapping that SPEC-C4 depends on. The one v1 ref is in the SPEC-A4 modifications.
- `kubeconform-schemas/` — owned by SPEC-S6 (fetch and unit test); the schema store is the source of truth for `test_kubeconform_manifests.sh`. No other session tool directly reads schema files.

### Total v1 API group refs across all session-tool files

| Category | Count |
|---|---|
| Script files (main branch) | 8 (7 in fetch-crds URLs + 1 in crossplane-trace case pattern) |
| Test fixture files (main branch) | 23 (17 crossplane-trace fixtures + 5 kubeconform fixtures + 1 composition-render fixture) |
| Open PR branch files (A4 + C4) | 11 (1 in A4 run.sh + 10 in C4 golden files) |
| **Total** | **42** |

### Silent-wrong vs hard-fail breakdown

**Hard-fail on v2 cluster:**
- SPEC-S6 — kubeconform schema store has no `.m.upbound.io` schemas; `fetch-crds-for-kubeconform.sh` re-downloads v1 CRDs; audit will silently skip all v2 MR bases instead of validating them (statusSkipped, not a hard crash — but schema regeneration is the broken action that produces permanently-wrong store)
- SPEC-C4 — chainsaw assert on all 3 platform-secret scenarios will hard-fail (apiVersion mismatch in golden files)

**Silent wrong output:**
- SPEC-S2 — `crossplane-trace.sh` PROVIDER/IRSA layers silently absent for v2 MRs (case branch misses `.m.upbound.io`)
- SPEC-S5 — Phase 2 reports "CRD platformsecrets absent" on healthy v2 cluster (claim CRD removed by v2 migration)
- SPEC-A4 — kind bootstrap creates ProviderConfig with wrong API group; result depends on whether v1 CRD is still installed
- SPEC-S9 — meta-test fixture is syntactically v1; crossplane render may produce a different error path before reaching the string-transform bug
