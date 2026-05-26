# 13 — Impact trace: test infrastructure

**Author:** sonnet impact-tracer
**Scope:** chainsaw harness + chainsaw scenarios + integration tests + unit tests that exercise Crossplane shapes + GitHub workflows

---

## Test impact matrix

| File | Layer | v2 breaks | Effect after migration |
|---|---|---|---|
| `tests/chainsaw/run.sh` | chainsaw | `API-GROUP-HARDCODED`, `PROVIDERCONFIG-NO-KIND` | WILL-FAIL-CRD-NOT-FOUND |
| `tests/chainsaw/versions.env` | chainsaw | — | WILL-PASS |
| `tests/chainsaw/chainsaw-config.yaml` | chainsaw | — | WILL-PASS |
| `tests/chainsaw/kind-config.yaml` | chainsaw | — | WILL-PASS |
| `tests/chainsaw/_smoke/chainsaw-test.yaml` | chainsaw | — | WILL-PASS |
| `tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml` | chainsaw | `API-GROUP-HARDCODED`, `XRD-PROMOTION-WAIT` | WILL-FAIL-EMPTY-RESULT |
| `tests/chainsaw/platform-secret/01-claim-deletion-cleanup/chainsaw-test.yaml` | chainsaw | `API-GROUP-HARDCODED`, `XRD-PROMOTION-WAIT` | WILL-FAIL-EMPTY-RESULT |
| `tests/chainsaw/platform-secret/02-data-rotation/chainsaw-test.yaml` | chainsaw | `API-GROUP-HARDCODED`, `XRD-PROMOTION-WAIT` | WILL-FAIL-EMPTY-RESULT |
| `tests/chainsaw/platform-cluster/00-xrd-establishes/chainsaw-test.yaml` | chainsaw | — | WILL-PASS (dry-run only, no MR shapes) |
| `tests/chainsaw/meta-catch-fires/chainsaw-test.yaml` (PR #91 / A4 branch) | chainsaw | — | WILL-PASS |
| `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml` (PR #94 / C4 branch) | chainsaw | `API-GROUP-HARDCODED`, `KUBECTL-SCRIPT-V1` | WILL-FAIL-EMPTY-RESULT |
| `tests/chainsaw/_lib/catch-block.yaml` (PR #91 / A4 branch) | chainsaw | — | WILL-PASS |
| `tests/integration/05_crossplane_managed_resource.sh` | integration | `API-GROUP-HARDCODED`, `KUBECTL-SCRIPT-V1` | WILL-FAIL-CRD-NOT-FOUND |
| `tests/integration/06_crossplane_xrd_claim.sh` | integration | `API-GROUP-HARDCODED`, `KIND-LIST-HARDCODED`, `XRD-PROMOTION-WAIT` | WILL-FAIL-CRD-NOT-FOUND |
| `tests/integration/11_platform_secret_e2e.sh` | integration | `API-GROUP-HARDCODED`, `XRD-PROMOTION-WAIT` | WILL-FAIL-EMPTY-RESULT |
| `tests/integration/12_crossplane_trace_smoke.sh` | integration | — | WILL-PASS (dispatched with CROSSPLANE_TRACE_LIVE=1; no v1 patterns in script) |
| `tests/integration/13_irsa_trust_validator_smoke.sh` | integration | — | WILL-PASS |
| `tests/integration/run.sh` | integration | — | WILL-PASS |
| `tests/unit/run.sh` | unit | — | WILL-PASS |
| `tests/unit/test_platform_secret_xrd.sh` | unit | `API-GROUP-HARDCODED` | WILL-FAIL-EMPTY-RESULT |
| `tests/unit/test_platform_cluster_xrd.sh` | unit | `API-GROUP-HARDCODED` | WILL-FAIL-EMPTY-RESULT |
| `tests/unit/test_platform_secret_composition.sh` | unit | `API-GROUP-HARDCODED` | WILL-FAIL-EMPTY-RESULT |
| `tests/unit/test_platform_cluster_composition.sh` | unit | `API-GROUP-HARDCODED` | WILL-FAIL-EMPTY-RESULT |
| `tests/unit/test_crossplane_trace.sh` | unit | `API-GROUP-HARDCODED` (fixtures) | NEEDS-REGENERATION |
| `tests/unit/test_kubeconform_manifests.sh` | unit | — (script is schema-agnostic) | NEEDS-REGENERATION (schema store) |
| `tests/unit/fixtures/crossplane-trace/mr-ok.json` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/crossplane-trace/mr-access-denied.json` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/crossplane-trace/mr-failing-long.json` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/crossplane-trace/xr-ok.json` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/crossplane-trace/xr-with-mrs.json` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/crossplane-trace/xr-12-refs.json` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/kubeconform/should_pass_composition.yaml` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/kubeconform/should_fail_string_transform_no_type.yaml` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/kubeconform/should_fail_unknown_field.yaml` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/kubeconform/multi_doc_first_valid_second_invalid.yaml` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `tests/unit/fixtures/composition-render/composition-missing-string-type.yaml` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `kubeconform-schemas/secretsmanager.aws.upbound.io/` (53 schema files) | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `kubeconform-schemas/eks.aws.upbound.io/` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `kubeconform-schemas/iam.aws.upbound.io/` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `kubeconform-schemas/ec2.aws.upbound.io/` | unit | `API-GROUP-HARDCODED` | NEEDS-REGENERATION |
| `.github/workflows/chainsaw.yml` | workflow | — | WILL-PASS |
| `.github/workflows/chainsaw-verify.yml` | workflow | — | WILL-PASS |
| `.github/workflows/unit-tests.yml` | workflow | — | WILL-PASS |
| `.github/workflows/integration-tests.yml` | workflow | — | WILL-PASS |

---

## Per-file detail (only files with at least one break)

### `tests/chainsaw/run.sh`

**Breaks:** `API-GROUP-HARDCODED`, `PROVIDERCONFIG-NO-KIND`

- **L230:** `apiVersion: aws.upbound.io/v1beta1` — the ProviderConfig heredoc uses the **v1 API group** `aws.upbound.io`. In v2 provider-family-aws (v2.5.4), the ProviderConfig CRD moves to `aws.m.upbound.io/v1beta1`. Applying this manifest against a cluster with the v2 provider will get "no matches for kind ProviderConfig in version aws.upbound.io/v1beta1".
- **L230–241 (ProviderConfig heredoc):** `providerConfigRef:` is used by name only (`name: default`). The v2 spec requires `kind:` on `providerConfigRef` entries in Compositions. Although this block only installs the ProviderConfig _itself_ (not a providerConfigRef), **the absence of a `kind:` field on the ProviderConfig's own object identity is not the issue** — the issue is the wrong API group. See Composition impact doc for providerConfigRef in Compositions.
- **L318–319 (diagnostics block):** `kubectl get platformsecret,xplatformsecret -A` and `kubectl get platformcluster,xplatformcluster -A` — in v2, XRs are namespaced. The `-A` flag still works for namespaced resources; these lines themselves are safe. However the loop at L324 `kubectl get "$kind" -o name` (where kind is `xplatformsecret`/`xplatformcluster`) will behave differently in v2 (returns namespaced objects, not cluster-scoped). This is a diagnostic-block issue only; it degrades output quality, not test correctness.
- **Effect:** `WILL-FAIL-CRD-NOT-FOUND` — the ProviderConfig apply at L229–241 will fail because `aws.upbound.io/v1beta1 ProviderConfig` does not exist with the v2 provider package. The provider installs fine, but ProviderConfig lives at `aws.m.upbound.io/v1beta1` in v2.

---

### `tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml`

**Breaks:** `API-GROUP-HARDCODED`, `XRD-PROMOTION-WAIT`

- **L68–69 (ASM-exists script):**
  ```
  xr=$(kubectl get platformsecret ${CLAIM_NAME} -n default -o jsonpath='{.spec.resourceRef.name}')
  uid=$(kubectl get xplatformsecret "$xr" -o jsonpath='{.metadata.uid}')
  ```
  `spec.resourceRef` is the v1 claim→XR promotion pointer. In v2, there is no separate Claim resource; the XR _is_ the claim (namespaced). The field `spec.resourceRef.name` will be absent; `xr` will be empty; the `kubectl get xplatformsecret` call with an empty name will fail.
- **Note:** Touches real AWS (creates an ASM secret). Cannot be run locally without AWS credentials.
- **Effect:** `WILL-FAIL-EMPTY-RESULT` — `spec.resourceRef` is not populated in v2 (no promotion), so `xr` is empty and the ASM key derivation fails. The claim itself may reach Ready=True post-migration (provider works), but this script step breaks.

---

### `tests/chainsaw/platform-secret/01-claim-deletion-cleanup/chainsaw-test.yaml`

**Breaks:** `API-GROUP-HARDCODED`, `XRD-PROMOTION-WAIT`

- **L50–51 (capture-XR-UID script):**
  ```
  xr=$(kubectl get platformsecret ${CLAIM_NAME} -n default -o jsonpath='{.spec.resourceRef.name}')
  uid=$(kubectl get xplatformsecret "$xr" -o jsonpath='{.metadata.uid}')
  ```
  Same v1 promotion pattern as scenario 00. `spec.resourceRef.name` will be empty in v2.
- **Note:** Touches real AWS. Cannot be run locally without AWS credentials.
- **Effect:** `WILL-FAIL-EMPTY-RESULT` — the XR UID capture fails; the ASM cleanup verification uses an empty key, and the `grep -q "$key"` call at scenario-cleanup time misfires silently.

---

### `tests/chainsaw/platform-secret/02-data-rotation/chainsaw-test.yaml`

**Breaks:** `API-GROUP-HARDCODED`, `XRD-PROMOTION-WAIT`

- **L52–53 (write-initial-value script):**
  ```
  xr=$(kubectl get platformsecret ${CLAIM_NAME} -n default -o jsonpath='{.spec.resourceRef.name}')
  uid=$(kubectl get xplatformsecret "$xr" -o jsonpath='{.metadata.uid}')
  ```
  Same pattern. In v2, `spec.resourceRef` is absent.
- **Note:** Touches real AWS. Cannot be run locally without AWS credentials.
- **Effect:** `WILL-FAIL-EMPTY-RESULT` — ASM key is derived from empty `uid`; the `put-secret-value` call fails.

---

### `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml` (PR #94 / C4 branch)

**Breaks:** `API-GROUP-HARDCODED`, `KUBECTL-SCRIPT-V1`

- **L"drift — golden MUST FAIL" step script:**
  ```
  region=$(kubectl get secret.secretsmanager.aws.upbound.io \
    -l "crossplane.io/composite=$xr" \
    -o jsonpath='{.items[0].spec.forProvider.region}')
  ```
  This `kubectl get` uses the v1 API group `secretsmanager.aws.upbound.io`. In v2, the CRD is at `secretsmanager.aws.m.upbound.io`; this kubectl call returns nothing.
- **Golden files (`expected/asm-secret.yaml` for scenarios 00/01/02):**
  All three golden files declare `apiVersion: secretsmanager.aws.upbound.io/v1beta1` — the v1 API group. After migration to v2 provider, the live MR's apiVersion is `secretsmanager.aws.m.upbound.io/v1beta1`. The chainsaw assert that compares live MR to golden will see a mismatch at `apiVersion`.
- **Effect:** `WILL-FAIL-EMPTY-RESULT` — the `kubectl get secret.secretsmanager.aws.upbound.io` returns 0 items; `region` is empty; the test's inverted-failure logic misfires.

---

### `tests/integration/05_crossplane_managed_resource.sh`

**Breaks:** `API-GROUP-HARDCODED`, `KUBECTL-SCRIPT-V1`

- **L27:** `apiVersion: s3.aws.upbound.io/v1beta1` — applies an S3 Bucket MR using the v1 API group.
- **L38:** `add_cleanup "kubectl delete bucket.s3.aws.upbound.io $BUCKET --wait=false"` — cleanup references v1 group.
- **L42:** `"$HERE/../../scripts/wait-for-claim.sh" bucket.s3.aws.upbound.io "$BUCKET" "" 180` — wait-for-claim uses v1 group for the object reference.
- **L50:** `trace kubectl delete bucket.s3.aws.upbound.io $BUCKET` — v1 group.
- **Note:** Touches real AWS (creates a real S3 bucket). Requires `provider-family-aws` to be Healthy and AWS creds present. Cannot run locally without those.
- **Effect:** `WILL-FAIL-CRD-NOT-FOUND` — `s3.aws.upbound.io/v1beta1 Bucket` CRD does not exist with v2 provider; provider-family-aws v2 ships S3 as `s3.aws.m.upbound.io/v1beta1`.

---

### `tests/integration/06_crossplane_xrd_claim.sh`

**Breaks:** `API-GROUP-HARDCODED`, `KIND-LIST-HARDCODED`, `XRD-PROMOTION-WAIT`

- **L38–39 (Composition `claimNames:` block):**
  ```yaml
  claimNames:
    kind: TestBucket
    plural: testbuckets
  ```
  The inline XRD at L28–54 uses `claimNames:`. In v2, `claimNames:` is removed from the `CompositeResourceDefinition` schema; Crossplane v2 rejects an XRD containing `claimNames:`.
- **L70:** `apiVersion: s3.aws.upbound.io/v1beta1` in the inline Composition's resource base — v1 API group.
- **L88–91 (Claim apply):**
  ```yaml
  kind: TestBucket   # namespace-scoped claim
  ```
  In v2, there is no claim separate from the XR. The namespace-scoped TestBucket resource type would not exist once `claimNames:` is rejected from the XRD; the claim apply fails.
- **L101:** `"$HERE/../../scripts/wait-for-claim.sh" TestBucket "$BUCKET" "$TEST_NS" 240` — wait-for-claim waits on the claim resource `TestBucket`; in v2 the XR IS the user-facing resource, kind name differs.
- **Note:** Touches real AWS (creates a real S3 bucket).
- **Effect:** `WILL-FAIL-CRD-NOT-FOUND` — the `claimNames:` XRD apply is rejected by Crossplane v2 at admission, so the CRD for `TestBucket` is never installed and the claim apply fails.

---

### `tests/integration/11_platform_secret_e2e.sh`

**Breaks:** `API-GROUP-HARDCODED`, `XRD-PROMOTION-WAIT`

- **L76:** `XR=$(kubectl get platformsecret -n "$TEST_NS" "$CLAIM" -o jsonpath='{.spec.resourceRef.name}')` — v1 claim→XR promotion pointer.
- **L82:** `XR_UID=$(kubectl get xplatformsecret "$XR" -o jsonpath='{.metadata.uid}')` — fetches XR by v1 name from `spec.resourceRef.name`.

  In v2, `spec.resourceRef` is not populated (no promotion model). XR and claim are the same object. `XR` will be an empty string; the subsequent `kubectl get xplatformsecret ""` call fails (or fetches the wrong object).
- **Note:** Touches real live management cluster + real AWS. Requires full phase-2 ArgoCD sync. Cannot run locally.
- **Effect:** `WILL-FAIL-EMPTY-RESULT` — `XR_UID` is empty; `ASM_KEY` becomes `k8-platform/`; `aws secretsmanager describe-secret` with that malformed key returns an error; the `wait_for` loop times out.

---

### `tests/unit/test_platform_secret_xrd.sh`

**Breaks:** `API-GROUP-HARDCODED`

- **L33–34 (claimNames assertions):**
  ```bash
  CLAIM_KIND=$(yq -r '.spec.claimNames.kind' "$XRD")
  assert_eq "xrd_claim_kind" "PlatformSecret" "$CLAIM_KIND"
  ```
  Tests L33, 47, 51: assert that `spec.claimNames` exists and has `kind`, `plural`, `listKind`, `singular`. After v2 migration, `claimNames:` is removed from the XRD. Every assertion that reads `.spec.claimNames.*` returns `null`; all five fail.
- **Effect:** `WILL-FAIL-EMPTY-RESULT` — `yq -r '.spec.claimNames.kind'` returns `null`; the `assert_eq "xrd_claim_kind" "PlatformSecret" "null"` assertion fails.

---

### `tests/unit/test_platform_cluster_xrd.sh`

**Breaks:** `API-GROUP-HARDCODED`

- **L28, 37–40 (claimNames assertions):**
  ```bash
  CLAIM_KIND=$(yq -r '.spec.claimNames.kind' "$XRD")
  assert_eq "xrd_claim_kind" "PlatformCluster" "$CLAIM_KIND"
  ...
  vc=$(yq -r ".spec.claimNames.$f" "$XRD")
  _fail "xrd_claim_names_${f}_present" ...
  ```
  Same as test_platform_secret_xrd.sh. All assertions on `spec.claimNames.*` fail when `claimNames` is removed for v2.
- **Effect:** `WILL-FAIL-EMPTY-RESULT`.

---

### `tests/unit/test_platform_secret_composition.sh`

**Breaks:** `API-GROUP-HARDCODED`

- **L41:** `assert_eq "composition_asm_apiVersion" "secretsmanager.aws.upbound.io/v1beta1" "$ASM_BASE_API"` — hardcodes the v1 API group. After migration the Composition uses `secretsmanager.aws.m.upbound.io/v1beta1`; the assertion fails.
- **L80–81 (deletionPolicy assertion):**
  ```bash
  ASM_DELETION=$(yq ... '.base.spec.deletionPolicy' "$COMP")
  assert_eq "composition_asm_deletionPolicy_Delete" "Delete" "$ASM_DELETION"
  ```
  v2 removes `deletionPolicy` for namespaced MRs. If the Composition migration removes `deletionPolicy:`, this assertion fails (reads `null`).
- **L88–89 (ES namespace from claimRef):**
  ```bash
  ES_NS_FROM=$(yq ... '.fromFieldPath' "$COMP")
  assert_eq "composition_es_namespace_from_claim" "spec.claimRef.namespace" "$ES_NS_FROM"
  ```
  In v2, XRs are namespaced themselves; the ExternalSecret namespace comes from the XR's own namespace, not `spec.claimRef.namespace`. After migration this patch path changes; the assertion fails.
- **Effect:** `WILL-FAIL-EMPTY-RESULT` — at minimum the `apiVersion` assertion fails immediately.

---

### `tests/unit/test_platform_cluster_composition.sh`

**Breaks:** `API-GROUP-HARDCODED`

- **L64–65:** `assert_eq "composition_eks_cluster_api" "eks.aws.upbound.io/v1beta1" "$CLUSTER_API"` — hardcodes v1 group. After migration: `eks.aws.m.upbound.io/v1beta1`.
- **L69–70:** `assert_eq "composition_eks_nodegroup_api" "eks.aws.upbound.io/v1beta1" "$NG_API"` — same.
- **Effect:** `WILL-FAIL-EMPTY-RESULT`.

---

### `tests/unit/test_crossplane_trace.sh` + fixture files

**Breaks:** `API-GROUP-HARDCODED` (in fixtures)

The test script itself has no v1 patterns; it dispatches against mock fixtures. The fixtures are the source of the break.

Affected fixtures:

| Fixture | Offending field |
|---|---|
| `tests/unit/fixtures/crossplane-trace/mr-ok.json` | L2: `"apiVersion": "secretsmanager.aws.upbound.io/v1beta1"` |
| `tests/unit/fixtures/crossplane-trace/mr-access-denied.json` | L2: `"apiVersion": "secretsmanager.aws.upbound.io/v1beta1"` |
| `tests/unit/fixtures/crossplane-trace/mr-failing-long.json` | L2: `"apiVersion": "secretsmanager.aws.upbound.io/v1beta1"` |
| `tests/unit/fixtures/crossplane-trace/xr-ok.json` | L11: `"apiVersion": "secretsmanager.aws.upbound.io/v1beta1"` in resourceRefs |
| `tests/unit/fixtures/crossplane-trace/xr-with-mrs.json` | L11: same |
| `tests/unit/fixtures/crossplane-trace/xr-12-refs.json` | L11–22: all 12 resourceRefs use v1 group |

The mock kubectl shim dispatches on `kind_lc/name` — it uses `secret` (kind), not the apiVersion for routing. So the shim does NOT break. However: `scripts/crossplane-trace.sh` uses the `apiVersion` from the fixture's `resourceRefs` to construct the `kubectl get <kind>.<apiVersion>/<name>` call. If the script is patched to understand v2 API groups but fixtures still say `secretsmanager.aws.upbound.io`, the script will look up `secret.secretsmanager.aws.upbound.io` which the mock shim will NOT find (the shim matches on kind `secret` alone, not the full `<kind>.<group>`). The impact depends on how `crossplane-trace.sh` is updated.

- **Effect:** `NEEDS-REGENERATION` — all six fixture files need their `apiVersion` fields updated from `secretsmanager.aws.upbound.io/v1beta1` to `secretsmanager.aws.m.upbound.io/v1beta1`. The unit test script itself does not need changes.

---

### `tests/unit/test_kubeconform_manifests.sh` (script) + schema store

**Script breaks:** None — the `test_kubeconform_manifests.sh` script itself is schema-store-agnostic. It reads YAML files and runs `kubeconform` with `--schema-location` pointing at `kubeconform-schemas/{{ .Group }}/...`. It does not hardcode group names.

**Schema store breaks:** The entire `kubeconform-schemas/` subtree is derived from v1 CRDs. After migration:
- `kubeconform-schemas/secretsmanager.aws.upbound.io/secret_v1beta1.json` — v1 schema for the old API group.
- `kubeconform-schemas/eks.aws.upbound.io/` — 4 schema files.
- `kubeconform-schemas/iam.aws.upbound.io/` — 2 schema files.
- `kubeconform-schemas/ec2.aws.upbound.io/` — 3 schema files.

When manifests are migrated to use `*.aws.m.upbound.io` groups, kubeconform will look for schemas at `kubeconform-schemas/secretsmanager.aws.m.upbound.io/secret_v1beta1.json` (etc.) — which do not exist. Resources will be emitted as `statusSkipped` (not `statusInvalid`), so the test will NOT fail; it will silently lose coverage. The kubeconform meta-test fixtures (see next section) will also lose schema coverage.

**Kubeconform fixture files with v1 API groups:**

| Fixture | Offending line | v2 consequence |
|---|---|---|
| `should_pass_composition.yaml` | L23: `apiVersion: secretsmanager.aws.upbound.io/v1beta1` | After migration, the base MR apiVersion in the Composition will be v2; the fixture won't match the real Composition shape. The test still passes (fixture is independently valid) but diverges from reality. |
| `should_fail_string_transform_no_type.yaml` | L24: same v1 apiVersion | Schema lookup against the kubeconform store hits the new v2 path (`secretsmanager.aws.m.upbound.io`) — no schema found → `statusSkipped` instead of `statusInvalid`. The meta-test expects `statusInvalid`; it **WILL FAIL**. |
| `should_fail_unknown_field.yaml` | L8: `apiVersion: secretsmanager.aws.upbound.io/v1beta1` | Schema lookup hits old v1 path — no schema → `statusSkipped` instead of `statusInvalid`. Meta-test assertion **WILL FAIL**. |
| `multi_doc_first_valid_second_invalid.yaml` | L13: `apiVersion: secretsmanager.aws.upbound.io/v1beta1` | Second doc skipped instead of invalid; meta-test assertion fails. |

- **Effect:** `NEEDS-REGENERATION` — schema store needs to be regenerated against v2 CRDs (run `scripts/fetch-crds-for-kubeconform.sh` against the v2 provider); kubeconform fixture files need apiVersion updated to v2 groups.

---

### `tests/unit/fixtures/composition-render/composition-missing-string-type.yaml`

**Breaks:** `API-GROUP-HARDCODED`

- **L35:** `apiVersion: secretsmanager.aws.upbound.io/v1beta1` in the resource base.

This fixture is used by `test_composition_render_catches_bug4.sh` (SPEC-S9 §6.2 meta-test). It is deliberately broken (missing `string.type`). After v2 migration, the real Compositions use `secretsmanager.aws.m.upbound.io/v1beta1`. The fixture should mirror the real Composition's shape to defend the same bug class. The bug-detection still works because the transform validation is API-group-independent; but the MR schema validation part (which validates `base.apiVersion`) will be looking at a stale group.

- **Effect:** `NEEDS-REGENERATION` — update the `apiVersion` field to `secretsmanager.aws.m.upbound.io/v1beta1`.

---

## Chainsaw scenario coverage matrix

| Scenario | Touches AWS? | v1 patterns? | After migration |
|---|---|---|---|
| `_smoke` | No | No | WILL-PASS |
| `meta-catch-fires` (PR #91) | No | No | WILL-PASS |
| `platform-cluster/00-xrd-establishes` | No (dry-run only) | No | WILL-PASS — XRD shape assertions use k8-platform.io groups; Composition apply (L66) needs the production Composition to be v2-valid, but the scenario itself has no v1 group hardcode |
| `platform-secret/00-claim-creates-secret` | Yes — AWS creds required | Yes (`spec.resourceRef`, `xplatformsecret`) | WILL-FAIL-EMPTY-RESULT |
| `platform-secret/01-claim-deletion-cleanup` | Yes — AWS creds required | Yes (`spec.resourceRef`, `xplatformsecret`) | WILL-FAIL-EMPTY-RESULT |
| `platform-secret/02-data-rotation` | Yes — AWS creds required | Yes (`spec.resourceRef`, `xplatformsecret`) | WILL-FAIL-EMPTY-RESULT |
| `_meta/composition-drift` (PR #94) | Yes — AWS creds required | Yes (`secret.secretsmanager.aws.upbound.io` kubectl get; golden files use v1 apiVersion) | WILL-FAIL-EMPTY-RESULT |

**Locally-testable scenarios** (no AWS creds needed): `_smoke`, `meta-catch-fires`, `platform-cluster/00-xrd-establishes`.

**AWS-creds-only scenarios** (cannot run locally without `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION`): all three `platform-secret/*` scenarios, `_meta/composition-drift`.

---

## Cross-cutting observations

**Total files inspected:** 45 (including branches for PRs #91 and #94; `phase-status-assert` scenario referenced in scope does not exist in any branch and is not counted).

**Workflow files:** All four workflow files (`chainsaw.yml`, `chainsaw-verify.yml`, `unit-tests.yml`, `integration-tests.yml`) pass through unchanged — they contain no v1 API group references. The `chainsaw.yml` just delegates to `run.sh`; the `unit-tests.yml` just invokes each test script. No workflow changes are needed.

**`versions.env` is already correct:** PR #98 bumped `PROVIDER_FAMILY_AWS_VERSION=v2.5.4`, `PROVIDER_AWS_SECRETSMANAGER_VERSION=v2.5.4`, `FUNCTION_PATCH_AND_TRANSFORM_VERSION=v0.10.6`. `versions.env` on main already carries these values. No further change needed there.

**`13_phase_status_smoke.sh` does not exist** in any branch inspected. The scope document listed it; it is a planned-but-not-yet-built test. Not counted.

**Test layers ordered by hardest to fix:**

1. **Integration tests** — `05`, `06`, `11` — hardest because they embed inline v1 XRDs + Compositions with `claimNames:` (06) and hit real AWS. The v2 XRD model change (no `claimNames:`) requires a rethink of how 06 defines its test XRD.
2. **Unit tests (composition/XRD shape)** — `test_platform_secret_composition.sh`, `test_platform_cluster_composition.sh`, `test_platform_secret_xrd.sh`, `test_platform_cluster_xrd.sh` — each test is a contract specification against the production manifests. Every `claimNames` assertion, every v1 API group assertion, and the `deletionPolicy` assertion must be updated to match the v2 manifests.
3. **Chainsaw (platform-secret scenarios)** — the `spec.resourceRef.name` pattern for XR-name lookup must change; in v2, the XR name can be found by label or by the fact that the XR is in the same namespace as the user.
4. **Kubeconform fixtures + schema store** — mechanical; `scripts/fetch-crds-for-kubeconform.sh` must be run against a v2 provider, new schemas committed under `secretsmanager.aws.m.upbound.io/` etc., fixture `apiVersion` fields updated.
5. **Fixture files (crossplane-trace)** — simple string replacements; `secretsmanager.aws.upbound.io/v1beta1` → `secretsmanager.aws.m.upbound.io/v1beta1`.

**Single biggest test-layer blocker:** `tests/unit/test_platform_secret_composition.sh` and its sibling `test_platform_cluster_composition.sh`. These run in CI on every push (unit-tests.yml), have no AWS dependency, and will immediately go red after the production Composition manifests are migrated. They gate the entire unit-test suite — any PR touching the Composition files will fail CI until these tests are updated in lockstep.
