# SPEC-S6 — Pre-commit `kubeconform` hook against registered CRDs

Brainstorm ID: A1-058 (see `ai/brainstorming/brainstorm.json`).
Tier S item S6 from `ai/brainstorming/specs/larger-list-preferences.md` §S6.

---

## 1. Summary

Add a `kubeconform`-backed validation step that runs against every YAML
under `crossplane/`, `argocd/`, `clusters/`, and `policies/` on every
push via `unit-tests.yml`. CRD schemas are pre-fetched from the cluster
and committed to `kubeconform-schemas/`, supplied to kubeconform via
`--schema-location`, so custom resources — XRDs, Compositions, Claims,
Kyverno ClusterPolicies — are validated with full field-level precision.
A second sub-check validates Composition pipeline inputs against the
`function-patch-and-transform` function-input schema, a distinct
silent-failure class not covered by XRD validation alone (A3 comment on
brainstorm A1-058). The deliverable is `tests/unit/test_kubeconform_manifests.sh`,
a `scripts/fetch-crds-for-kubeconform.sh` helper, a `tests/unit/fixtures/kubeconform/`
fixture set, a new step in `.github/workflows/unit-tests.yml`, and a
`run_suite` entry in `tests/unit/run.sh`. Together these catch the Bug 4
class (string-transform-missing-type) and the Crossplane 2.3.0 Bug 1
class (`forceOverwriteReplica` unknown field) at commit time instead of
chainsaw-iteration time.

---

## 2. Retro pain killed

- **Bug 4 (PR #61, retro `2026-05-24-62.md` Phase 6, lines 92-96).**
  `crossplane/compositions/platform-secret.yaml` and
  `platform-cluster.yaml` had 9 transforms of `type: string` missing
  `.string.type`. The validator rejects the ENTIRE Composition input
  before any managed resource renders; every claim stays
  `Ready=False/Waiting` forever with no AWS resource created. The
  failure was invisible on `kubectl apply` — XRD and Composition both
  reached Established+Synced — and only surfaced through the
  `phase-2-diagnose` workflow after five chainsaw iterations. A
  kubeconform check against the `pt.fn.crossplane.io/v1beta1` Resources
  schema would have rejected the malformed input at commit time.

- **Crossplane 2.3.0 Bug 1 (PR #74, retro `2026-05-25-76.md` Phase 2,
  lines 44-46).** `crossplane/compositions/platform-secret.yaml` had
  `forceOverwriteReplica: true` in the ASM Secret base — a field absent
  from `provider-aws-secretsmanager`'s CRD schema. Crossplane 2.0.1
  silently tolerated it; 2.3.0's SSA reconciler rejected it with
  `field not declared in schema` and broke all claim reconciliation.
  kubeconform against the provider CRD schema catches this at author
  time.

- **Kyverno drift (PR #64, retro `2026-05-25-70.md` Phase 1, lines 43-47).**
  `crossplane/policies/09-platform-secret-namespace-allowed.yaml` was
  missing `spec.background`, `spec.admission`, and
  `pod-policies.kyverno.io/autogen-controllers`. Kyverno defaulted them
  on admission, causing ArgoCD to see eternal drift. kubeconform against
  the `ClusterPolicy` CRD would have surfaced the schema gaps earlier.

- **Silent-schema-mismatch class (`2026-05-24-62.md` SKILL-SPEC-9149cdc0a6).**
  The retro codified: bugs silent on `kubectl apply` but fatal at
  reconcile time are the most expensive class in this repo. kubeconform
  shifts the failure boundary from chainsaw iteration to commit.

---

## 3. Out of scope

- **Running `kubeconform` against Helm-rendered output.** `test_helm_render.sh`
  already validates helm-rendered YAML; this spec targets hand-authored
  manifests in `crossplane/`, `argocd/`, `clusters/`, `policies/`.
  Helm overlaps are excluded from the kubeconform scan by path.

- **Crossplane `crossplane render` dry-run.** A full `crossplane render`
  against a live function is a deeper check (SPEC-S9 / A1-040 in
  `larger-list-preferences.md`). This spec validates the static schema
  shape; dynamic render output is out of scope here.

- **Automatic CRD schema fetching in CI.** CI cannot reach the EKS
  cluster from a GitHub Actions runner. The schema store is
  pre-committed and updated locally via `scripts/fetch-crds-for-kubeconform.sh`.
  Wiring a live fetch into `unit-tests.yml` would violate AGENTS.md
  §6.1 ("unit | always" — no credentials needed).

- **Validating Terraform-rendered manifests.** Covered by `terraform validate`.

- **Secret or sensitive manifests.** No secrets live in the tracked tree.

### Considered and rejected

- **`kubeval` instead of `kubeconform`.** kubeval is unmaintained (last
  release 2021). kubeconform is its maintained successor.

- **`kyverno test` or policy-based schema enforcement.** Requires a live
  cluster with the CRD installed; not a substitute for static validation.

- **Embedding schema fetch in CI per push.** Requires AWS credentials and
  cluster access — incompatible with the credential-free unit-test tier.

---

## 4. Files to change / create

### Create

| Path | Purpose |
|------|---------|
| `/home/user/k8-platform/tests/unit/test_kubeconform_manifests.sh` | Lint test: runs kubeconform against each scanned directory using the committed schema store. |
| `/home/user/k8-platform/scripts/fetch-crds-for-kubeconform.sh` | Helper: fetches CRD schemas from a live cluster and writes them to the schema store. Not invoked by CI; used locally or via manual `workflow_dispatch`. |
| `/home/user/k8-platform/tests/unit/fixtures/kubeconform/` | Fixture directory: deliberately valid and invalid manifests used by the meta-test. |
| `/home/user/k8-platform/tests/unit/fixtures/kubeconform/should_pass_composition.yaml` | Valid Composition with `string.type` set — lint must accept. |
| `/home/user/k8-platform/tests/unit/fixtures/kubeconform/should_fail_string_transform_no_type.yaml` | Composition with a string transform missing `.string.type` — lint must reject. |
| `/home/user/k8-platform/tests/unit/fixtures/kubeconform/should_fail_unknown_field.yaml` | Manifest with a field absent from its CRD schema (mirrors `forceOverwriteReplica` bug). |
| `/home/user/k8-platform/tests/unit/fixtures/kubeconform/should_pass_claimspolicy.yaml` | Valid Kyverno ClusterPolicy with all required fields — lint must accept. |
| `/home/user/k8-platform/kubeconform-schemas/` | Committed schema store: one JSON Schema file per CRD group/version/kind. Checked into git. |
| `/home/user/k8-platform/kubeconform-schemas/README.md` | Documents how to regenerate the schema store (`scripts/fetch-crds-for-kubeconform.sh`) and when to do so. |

### Modify

| Path | What changes |
|------|-------------|
| `/home/user/k8-platform/tests/unit/run.sh` | Append `run_suite tests/unit/test_kubeconform_manifests.sh`. |
| `/home/user/k8-platform/.github/workflows/unit-tests.yml` | Add `kubeconform` binary install step and `test_kubeconform_manifests` job step. |
| `/home/user/k8-platform/AGENTS.md` | §6.1 test-layer table: add kubeconform row. §6.2 note: kubeconform is the first line of schema defense. |
| `/home/user/k8-platform/ai/testing-guidelines.md` | Add subsection describing the schema store and the kubeconform lint scope. |

---

## 5. Implementation notes

### 5.1 Schema store layout

The committed schema store lives at
`/home/user/k8-platform/kubeconform-schemas/` with one JSON Schema file
per CRD, named `{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json`
(kubeconform's standard local layout). Required entries at minimum:

```
kubeconform-schemas/
  platform.k8-platform.io/   # XRDs + Claims
  pt.fn.crossplane.io/       # function-patch-and-transform input
  kyverno.io/                # ClusterPolicy
  external-secrets.io/       # ExternalSecret
  secretsmanager.aws.upbound.io/  # provider-aws Secret MR
  apiextensions.crossplane.io/   # Composition, XRD
```

Test invocation:

```bash
kubeconform \
  --schema-location 'default' \
  --schema-location "kubeconform-schemas/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
  --ignore-missing-schemas \
  --output json \
  "$manifest"
```

`--ignore-missing-schemas` prevents failure when a schema is absent
from both the store and the upstream catalog. The test emits a
`NOTICE:` line per skipped schema so gaps are visible but non-blocking.

### 5.2 Schema fetch helper

`scripts/fetch-crds-for-kubeconform.sh` requires `kubectl` and
`python3`. Core loop:

```bash
#!/usr/bin/env bash
set -euo pipefail
STORE_DIR="${STORE_DIR:-kubeconform-schemas}"
kubectl get crds -o json | python3 - <<'PY'
import json, sys, pathlib, os
store = os.environ.get("STORE_DIR", "kubeconform-schemas")
for item in json.load(sys.stdin).get("items", []):
    group = item["spec"]["group"]
    kind  = item["spec"]["names"]["kind"].lower()
    for ver in item["spec"]["versions"]:
        schema = ver.get("schema", {}).get("openAPIV3Schema")
        if not schema:
            continue
        dest = pathlib.Path(store) / group / f"{kind}_{ver['name']}.json"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(schema, indent=2))
        print(f"  wrote {dest}")
PY
```

Run once against a live cluster (`aws eks update-kubeconfig`), commit
the resulting JSON files in the same PR that ships the lint.

### 5.3 Function-input schema (the A3 cross-comment extension)

`pt.fn.crossplane.io/v1beta1 Resources` is the function-patch-and-transform
input schema. It is NOT installed as a CRD; it ships embedded in the
function's OCI package. Acquisition:

```bash
# function-patch-and-transform v0.8.x embeds schemas/input/pt.fn.crossplane.io_resources.yaml
id=$(docker create xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.8.0)
docker cp "${id}:/schemas/input/pt.fn.crossplane.io_resources.yaml" /tmp/resources-schema.yaml
docker rm "${id}"
python3 -c "import yaml,json; print(json.dumps(yaml.safe_load(open('/tmp/resources-schema.yaml')), indent=2))" \
  > kubeconform-schemas/pt.fn.crossplane.io/resources_v1beta1.json
```

This schema enforces `.string.type` on every string transform — the
direct defense against Bug 4. Document in `kubeconform-schemas/README.md`.

### 5.4 Scanned paths and exclusions

The test scans:

```bash
find crossplane/ argocd/ clusters/ policies/ \
  -name '*.yaml' -o -name '*.yml'
```

Exclude:

- `tests/unit/fixtures/kubeconform/` (intentional bad fixtures).
- Files with `# kubeconform-skip` on the first 5 lines (allowlist,
  same approach as SPEC-B1's `shell-safety-lint: skip-file`).

A file that produces any kubeconform `status: "invalid"` result causes
the test to exit 1. A file that produces `status: "statusSkipped"` (no
schema found) emits a `NOTICE:` line and continues.

### 5.5 Output and CI install

kubeconform `--output json` emits one JSON object per manifest with a
`status` field (`valid`, `statusSkipped`, `invalid`, `error`). The test
loops over findings: `valid` → `_pass`, `statusSkipped` → `NOTICE:`,
`invalid|error` → `_fail` + exit 1. The `msg` field is one line;
no truncation needed.

Install in `unit-tests.yml` before the test step (pin to `versions.env`):

```yaml
- name: Install kubeconform
  run: |
    set -euo pipefail
    VERSION="v0.6.7"   # also set in versions.env
    curl -fsSL \
      "https://github.com/yannh/kubeconform/releases/download/${VERSION}/kubeconform-linux-amd64.tar.gz" \
      | tar xz -C /usr/local/bin kubeconform
    kubeconform --version
```

On ~30 YAML files, kubeconform completes in under 2 seconds. Schema
store is ~200 KB of JSON — acceptable overhead.

---

## 6. Tests required

Per AGENTS.md §6.1 and §6.4 (adversarial reviewer):

| Layer | File | Assertion |
|-------|------|-----------|
| Unit (meta) | `tests/unit/test_kubeconform_manifests.sh` | Run against `fixtures/kubeconform/should_pass_composition.yaml` — assert exit 0, no `FAIL:` lines. |
| Unit (meta) | same | Run against `should_fail_string_transform_no_type.yaml` — assert exit 1, `FAIL:` line names the file and cites `.string.type`. |
| Unit (meta) | same | Run against `should_fail_unknown_field.yaml` — assert exit 1, `FAIL:` line names the unexpected field. |
| Unit (meta) | same | Run against `should_pass_claimspolicy.yaml` — assert exit 0. |
| Unit (regression) | same | Run against a fixture synthesizing the PR #74 `forceOverwriteReplica` bug — assert exit 1. |
| Unit (regression) | same | Run against a fixture synthesizing the PR #61 string-transform-no-type bug — assert exit 1. |
| Unit (skip) | same | Fixture with `# kubeconform-skip` header — assert exit 0 and a `NOTICE:` line. |

Before authoring the test, spawn one adversarial subagent per AGENTS.md
§6.4 with: (a) the fixture cases, (b) Bug 4 and Bug 1 failure modes,
(c) the `--ignore-missing-schemas` boundary. Expected gap findings:
multi-document YAML (`---` separated), kubeconform `List` kind handling,
`statusSkipped` non-fatal path.

---

## 7. Testing suggestions (unit / integration / e2e)

**Unit** — `tests/unit/test_kubeconform_manifests.sh`

Fast (<5s each). The meta-test fixtures described in §6 are the primary
cases. Additional coverage:

1. A multi-document YAML file (two `---`-separated manifests) where the
   first is valid and the second has an unknown field — assert exit 1
   and that BOTH documents are scanned.
2. An empty YAML file (0 bytes) — assert exit 0, no crash (kubeconform
   returns `statusSkipped` for empty input).
3. A manifest of a built-in kind (`ConfigMap`, `Namespace`) — assert
   exit 0 using the default schema location (no custom schema needed).
4. A manifest where `apiVersion` is a custom group not in the store and
   no upstream schema exists — assert `NOTICE:` emitted and exit 0
   (the `--ignore-missing-schemas` path is exercised).

**Integration** — not applicable for this spec.

This lint operates entirely on static files and requires no live cluster,
no AWS credentials, and no Kubernetes API. The schema-fetch helper is a
human-invoked tool, not a test; its correctness is visible in the
committed schema store via `git diff` after a re-run.

**E2E** — not applicable for this spec.

The lint's purpose is to prevent bad manifests from reaching the cluster.
Correctness of applied manifests is verified by the existing chainsaw
scenarios in `tests/chainsaw/<scenario>/chainsaw-test.yaml`. A chainsaw
scenario that applies a deliberately-invalid manifest would be testing
kubeconform itself, not k8-platform contracts — out of scope.

---

## 8. Documentation updates

- **`AGENTS.md` §6.1** — add row: `kubeconform | all YAML in crossplane/, argocd/, clusters/, policies/ | tests/unit/test_kubeconform_manifests.sh`.
- **`AGENTS.md` §6.2** — add bullet: Bug 4 / Bug 1 class is caught by
  the kubeconform lint (SPEC-S6); fix by correcting the field, not by
  adding `# kubeconform-skip`.
- **`ai/testing-guidelines.md`** — add subsection: schema store location,
  how to regenerate (`scripts/fetch-crds-for-kubeconform.sh` after any
  CRD addition or Crossplane bump), allowlist syntax.
- **`kubeconform-schemas/README.md`** — documents CRD-fetch (§5.2) and
  function-input schema acquisition (§5.3). Created as part of §4.

---

## 9. Workflow / auto-invocation wiring

`tests/unit/run.sh` — append `run_suite tests/unit/test_kubeconform_manifests.sh`.

`.github/workflows/unit-tests.yml` — add two steps after `Install yq`:
`Install kubeconform` (§5.5 snippet) and `test_kubeconform_manifests`
(same guard pattern as every other test step — `if [ -f ... ]; then bash ...`).
No `continue-on-error`: schema violations must block the PR.

The lint fires on every push to a non-main branch via the existing
`push: branches-ignore: [main]` trigger. No new workflow file required.

---

## 10. Discoverability

1. **Mechanical enforcement** — `unit-tests.yml` fails the PR check when
   any manifest has an unknown field or missing required field. `FAIL:`
   output names the file and field; the fix is unambiguous.

2. **Documentation pointer** — `AGENTS.md` §6.1 test-layer table lists
   kubeconform as required for all `crossplane/`, `argocd/`, `clusters/`,
   `policies/` YAML. Future agents authoring a new Composition land on
   this row and the SPEC-S6 pointer in `ai/testing-guidelines.md`.

3. **Adversarial-review trigger** — `AGENTS.md §6.4` fires on new XRD or
   Composition authoring. The reviewer's brief (§6 of this spec) covers
   Bug 4 and Bug 1, prompting a check that the schema store covers the
   new CRD group before the PR lands.

---

## 11. Verification checklist

- [ ] `bash tests/unit/test_kubeconform_manifests.sh` exits 0 (after §12
  audit).
- [ ] `bash tests/unit/run.sh` includes `test_kubeconform_manifests` and
  exits 0.
- [ ] `ls kubeconform-schemas/` shows: `platform.k8-platform.io`,
  `pt.fn.crossplane.io`, `apiextensions.crossplane.io`, `kyverno.io`,
  `external-secrets.io`, `secretsmanager.aws.upbound.io`.
- [ ] Manual: add `forceOverwriteReplica: true` to
  `crossplane/compositions/platform-secret.yaml` → `FAIL:` names the
  field → revert.
- [ ] Manual: remove `type: Format` from one string transform in
  `crossplane/compositions/platform-secret.yaml` → `FAIL:` → revert.
- [ ] `grep -r 'kubeconform-skip' crossplane/ argocd/ clusters/ policies/`
  returns nothing on first landing.
- [ ] `.github/workflows/unit-tests.yml` has exactly one
  `test_kubeconform_manifests` step, preceded by `Install kubeconform`.
- [ ] `kubeconform-schemas/README.md` exists and documents both the CRD
  fetch procedure (§5.2) and the function-input schema path (§5.3).
- [ ] `grep KUBECONFORM_VERSION versions.env` returns the pinned version.

---

## 12. Rollout notes

**Audit-before-merge is required.** Do not wire the lint into `run.sh`
or `unit-tests.yml` until it is green locally.

1. **Build the schema store.** Run `scripts/fetch-crds-for-kubeconform.sh`
   after `aws eks update-kubeconfig`. Extract the function-input schema
   per §5.3. Commit the resulting JSON to `kubeconform-schemas/` in the
   same PR as the lint.
2. **Local audit pass.** Expect zero `FAIL:` lines — PR #61 fixed the 9
   `string.type` instances, PR #74 removed `forceOverwriteReplica`. Any
   new violation is real schema drift; fix it in the same PR.
3. **Triage `statusSkipped` notices.** Document skipped types in
   `kubeconform-schemas/README.md` with a one-line reason.
4. **Wire in.** Add `run_suite` to `run.sh`, add install + test steps to
   `unit-tests.yml`, push, confirm CI green.

**Schema store maintenance.** When a CRD is added or Crossplane is
bumped, re-run the fetch and commit updated schemas alongside the new
manifests. This is exactly the guard that would have caught Bug 1 (PR
#74) before it landed on main.

**Pluralsight sandbox constraints** — orthogonal; no AWS spend.

**Branch sequencing.** Standalone `chore/kubeconform-precommit` off
`main`, no stacking dependencies.

---

## 13. Estimated effort

**M** (1.5–2 hours elapsed). The lint code is straightforward; the
schema-fetch and rollout-audit steps dominate.

- 20 min — write `test_kubeconform_manifests.sh`, fixture files,
  allowlist logic.
- 25 min — write `scripts/fetch-crds-for-kubeconform.sh`, run against
  a live cluster, extract function-input schema per §5.3, commit schema
  store (~200 KB JSON).
- 15 min — rollout audit: run lint against current repo, triage
  `statusSkipped` notices, verify zero `FAIL:` lines.
- 10 min — wire into `run.sh` + `unit-tests.yml`, pin `versions.env`.
- 15 min — adversarial subagent review (AGENTS.md §6.4), adopt gap
  findings (multi-doc YAML, empty files, new-CRD handling).
- 15 min — PR review cycle + `AGENTS.md` / `testing-guidelines.md` edits.

The schema-fetch step is the highest-risk component. If the cluster is
unavailable, the implementing agent can bootstrap the store from
published provider CRD YAML URLs (most Crossplane providers publish
their CRD manifests) and flag the live-cluster re-run as a follow-up.
