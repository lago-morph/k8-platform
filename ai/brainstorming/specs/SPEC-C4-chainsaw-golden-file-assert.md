# SPEC-C4 — Chainsaw golden-file assertion of composition-rendered MR spec

## 1. Summary

Every chainsaw scenario that exercises a Composition asserts the rendered
Managed Resource's `spec.forProvider` (and any other load-bearing subtree)
against a committed YAML fixture under
`tests/chainsaw/<scenario>/expected/<resource>.yaml`. The scenario's
`assert:` block uses chainsaw's `(file('expected/<resource>.yaml'))`
reference so the fixture is the authoritative source of "what the
Composition is supposed to render". Composition changes therefore can
only land in a PR that also updates the matching golden file — the diff
is the review surface.

## 2. Retro pain killed

**Bug 4 (PR #61 — Composition `string-transform` shape regression).**
The PlatformSecret Composition contained a `transforms` entry of type
`string` that was missing the required `type: Format` discriminator under
the `string:` block. Crossplane v2.0.1's composition function decoder
runs **strict decoding** against the function input shape; the malformed
transform was silently dropped on the renderer side, so the resulting MR
had the wrong `spec.forProvider.name` value (the string-format suffix
never appeared). Every chainsaw scenario at the time asserted only "the
MR with this kind/name exists" and "the claim reaches Ready=True" — both
were true. The bug shipped to live AWS and was caught only when the
integration suite probed the actual ASM key.

A golden-file assertion of `spec.forProvider` on the rendered MR would
have failed inside chainsaw on the first PR iteration: the expected name
would have included the formatted suffix; the rendered name would not.

The companion lint, `tests/unit/test_composition_string_transform_type.sh`
(added by PR #61), defends against the specific *input* mistake. SPEC-C4
defends against the *output* class of mistake — any silent regression in
the rendered MR shape, not just string-transform ones.

## 3. Out of scope

- **Non-Crossplane chainsaw scenarios.** Scenarios that only exercise
  Kubernetes-native resources (e.g. `tests/chainsaw/_smoke/`) do not
  require golden files; their assertion surface is already explicit.
- **AWS-side shape assertions.** Whether the ASM secret actually exists
  in AWS with the expected attributes is SPEC-C2's job (live-account
  read-back). SPEC-C4 only verifies what Crossplane's composition
  reconciler produces *inside the kind cluster*.
- **XRD schema validation.** Already covered by the
  `platform-cluster/00-xrd-establishes` scenario's `--dry-run=server`
  reject tests.
- **Status-subtree assertion.** Status fields (`status.conditions`,
  `status.atProvider`) are populated by the provider, not by the
  composition — they're a separate layer and remain asserted positionally
  / by `kubectl wait` as today. SPEC-C4 is `spec`-only.

## 4. Files to create / amend

### Per existing chainsaw scenario

For every scenario under `tests/chainsaw/<xrd>/<scenario>/` whose `apply:`
block contains a claim that triggers Composition rendering, add:

| Path | Contents |
|---|---|
| `tests/chainsaw/platform-secret/00-claim-creates-secret/expected/asm-secret.yaml` | Expected `Secret.secretsmanager.aws.upbound.io` `spec.forProvider` subtree |
| `tests/chainsaw/platform-secret/00-claim-creates-secret/expected/external-secret.yaml` | Expected `ExternalSecret.external-secrets.io` `spec` subtree |
| `tests/chainsaw/platform-secret/01-claim-deletion-cleanup/expected/asm-secret.yaml` | Same shape as 00 (pre-deletion) |
| `tests/chainsaw/platform-secret/01-claim-deletion-cleanup/expected/external-secret.yaml` | Same |
| `tests/chainsaw/platform-secret/02-data-rotation/expected/asm-secret.yaml` | Same; `refreshInterval` reflected in the matching `external-secret` golden |
| `tests/chainsaw/platform-secret/02-data-rotation/expected/external-secret.yaml` | `spec.refreshInterval: 10s` |

`platform-cluster/00-xrd-establishes` is an XRD-establishment scenario
(no live Composition render — uses `--dry-run=server`); it gets a golden
file ONLY for the rendered Composition's `spec.pipeline` shape if a
follow-on render-step is added, otherwise it is exempt and noted in §12
rollout.

### Per scenario `chainsaw-test.yaml`

Each scenario's existing `assert:` block adds one or more steps of the
form:

```yaml
- name: assert rendered ASM Secret MR matches golden
  try:
    - assert:
        file: expected/asm-secret.yaml
```

The golden file itself uses chainsaw's resource-fragment syntax —
`apiVersion`, `kind`, `metadata.{name,namespace,labels}` to select; the
asserted subtree (`spec.forProvider.*`) underneath. Fields chainsaw must
ignore (UID-derived name suffixes, owner references with random suffixes)
are written with chainsaw's binding/JMESPath wildcards — see §5.

### New files (none outside `tests/chainsaw/`)

This spec writes only under `tests/chainsaw/`. The chainsaw workflow,
the Composition source, and the XRD source are untouched.

## 5. Implementation notes

### Chainsaw `(file)` reference syntax

Chainsaw supports loading the asserted resource fragment from a file via
either:

- `assert: { file: <relative-path> }` — the entire YAML doc is the
  fragment, and chainsaw's partial-match semantics apply (only fields
  present in the file are checked; the live resource may have more).
- Inline expression `(file('expected/<resource>.yaml'))` — useful when
  composing multiple fragments in a single step.

Use the first form per-step for readability. Paths are relative to the
scenario directory.

### Handling fields with random / timestamp / UID-derived values

Three classes of churn appear in the rendered MR:

1. **UID-derived names** (`metadata.name: k8-platform-<xr-uid>-...`).
   The XR UID is unstable per run. **Strategy:** assert only the
   `metadata.labels.crossplane.io/composite` label (deterministic =
   the XR name from the claim) and the `metadata.generateName` prefix;
   omit `metadata.name` from the golden file. Chainsaw's partial-match
   ignores absent fields.

2. **Owner references with random suffixes.** Same UID issue.
   **Strategy:** omit `metadata.ownerReferences` entirely from the
   golden file. The fact that the MR is owned correctly is covered by
   the existing `setup`/teardown scenarios — golden files are about
   *rendered shape*, not lifecycle linkage.

3. **Timestamps / generation / resourceVersion.** Never include in a
   golden file.

For scenarios where a value MUST be checked but is run-derived (e.g.
`spec.forProvider.region` should equal whatever the claim asked for),
use chainsaw's `set:` (or `bindings:` at scenario top, depending on
chainsaw version) to inject the run-time value into the assert. Concrete
pattern:

```yaml
- assert:
    bindings:
      - name: expected_region
        value: us-east-1
    file: expected/asm-secret.yaml
# inside expected/asm-secret.yaml:
spec:
  forProvider:
    region: ($expected_region)
```

If a target subtree is genuinely free-form (e.g. a JSON-encoded blob
inside `spec.forProvider.forceOverwriteReplicaSecret`), use chainsaw's
`(starts_with(...))` / `(length(@) > 0)` JMESPath expressions in the
golden file rather than hardcoding the value.

### Bootstrapping a golden file from the first green run

1. Push the Composition + scenario without the golden file but WITH the
   assert step pointing at it. The scenario fails ("file not found").
2. Locally (or in a debug job), after the scenario gets far enough that
   the MR is rendered, dump it: `kubectl get
   secret.secretsmanager.aws.upbound.io -l
   crossplane.io/composite=<xr-name> -o yaml > expected/asm-secret.yaml`.
3. Hand-edit the dump: strip `status:`, `metadata.{uid,resourceVersion,
   generation,creationTimestamp,managedFields,ownerReferences}`; replace
   run-derived values with binding references or wildcards per the
   strategy above; keep only the fields you want the test to defend.
4. Commit the trimmed file. Re-run; it must now pass.

### When the Composition intentionally changes

The Composition author updates the golden file in the same PR. The PR
diff shows both files; the reviewer checks that the new golden matches
the intended new MR shape. If the author updates the Composition but
not the golden, chainsaw fails — and the failure message points
directly at the diverged field.

### Workflow integration

No change to `.github/workflows/chainsaw.yml`. Chainsaw auto-discovers
`chainsaw-test.yaml` under `tests/chainsaw/`; the new assert steps run
as part of every scenario invocation.

## 6. Tests required

Per AGENTS.md §6.1 (author tests alongside features) and §6.2 (TDD on
bug fixes):

### 6.1 Meta-test: drift detection

Add `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`. It:

1. Loads the production PlatformSecret Composition.
2. Applies a *mutated* copy with `spec.forProvider.region` patched to
   a wrong value via a `script:` step (`yq` in-place).
3. Re-runs the `00-claim-creates-secret` assert (`(file('../../platform-secret/00-claim-creates-secret/expected/asm-secret.yaml'))`).
4. Expects the assert to FAIL (uses chainsaw's `try:` + `catch:` with
   `expected: false` / inverse-error semantics, or wraps the
   `chainsaw run` invocation in a `script:` step that grep-asserts
   non-zero exit).

This is the §6.1 maximal-coverage move: a Composition mutation in the
absence of a golden update must be caught.

### 6.2 TDD fixture reproducing Bug 4

Add `tests/chainsaw/_meta/bug4-replay/chainsaw-test.yaml` (or a unit-test
script `tests/unit/test_chainsaw_golden_catches_bug4.sh` if the
chainsaw-in-chainsaw pattern is awkward). The fixture:

1. Checks out a copy of the pre-PR-#61 Composition (the file is in
   `git log` — embed a frozen copy under
   `tests/fixtures/compositions/platform-secret-pre-pr61.yaml`).
2. Renders it against a probe claim in a kind cluster.
3. Asserts the rendered MR against the current golden file.
4. Expected outcome: assert FAILS, with the failure message naming
   the divergent `spec.forProvider.*` field.

Both meta-tests run inside the existing `chainsaw.yml` job; they add
~30s. If the meta-tests pass green (i.e. the mutation is NOT caught),
the whole SPEC-C4 mechanism is broken and the PR is blocked.

### 6.3 Unit-test the golden-file presence invariant

`tests/unit/test_chainsaw_golden_files_present.sh`: for every directory
under `tests/chainsaw/<xrd>/<scenario>/` whose `chainsaw-test.yaml`
contains an `apply:` against a `platform.k8-platform.io/v1alpha1` claim,
assert that `expected/` exists and is non-empty. Catches "author added
a new scenario, forgot the golden file" at unit-test time.

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast (<10 s each). Names follow `tests/unit/test_<name>.sh`.

1. `tests/unit/test_chainsaw_golden_files_present.sh` — for every scenario
   directory under `tests/chainsaw/<xrd>/<scenario>/` whose
   `chainsaw-test.yaml` contains an `apply:` against a
   `platform.k8-platform.io/v1alpha1` claim, assert that `expected/`
   exists and is non-empty.
2. `tests/unit/test_golden_no_volatile_fields.sh` — for every
   `tests/chainsaw/**/expected/*.yaml`, assert the file contains none of
   `uid:`, `resourceVersion:`, `creationTimestamp:`, `managedFields:`, or
   `ownerReferences:`; the grep must return non-zero (zero lines matched).
3. `tests/unit/test_golden_has_spec_forProvider.sh` — each golden file
   for an ASM-backed MR contains a `spec.forProvider:` block (yq
   `.spec.forProvider | type` returns `!!map`).
4. `tests/unit/test_chainsaw_assert_references_golden.sh` — each
   `chainsaw-test.yaml` under `tests/chainsaw/platform-secret/` contains
   at least one `file: expected/` reference (`grep -r` returns non-zero
   count).
5. `tests/unit/test_golden_region_uses_binding.sh` — golden files for
   region-bearing MRs reference a binding expression `($` rather than a
   hardcoded region string such as `us-east-1`.

### Integration

Tests against a live kind cluster. Names follow
`tests/integration/<NN>_<name>.sh`.

1. `tests/integration/10_golden_assert_passes_on_fresh_render.sh` —
   applies the PlatformSecret claim to a kind cluster, waits for the MR
   to reach `Synced=True`, then invokes `chainsaw run` for
   `00-claim-creates-secret`; asserts exit 0.
2. `tests/integration/11_golden_assert_fails_on_mutated_composition.sh` —
   applies a yq-mutated copy of the Composition (wrong region value),
   runs the same assert step, asserts exit non-zero and that the failure
   message names `spec.forProvider.region`.
3. `tests/integration/12_bug4_regression_golden.sh` — loads the frozen
   pre-PR-#61 Composition from
   `tests/fixtures/compositions/platform-secret-pre-pr61.yaml`, renders
   it against a probe claim, runs the assert; expects exit non-zero with
   the divergent `spec.forProvider.name` field named in output.

E2E is the primary validation surface for this spec; integration tests
confirm the golden mechanism works in isolation before full-stack
scenarios run.

### E2E

Full chainsaw scenarios. Names follow
`tests/chainsaw/<scenario>/chainsaw-test.yaml`.

1. `tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml`
   — assert step `assert: { file: expected/asm-secret.yaml }` passes
   after claim reaches `Ready=True`.
2. `tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml`
   — assert step `assert: { file: expected/external-secret.yaml }` passes
   for the rendered ExternalSecret.
3. `tests/chainsaw/platform-secret/01-claim-deletion-cleanup/chainsaw-test.yaml`
   — same two assert steps pass before the deletion step fires.
4. `tests/chainsaw/platform-secret/02-data-rotation/chainsaw-test.yaml`
   — golden `spec.refreshInterval: 10s` is matched after rotation claim
   is applied.
5. `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml` — meta-test
   confirms that a deliberate Composition mutation is REJECTED by the
   golden (chainsaw step expected to fail; wrapper asserts non-zero exit).

`platform-cluster/00-xrd-establishes` uses `--dry-run=server` and does
not trigger a live Composition render; E2E golden-file assertions are
**not applicable** for that scenario until a live-render step is added
in a future phase. This is a deliberate scoping decision, not an
oversight — see §3 "Non-Crossplane chainsaw scenarios".

Distinguish from §6: §6 is the gate (the spec is not done without those
tests); §7 is the broader catalogue of tests to add as the surrounding
system matures.

## 8. Documentation updates

### `ai/testing-guidelines.md` §6.1

Append to the "Chainsaw" row in the test-layer table:

> Chainsaw scenarios that exercise a Composition MUST include a
> golden-file assertion (`tests/chainsaw/<scenario>/expected/<resource>.yaml`)
> against the rendered MR's `spec.forProvider`. New XRDs ship with at
> least one happy-path scenario AND its golden file in the same PR
> — see SPEC-C4.

### `ai/testing-guidelines.md` §6.4

Add an adversarial-reviewer trigger row:

> When a new Composition or a new MR resource type is introduced, the
> adversarial-reviewer brief MUST explicitly challenge golden-file
> completeness: "Which `spec.forProvider` subtrees are NOT in the
> golden file, and what regression class does each omission permit?"
> Adopt every suggestion that names a specific contract.

### `AGENTS.md`

Add a one-line cross-link under §6 ("Test discipline"):

> Golden-file assertion of composition-rendered MRs is mandatory —
> see SPEC-C4 (`ai/brainstorming/specs/SPEC-C4-chainsaw-golden-file-assert.md`)
> and testing-guidelines.md §6.1.

### `ai/TESTING-PLAN.md`

Add bug-class row: "Composition silently renders wrong MR shape →
golden-file assertion in chainsaw" with Bug 4 as the precedent.

## 9. Workflow / auto-invocation wiring

`.github/workflows/chainsaw.yml` already auto-discovers every
`chainsaw-test.yaml` under `tests/chainsaw/`. The new golden assertions
run as additional `assert:` steps inside each existing scenario — no
new workflow file, no new job, no new dispatch surface. Heavy-CI
contract (§6.7) is unchanged: chainsaw remains workflow_dispatch-only,
verified pre-PR.

The `chainsaw.yml` path-filter already includes `tests/chainsaw/**` and
`crossplane/**`; golden-file edits and Composition edits both trigger
the same dispatch requirement. No change to the verifier
(`chainsaw-verify.yml`).

## 10. Discoverability for future agents

1. **PR diff coupling.** A PR that touches
   `crossplane/compositions/platform-secret.yaml` but not any
   `tests/chainsaw/platform-secret/*/expected/*.yaml` is anomalous and
   visually obvious in the GitHub PR file list — the reviewer asks
   "did you mean to leave the goldens untouched?"
2. **Unit test backstop.** `test_chainsaw_golden_files_present.sh`
   (§6.3) hard-fails CI on any new scenario lacking an `expected/`
   directory.
3. **Testing-guidelines checklist item.** A new bullet under §6.1
   reads: "For new Compositions, did you commit the golden file
   alongside the Composition?"
4. **Failure message ergonomics.** Chainsaw prints a diff between
   expected and actual on assert failure — the message itself teaches
   the next agent what changed.

## 11. Verification checklist

- [ ] Every chainsaw scenario under `tests/chainsaw/platform-secret/`
  has an `expected/` directory with one YAML per rendered MR.
- [ ] Each scenario's `chainsaw-test.yaml` references the golden via
  `assert: { file: expected/<resource>.yaml }`.
- [ ] Golden files contain no fields chainsaw cannot match (no `uid`,
  no `resourceVersion`, no `creationTimestamp`).
- [ ] Run-derived values use bindings, not hardcoded.
- [ ] `tests/chainsaw/_meta/composition-drift/` meta-test passes (i.e.
  the mutated Composition is correctly REJECTED by the golden).
- [ ] `tests/chainsaw/_meta/bug4-replay/` (or the equivalent unit
  test) passes (the historical-buggy Composition is REJECTED).
- [ ] `tests/unit/test_chainsaw_golden_files_present.sh` is green on
  the current scenario set.
- [ ] `chainsaw.yml` dispatched green against the spec branch's HEAD
  SHA (per §6.7) BEFORE the PR is opened.
- [ ] `testing-guidelines.md` §6.1, §6.4, and `AGENTS.md` carry the
  cross-links.

## 12. Rollout notes

**Order matters — golden files MUST be backfilled before the assert
steps are wired in, or every existing scenario breaks on the first
chainsaw run.**

Backfill sequence (single PR or stacked PRs):

1. **Stage 1: bootstrap goldens, no assert steps yet.** For each
   existing scenario (`platform-secret/00`, `01`, `02`), capture the
   currently-rendered MR via the bootstrap procedure in §5 and commit
   `expected/*.yaml`. Run chainsaw — must stay green (nothing new
   asserted yet).
2. **Stage 2: wire the assert steps.** Edit each
   `chainsaw-test.yaml` to add `assert: { file: expected/... }` steps.
   Run chainsaw — must stay green (assertion matches captured shape).
3. **Stage 3: add the meta-tests** (`_meta/composition-drift`,
   `_meta/bug4-replay`). Confirm both correctly FAIL the mutated /
   historical-buggy inputs.
4. **Stage 4: add the unit-test backstop** + docs updates.

The `platform-cluster/00-xrd-establishes` scenario does NOT render a
Composition (uses `--dry-run=server`) and is exempt from Stages 1–2
until phase 3 introduces a live-render scenario. Note this exemption
in the scenario's header comment so the next agent doesn't add a
golden file by mistake.

If chainsaw's golden assert fails for a reason unrelated to a real
regression (e.g. provider-family-aws version bump introduced a new
default field), the fix is to update the golden file in the same
commit as the version bump — same discipline as updating snapshots
in any other test harness.

## 13. Estimated effort

**M** (medium). Bootstrapping the golden files for the three existing
PlatformSecret scenarios is ~1 hour each (capture, trim, verify). The
meta-tests are ~2 hours total. Docs and unit-test backstop ~1 hour.
The dispatch-and-verify loop per §6.7 dominates wall-clock: budget
half a day. Subsequent XRDs inherit the pattern at near-zero marginal
cost — adding a new scenario means adding one more `expected/` file
during normal authoring.
