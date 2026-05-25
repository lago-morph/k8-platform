# SPEC-S9 — Composition render dry-run helper

Brainstorm ID: A1-040 (with A3→A1-007 fixture-directory extension).
Tier: S9 from `ai/brainstorming/specs/larger-list-preferences.md`.

## 1. Summary

Add a local dry-run helper (`scripts/composition-render.sh`) that runs
`crossplane render` against a claim YAML, a Composition, and the
function-patch-and-transform binary, then diffs the output against a
committed fixture file. The helper catches the Bug 4 class (string
transform missing `type: Format`, and any other function-input schema
violations) at author time — before the Composition is pushed to a
cluster and before chainsaw runs. Companion to SPEC-C4 (chainsaw
golden-file assertions): SPEC-C4 catches regressions during CI in a
kind cluster; SPEC-S9 catches them on the author's laptop or in a
lightweight CI job before the kind cluster is even booted.

Every Composition gains a `render-fixtures/` subdirectory alongside its
XRD source under `crossplane/xrds/<name>/render-fixtures/` containing
`input.yaml` (the probe claim) and `expected.yaml` (the golden rendered
output). The helper is also wired as a pre-commit hook via
`.pre-commit-config.yaml` so violations are caught at commit time.
This spec is part of the CLUSTERING-REVIEW.md Cluster 2 authoring-time
defense layer and is critical for PlatformCluster (phase 2b) where the
Composition renders 8 managed resources with cross-resource IAM
references.

## 2. Retro pain killed

- **Bug 4 — string transform `type: Format` missing in 9 places**
  (`retrospective/2026-05-24-62.md` Phase 6). The XR validator rejected
  the entire Composition input before any managed resource rendered;
  every claim sat `Ready=False, reason=ReconcileError` forever. The error
  surfaced only via `phase-2-diagnose.yml` (PR #60) against a live
  cluster. Had `crossplane render` been run locally before push, the
  fatal result would have appeared in ~2 seconds on a developer workstation
  rather than after a 15-minute management apply cycle.

- **Silent pass on Bug 4 during apply-and-verify** (`retrospective/
  2026-05-24-62.md` Phase 6). The management `apply-and-verify` dispatcher
  reported `conclusion: success`. XRD and Composition both reached
  `Established + Synced`. The validator rejection only fires when a claim
  is applied. The `crossplane render` invocation in this spec fires
  against a claim probe during unit testing — closing the gap between
  "Composition synced" and "Composition actually renders a valid resource".

- **Iteration cost in chainsaw** (`retrospective/2026-05-24-62.md`
  Phase 2 and Phase 4). Chainsaw boot takes ~10 minutes (kind + Crossplane
  install + provider install). Each function-input rejection costs a full
  chainsaw re-run. Local `crossplane render` runs in under 3 seconds
  against the downloaded function binary — catching the same class of
  error 200x faster.

- **Brainstorm A4-032 cross-reference.** `A4-032` in
  `ai/brainstorming/A4-debug-tool-gaps-prior-constraints.md` states:
  "Bug 4 (Composition string transform missing `type: Format`) would
  have shown up in a render diff before any cluster touched it." This
  spec implements that idea with the fixture extension proposed by A3
  (cross-comment A3→A1-007).

- **Fixture gap in SPEC-C4 §5.** SPEC-C4 (chainsaw golden-file assert)
  requires bootstrapping golden files from a first green kind-cluster run.
  SPEC-S9 provides the `crossplane render`-derived alternative: golden
  files can be bootstrapped locally, committed alongside the Composition,
  and the chainsaw golden then cross-validates against the same expected
  shape. The two specs share a fixture format (see §5).

## 3. Out of scope

- **Live-cluster render fidelity.** `crossplane render` uses the
  function binary, not a running Crossplane controller. Patches that
  depend on connection details, `status.atProvider` values, or
  cross-resource refs resolved by the provider reconciler are not
  faithfully captured. Asserting AWS-side attributes remains SPEC-C2's
  job.

- **Multiple-step pipeline compositions.** Phase 2's Compositions use
  a single `function-patch-and-transform` step. Multi-step pipelines
  (e.g. with `function-go-templating` or `function-kcl`) are supported
  by `crossplane render` but are out of scope until those function
  packages appear in the repo.

- **OCI pulling of function binaries.** The helper uses a pre-downloaded
  binary in `tests/chainsaw/versions.env` (same pin already used by
  `tests/chainsaw/run.sh`). Automatic OCI pulls in CI are not added;
  the binary install is handled by the existing chainsaw bootstrap.

- **Rendering claims that require a kubeconfig.** `crossplane render`
  is fully offline; it does not connect to a cluster. Scenarios that
  depend on provider state (e.g. a claim patching from a providerConfig
  status field) are not supported and are explicitly excluded from the
  fixture set.

### Considered and rejected

- **Running `crossplane render` inside chainsaw as an additional step.**
  Rejected because it requires the kind cluster to already be up and the
  function-patch-and-transform package to be installed. The value of
  SPEC-S9 is catching the error _before_ the kind cluster is booted.
  SPEC-C4 covers the chainsaw layer; SPEC-S9 covers pre-chainsaw.

- **Generating golden files from `helm template`.** Not applicable —
  this is Crossplane, not Helm. Rejected on mismatch grounds.

- **Embedding the probe claim inside `chainsaw-test.yaml`.** Chainsaw
  claims are K8s API objects applied to a live cluster; they carry
  status, ownerReferences, and reconciler-injected fields that the
  offline `crossplane render` output does not produce. Keeping the render
  fixtures in `crossplane/xrds/<name>/render-fixtures/` decouples the two
  layers cleanly.

## 4. Files to change / create

### Create (new files)

| Path | Contents |
|---|---|
| `/home/user/k8-platform/scripts/composition-render.sh` | Main helper: runs `crossplane render`, diffs against fixture, exits non-zero on mismatch |
| `/home/user/k8-platform/crossplane/xrds/platform-secret/render-fixtures/input.yaml` | Probe PlatformSecret claim for offline render |
| `/home/user/k8-platform/crossplane/xrds/platform-secret/render-fixtures/expected.yaml` | Golden rendered output (2 MRs: ASM Secret + ExternalSecret) |
| `/home/user/k8-platform/crossplane/xrds/platform-cluster/render-fixtures/input.yaml` | Probe PlatformCluster claim for offline render |
| `/home/user/k8-platform/crossplane/xrds/platform-cluster/render-fixtures/expected.yaml` | Golden rendered output (8 MRs: IAM roles + attachments + EKS Cluster + NodeGroup) |
| `/home/user/k8-platform/tests/unit/test_composition_render_fixtures.sh` | Unit test: for every XRD with a `render-fixtures/` dir, run the helper and assert exit 0 |

### Modify (existing files)

| Path | What changes |
|---|---|
| `/home/user/k8-platform/.pre-commit-config.yaml` | Add `composition-render.sh` as a `local` hook on `crossplane/compositions/*.yaml` and `crossplane/xrds/*/render-fixtures/*.yaml` path filters |
| `/home/user/k8-platform/tests/unit/run.sh` | Add `test_composition_render_fixtures.sh` to the test suite |
| `/home/user/k8-platform/ai/testing-guidelines.md` | Document the render-fixture convention under the unit-test layer |
| `/home/user/k8-platform/AGENTS.md` | Cross-link under §6 ("Test discipline") |

### Fixture directory layout

```
crossplane/
  xrds/
    platform-secret/
      render-fixtures/
        input.yaml        # probe claim (no metadata.uid — render assigns a fake one)
        expected.yaml     # golden: YAML stream of all rendered MRs (--- separator)
    platform-cluster/
      render-fixtures/
        input.yaml
        expected.yaml
```

The `input.yaml` is a minimal well-formed claim. `metadata.uid` is
omitted — `crossplane render` assigns a deterministic fake UID so
transforms involving `metadata.uid` still fire. The `expected.yaml` is a
multi-document YAML stream (one `---`-separated document per rendered MR)
matching what `crossplane render` emits to stdout.

## 5. Implementation notes

### Invocation shape

```bash
scripts/composition-render.sh \
  --xrd  crossplane/xrds/platform-secret.yaml \
  --comp crossplane/compositions/platform-secret.yaml \
  --func function-patch-and-transform:<version> \
  --fixtures crossplane/xrds/platform-secret/render-fixtures/
```

Flags:
- `--xrd` — the CompositeResourceDefinition for schema validation.
- `--comp` — the Composition file.
- `--func` — function reference. Matches the version pinned in
  `tests/chainsaw/versions.env` (`FUNCTION_PT_VERSION`). The helper
  reads the pin from that file rather than accepting it as a bare string,
  so the two sources stay in sync.
- `--fixtures` — directory containing `input.yaml` and `expected.yaml`.
  If `--fixtures` is absent, the helper runs the render and prints output
  without diffing (useful during initial golden-file authoring).

### Core logic

```bash
# Simplified core of scripts/composition-render.sh
set -euo pipefail

RENDERED=$(crossplane render \
  "$XRD_FILE" \
  "$COMP_FILE" \
  --function-runner-type=docker \
  --include-full-xr \
  "$INPUT_FILE")

if [[ -n "$EXPECTED_FILE" ]]; then
  diff <(echo "$RENDERED") "$EXPECTED_FILE"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "FAIL: rendered output differs from $EXPECTED_FILE" >&2
    exit 1
  fi
  echo "OK: rendered output matches $EXPECTED_FILE"
fi
```

`crossplane render` accepts the XRD, Composition, and a claim YAML and
emits the rendered managed-resource stream to stdout. The `--include-full-xr`
flag ensures the XR object (with `metadata.uid` and `spec.*` fields) is
emitted in the stream so patches that reference the XR are fully resolved.

### Diff strategy

The diff is a `diff -u` of the full rendered stream against the golden.
Fields that are non-deterministic between runs (ownerReferences with
UID-derived values, `resourceVersion`, `creationTimestamp`,
`generateName` suffixes) are stripped from both sides by a
`yq`-based normalizer inside the helper before diffing:

```bash
normalize() {
  yq 'del(.metadata.ownerReferences,
          .metadata.uid,
          .metadata.resourceVersion,
          .metadata.creationTimestamp,
          .metadata.generation,
          .metadata.managedFields)' "$1"
}
diff <(normalize <(echo "$RENDERED")) <(normalize "$EXPECTED_FILE")
```

This is the same normalization strategy used in SPEC-C4 §5. The two
specs intentionally share the approach so a future refactor can unify
the normalization function.

The `metadata.uid` on the input claim is pinned to a deterministic
fake value (`"00000000-0000-0000-0000-000000000001"`) inside `input.yaml`
so transforms that derive values from `metadata.uid` (e.g.
`k8-platform/<XR-uid>` ASM key name) produce reproducible output across
runs without needing to strip those fields.

### Bootstrap procedure (authoring a new golden file)

1. Run the helper without `--fixtures` (or without `expected.yaml`
   present):
   ```
   scripts/composition-render.sh --xrd ... --comp ... --func ... \
     --input crossplane/xrds/platform-secret/render-fixtures/input.yaml
   ```
2. Inspect the emitted stream. Verify the rendered MRs look correct.
3. Redirect to `expected.yaml`:
   ```
   scripts/composition-render.sh ... > crossplane/xrds/platform-secret/render-fixtures/expected.yaml
   ```
4. Hand-edit: pin `metadata.uid` on `input.yaml` to the deterministic
   fake value; verify the `k8-platform/<UID>` field in `expected.yaml`
   reflects it. Remove any fields the normalization step already strips.
5. Run with `--fixtures` and confirm exit 0.
6. Commit both files.

### When the Composition intentionally changes

The Composition author re-runs the bootstrap procedure (step 3 above),
commits the updated `expected.yaml` alongside the Composition change.
Pre-commit blocks the push if the golden is stale. The PR diff shows
both files; the reviewer can verify the rendered-shape delta matches
the intent.

### Performance expectations

`crossplane render` with a pre-downloaded function binary runs in under
3 seconds on a developer workstation and under 10 seconds in CI. The
pre-commit hook fires only on changed Composition or fixture paths —
no cost for unrelated commits.

### Output budget

On mismatch: the `diff -u` output is bounded by the size of the rendered
MR stream. For PlatformCluster (8 MRs, ~400 lines each), worst-case is
~3200 lines. Truncate after 200 diff lines with a "... (truncated) ..."
marker and the instruction to run the helper locally for the full diff.
On success: one line (`OK: ...`). No output budget concern on the happy path.

### Error-mode semantics

- Function binary not found: exit 2 with "Install crossplane CLI and
  function-patch-and-transform; see tests/chainsaw/run.sh for version."
- `crossplane render` non-zero exit (function-input rejection): exit 1
  with the full stderr (this is the Bug 4 class — the fatal result
  message surfaces here).
- `input.yaml` or `Composition` not found: exit 2 with the missing path.
- Missing `expected.yaml` with no `--no-diff` flag: emit rendered output
  and exit 0 with "No expected.yaml found; review output above and
  redirect to expected.yaml to create the golden."

## 6. Tests required

Per AGENTS.md §6.1 and §6.2 (author tests alongside features; TDD on
bug fixes):

### 6.1 Unit test — render fixtures present and match

`tests/unit/test_composition_render_fixtures.sh`: for every directory
under `crossplane/xrds/*/render-fixtures/`, assert that both
`input.yaml` and `expected.yaml` exist and are non-empty, then invoke
`scripts/composition-render.sh` with the correct `--xrd`, `--comp`, and
`--fixtures` flags derived from the directory path. Exit non-zero on any
mismatch. This test runs in `tests/unit/run.sh` on every push via
`unit-tests.yml`.

### 6.2 Meta-test — helper catches Bug 4

`tests/unit/test_composition_render_catches_bug4.sh`: injects a
synthetic Composition with one `string` transform missing `string.type`,
runs `scripts/composition-render.sh` against it, and asserts the helper
exits non-zero with stderr containing `Required value` or similar
function-rejection language. This is the mandatory §6.2 test: it must
FAIL against a buggy composition and PASS after the fix. Running it
against the repo's current (fixed) Composition would trivially pass and
provide no signal; the test must use the synthetic buggy fixture.

Store the synthetic fixture at:
`tests/unit/fixtures/composition-missing-string-type.yaml`

### 6.3 Meta-test — helper flags render divergence

`tests/unit/test_composition_render_diff_detected.sh`: takes the real
PlatformSecret Composition, mutates one patch value (e.g. changes
`fmt: "k8-platform/%s"` to `fmt: "wrong/%s"`) in a temp copy, runs the
helper against it with the committed `expected.yaml`, and asserts exit
non-zero. Proves the golden-file comparison path actually fires.

## 7. Testing suggestions (unit / integration / e2e)

### Unit

These tests run fast (<5s each) and live in `tests/unit/`.

1. `test_composition_render_fixtures.sh` (§6.1) — asserts all fixtures
   present and render matches golden. Gate test for the spec itself.
2. `test_composition_render_catches_bug4.sh` (§6.2) — confirms the
   helper exits non-zero on a `string` transform missing `string.type`.
3. `test_composition_render_diff_detected.sh` (§6.3) — confirms the
   helper exits non-zero when the rendered output diverges from the golden.
4. `test_composition_render_no_golden_exit0.sh` — confirms the helper
   exits 0 when `expected.yaml` is absent (bootstrap mode, no diff).
5. `test_composition_render_version_pin.sh` — confirms the helper reads
   `FUNCTION_PT_VERSION` from `tests/chainsaw/versions.env` and errors
   if that file is absent, rather than silently using an unpinned version.

### Integration

Integration tests require `crossplane` CLI and Docker on the runner.
Names follow `tests/integration/NN_*.sh`.

1. `tests/integration/12_composition_render_platform_secret.sh` — runs
   `scripts/composition-render.sh` against the live-pinned function
   image (not a local binary) and confirms the rendered output matches
   `crossplane/xrds/platform-secret/render-fixtures/expected.yaml`.
   Catches skew between the local binary and the OCI image.
2. `tests/integration/13_composition_render_platform_cluster.sh` — same
   for PlatformCluster. Validates that the 8-MR render is correct and
   that IAM role ARN cross-references are deterministically resolved from
   the probe claim's `spec.name`.

These run during the integration test suite (`tests/integration/run.sh`),
not on every push.

### E2E

The `crossplane render` tool is intentionally offline-only; it does not
talk to a cluster. True end-to-end render fidelity (rendered MR matches
what the live Crossplane controller actually provisions) is the job of
SPEC-C4's chainsaw golden-file assertions. SPEC-S9's E2E surface is
therefore the same as SPEC-C4's chainsaw scenarios — verifying that
`expected.yaml` in the render fixture and `expected/<resource>.yaml` in
the chainsaw scenario are consistent.

One E2E validation: `tests/chainsaw/_meta/render-vs-chainsaw-golden/`
scenario that asserts the live chainsaw golden (SPEC-C4) subsumes the
render fixture fields. This verifies the two defense layers do not
silently drift. Implement as a pre-chainsaw `script:` step that runs
`diff` between the render-fixture expected and the chainsaw golden for
the overlapping fields, failing the scenario if they diverge.

This E2E item is a follow-on and is not required for the spec to be
complete; it is marked as a future hardening step.

## 8. Documentation updates

- `ai/testing-guidelines.md` §6.1 — append to the Unit row: "Every
  Composition in `crossplane/compositions/` MUST have a
  `render-fixtures/` dir under its XRD subdirectory with `input.yaml`
  and `expected.yaml`. Use `scripts/composition-render.sh` to bootstrap
  and verify. See SPEC-S9."
- `AGENTS.md` §6 — add one-line cross-link: "Composition render
  dry-run is mandatory at author time — see SPEC-S9
  (`ai/brainstorming/specs/SPEC-S9-composition-render-dryrun.md`)."
- `ai/TESTING-PLAN.md` — add bug-class row: "Composition
  function-input rejection (Bug 4 class) → `crossplane render` + golden
  diff in unit layer (SPEC-S9) + chainsaw golden assert (SPEC-C4)."
- `docs/operations.md` (or equivalent runbook) — add a "Authoring a new
  Composition" section noting the bootstrap procedure from §5 of this
  spec.
- `scripts/` README (if one exists) — one bullet listing
  `composition-render.sh` with its usage.

## 9. Workflow / auto-invocation wiring

### Pre-commit hook

Add to `/home/user/k8-platform/.pre-commit-config.yaml`:

```yaml
- repo: local
  hooks:
    - id: composition-render-dryrun
      name: Composition render dry-run
      language: script
      entry: scripts/composition-render.sh --all
      pass_filenames: false
      files: ^crossplane/(compositions|xrds/[^/]+/render-fixtures)/.*\.yaml$
```

The `--all` flag iterates over all `crossplane/xrds/*/render-fixtures/`
directories. Pre-commit invokes it only when a Composition or
render-fixture file is staged.

### CI (lightweight)

`tests/unit/run.sh` already runs on every push via
`.github/workflows/unit-tests.yml`. `test_composition_render_fixtures.sh`
added to that suite gates every push on a green render-vs-golden check
without requiring Docker (the unit test uses the pre-installed binary,
not the OCI image). The binary install step is a one-liner already
present in the CI job for the existing chainsaw-related unit tests.

### Heavy-CI contract

The integration layer tests (§7 Integration) run during
`tests/integration/run.sh`, which is not on every push. No new
`workflow_dispatch`-only heavy workflow is introduced by this spec.

## 10. Discoverability

1. **Mechanical enforcement.** `tests/unit/test_composition_render_fixtures.sh`
   runs on every push via `unit-tests.yml`. A Composition added without
   a `render-fixtures/` directory causes that test to fail immediately,
   printing the missing path. The pre-commit hook blocks the push one
   layer earlier for developers with pre-commit installed.

2. **Documentation pointer.** `AGENTS.md §6` carries a cross-link to
   this spec. `ai/testing-guidelines.md §6.1` names the convention in
   the Unit row of the test-layer table. Any agent authoring a new
   Composition reads both before writing tests (per §6.1 of AGENTS.md)
   and lands on the bootstrap procedure.

3. **Adversarial-review trigger.** The §6.4 adversarial-reviewer brief
   for any new XRD or Composition work includes the question: "Does the
   PR include `render-fixtures/input.yaml` and `render-fixtures/expected.yaml`?
   If not, what function-input bug class does the omission permit?" This
   question is added to `ai/testing-guidelines.md §6.4` as a mandatory
   checklist item for new Composition PRs.

## 11. Verification checklist

- [ ] `scripts/composition-render.sh --help` exits 0 and prints usage.
- [ ] `crossplane/xrds/platform-secret/render-fixtures/input.yaml` exists
  and contains `metadata.uid: "00000000-0000-0000-0000-000000000001"`.
- [ ] `crossplane/xrds/platform-secret/render-fixtures/expected.yaml` exists
  and contains at least two `---`-separated documents (ASM Secret and
  ExternalSecret).
- [ ] `scripts/composition-render.sh --xrd crossplane/xrds/platform-secret.yaml --comp crossplane/compositions/platform-secret.yaml --fixtures crossplane/xrds/platform-secret/render-fixtures/`
  exits 0 on the current main.
- [ ] Same invocation with `fmt: "k8-platform/%s"` replaced by
  `fmt: "wrong/%s"` in a temp copy of the Composition exits non-zero
  with a diff printed to stdout.
- [ ] `crossplane/xrds/platform-cluster/render-fixtures/input.yaml` and
  `expected.yaml` exist; render helper exits 0 for PlatformCluster.
- [ ] `tests/unit/test_composition_render_fixtures.sh` passes green:
  `bash tests/unit/test_composition_render_fixtures.sh`.
- [ ] `tests/unit/test_composition_render_catches_bug4.sh` passes green
  (i.e. the helper returns non-zero on the synthetic buggy fixture).
- [ ] `tests/unit/test_composition_render_diff_detected.sh` passes green
  (i.e. the helper returns non-zero on the mutated Composition).
- [ ] Pre-commit hook fires when `crossplane/compositions/platform-secret.yaml`
  is staged: `git stash && echo ' ' >> crossplane/compositions/platform-secret.yaml
  && git add crossplane/compositions/platform-secret.yaml && pre-commit run composition-render-dryrun`
  — expect exit 0 (golden already matches) or exit 1 (expected if you
  actually changed content).
- [ ] `AGENTS.md §6` cross-link is present.
- [ ] `ai/testing-guidelines.md §6.1` Unit row mentions `render-fixtures/`.

## 12. Rollout notes

**Backward compatibility.** The helper is additive. No existing test
changes behavior. The pre-commit hook only runs when pre-commit is
installed locally (opt-in per developer). The CI unit test is a new
file in `tests/unit/` — it does not modify any existing test.

**Audit-before-merge.** The implementing PR must commit both
`render-fixtures/` directories alongside `scripts/composition-render.sh`
and the unit tests, so `unit-tests.yml` lands green on the first push.
Staggering (helper merged first, fixtures later) would break CI on the
first push; do not stagger.

**Sandbox constraints.** This spec is orthogonal to AWS account
constraints (us-east-1 / us-west-2 instance limits) — `crossplane render`
is fully offline and provisions nothing. The integration tests (§7) use
Docker; confirm the CI runner has Docker available (it does for chainsaw
jobs).

**Coordination with in-flight branches.** SPEC-C4 (chainsaw golden-file
assert) uses the same `expected.yaml` format for the chainsaw layer. If
SPEC-C4 is implemented concurrently, the two implementing agents should
agree on the normalization strategy (both strip `uid`, `resourceVersion`,
`ownerReferences`, `creationTimestamp`) to avoid divergent fixture files.
Recommend implementing SPEC-S9 first (the golden files it produces become
the bootstrap input for SPEC-C4).

**Branch sequencing.** SPEC-S9 has no hard dependency on any other spec.
It can land as a standalone PR off `main` at any time. Phase 2b
(PlatformCluster) benefits from it being in place before the
PlatformCluster Composition authoring begins.

## 13. Estimated effort

**M** (medium, 2–3 hours).

- `scripts/composition-render.sh` (helper + normalization + diff logic):
  ~45 minutes authoring.
- `render-fixtures/` for PlatformSecret (bootstrap, normalize, verify):
  ~30 minutes.
- `render-fixtures/` for PlatformCluster (8 MRs, cross-resource refs,
  more complex probe claim): ~45 minutes.
- Three unit tests (§6.1–6.3): ~30 minutes.
- Pre-commit hook wiring + `tests/unit/run.sh` addition: ~15 minutes.
- Documentation updates (AGENTS.md, testing-guidelines.md, TESTING-PLAN.md):
  ~15 minutes.
- §11 verification checklist run: ~15 minutes.

Rollout-audit cost is low because all existing tests are untouched and
`unit-tests.yml` is a fast job. The one risk is the `crossplane render`
binary version — if the pinned version in `versions.env` does not match
the installed CLI, the unit test fails with a clear error. Budget an
extra 15 minutes to verify the binary install step in CI if the chainsaw
bootstrap does not already provide it for the unit job.
