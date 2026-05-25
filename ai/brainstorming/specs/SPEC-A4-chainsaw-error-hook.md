# SPEC-A4 — shared chainsaw `catch:` hook for failure diagnostics

## 1. Summary

Add a shared `catch:` action block (executed by chainsaw on any step
failure) to every existing scenario under `tests/chainsaw/` so that a
red CI run automatically captures the XR `describe`, every referenced
MR's `describe`, and recent reconcile events for the test namespace —
inline in the chainsaw log, the same artifact CI already uploads. The
block is defined once as a YAML template that scenarios include via
chainsaw's per-scenario `catch:` field (chainsaw does not yet support a
true repo-wide `catch:` in `Configuration`, so the template is copied
into each scenario and policed by a unit test).

## 2. Retro pain killed

- **Current failure-mode output is useless.** Today, a chainsaw red
  emits `step "<name>" failed: assertion timed out` with no surrounding
  context. The agent must re-run the scenario locally (kind boot
  + Crossplane install + provider, ~10 min) to reproduce and `kubectl
  describe` the resources. Several PRs in flight have shown this
  pattern — the chainsaw scenarios in `tests/chainsaw/platform-secret/`
  failed in CI and the lead agent could not diagnose without a local
  re-run.
- **Iteration cost on PR #X chainsaw work.** The impl agent's
  chainsaw-tests PR (referenced in the operator brief) is currently
  iterating with multi-minute CI loops because each failure surfaces
  symptom-only output. A scenario-attached `catch:` block converts each
  failed run into a self-contained diagnostic artifact, eliminating the
  re-run step.
- **AGENTS.md §6.7 (heavy-CI-workflow contract) makes this worse, not
  better.** The verifier-on-push pattern means the agent dispatches
  chainsaw manually against a SHA. A failed dispatch with no context is
  a wasted 5-minute kind boot — the agent has to dispatch *again* just
  to learn what failed. The `catch:` block makes the first dispatch
  diagnostic-complete.
- **Retro pattern across `retrospective/`.** Multiple sessions cite
  "chainsaw red, root cause unclear" as a debug-loop trigger. The
  classifier from SPEC-A2 helps once the agent has the XR/MR YAML — but
  inside CI, the YAML is what's missing. SPEC-A4 captures it.

## 3. Out of scope

- New chainsaw scenarios (those land alongside their owning XRD work).
- The classifier itself — SPEC-A2 owns turning the captured YAML into a
  named gap. SPEC-A4 only guarantees the YAML is in the log.
- Pre-failure diagnostics ("dump state on every assert step"). The
  block only fires on `catch:` (step failure), keeping the happy-path
  log small.
- Cluster-level dumps (`kubectl get all -A`, controller-manager logs).
  Scope is the XR + MRs + namespace events for the failing scenario.
- Modifying `.github/workflows/chainsaw.yml` itself. The diagnostic is
  inline in the chainsaw stdout the workflow already captures.
- A Bash post-step in the workflow that runs after chainsaw exits.
  Rejected because the kind cluster is torn down at job end and
  scenarios may run in parallel under `parallel: N` later — the
  diagnostic must be scoped to the failing scenario's resources, which
  only chainsaw knows.

## 4. Files to change / create

**Modify (add `catch:` to spec):**

- `/home/user/k8-platform/tests/chainsaw/_smoke/chainsaw-test.yaml`
- `/home/user/k8-platform/tests/chainsaw/platform-cluster/00-xrd-establishes/chainsaw-test.yaml`
- `/home/user/k8-platform/tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml`
- `/home/user/k8-platform/tests/chainsaw/platform-secret/01-claim-deletion-cleanup/chainsaw-test.yaml`
- `/home/user/k8-platform/tests/chainsaw/platform-secret/02-data-rotation/chainsaw-test.yaml`

**Create:**

- `/home/user/k8-platform/tests/chainsaw/_lib/catch-block.yaml` — the
  canonical YAML fragment (the `catch:` list) that scenarios paste in
  verbatim. Single source of truth so future drift can be linted.
- `/home/user/k8-platform/tests/chainsaw/_lib/README.md` — one
  paragraph naming the include pattern and the unit test that enforces
  it.
- `/home/user/k8-platform/tests/chainsaw/meta-catch-fires/chainsaw-test.yaml`
  — the "meta-test" scenario (see §6) whose only step deliberately
  fails to exercise the `catch:` block.
- `/home/user/k8-platform/tests/unit/test_chainsaw_catch_block.sh` —
  unit test that asserts every scenario YAML under `tests/chainsaw/`
  (except the smoke meta-test marker if needed) contains the canonical
  catch block by structural comparison against `_lib/catch-block.yaml`.

**Considered and rejected:**

- Updating `/home/user/k8-platform/tests/chainsaw/chainsaw-config.yaml`
  (chainsaw `Configuration` kind) to set a repo-wide `catch:`.
  Chainsaw's `Configuration` does not currently expose a `catch:` field
  applied across all tests — `catch:` lives on the `Test` spec or on
  individual `steps`. The unit-test-enforced copy is the closest
  equivalent.

## 5. Implementation notes

**Chainsaw `catch:` syntax.** Each `Test.spec.catch` is a list of
operations chainsaw runs whenever any step in that test fails (it does
not run on success; it does not run on cleanup). Operations available
include `describe`, `events`, `get`, `podLogs`, `script`, and `command`.
The shared block uses:

```yaml
catch:
  - describe:
      apiVersion: platform.k8-platform.io/v1alpha1
      kind: PlatformSecret      # overridden per-scenario when the XR kind differs
      namespace: ($namespace)
  - script:
      content: |
        set +e
        # Describe the XR (composite) the claim points at, if any.
        for claim_kind in platformsecret platformcluster; do
          for c in $(kubectl get "$claim_kind" -n "$NAMESPACE" -o name 2>/dev/null); do
            xr=$(kubectl get "$c" -n "$NAMESPACE" -o jsonpath='{.spec.resourceRef.name}' 2>/dev/null)
            [ -n "$xr" ] && kubectl describe "x${claim_kind}" "$xr" 2>&1 | head -c 1500
          done
        done
        # Describe every MR referenced by every XR in the namespace.
        for xr in $(kubectl get composite -o name 2>/dev/null); do
          kubectl get "$xr" -o jsonpath='{range .spec.resourceRefs[*]}{.apiVersion}{" "}{.kind}{" "}{.name}{"\n"}{end}' \
            | while read -r api kind name; do
                [ -z "$kind" ] && continue
                kubectl describe "$kind.$api" "$name" 2>&1 | head -c 1000
              done
        done
      env:
        - name: NAMESPACE
          value: ($namespace)
  - events:
      namespace: ($namespace)
```

**Scoping.** The block is scoped to the test's namespace via chainsaw's
`($namespace)` binding (chainsaw creates a per-test ephemeral
namespace; existing scenarios use `default` explicitly — those keep
`default` here for compatibility, or migrate to the chainsaw-managed
namespace as a follow-up). MR resources are cluster-scoped, but they
are reached *through* the XR refs filtered to XRs created in the test
namespace.

**Output budget — ≤5 KB per failure.** Each `describe` is truncated
with `head -c 1500` (XR) and `head -c 1000` (each MR); events output
chainsaw's default `--for=10m` window. A scenario with 1 XR + 3 MRs +
~20 events fits in well under 5 KB. Without truncation a verbose ASM
or EKS MR can produce 20 KB+. The truncation thresholds are documented
in `_lib/README.md`.

**Idempotency under retry.** Chainsaw's `catch:` runs once per failed
test invocation. Chainsaw does not retry tests by default; if a future
config adds retry (`spec.try.*` or `--repeat`), each retry triggers
its own catch — that is desirable (the diagnostic captures each
attempt's state) and the truncation budget keeps the cost bounded.

**Per-scenario XR kind override.** The `describe` operation needs the
XR kind. The `_lib/catch-block.yaml` is parameterized by a YAML
comment marker; scenarios paste the block and edit the `kind:` line to
their owning XR (`PlatformSecret`, `PlatformCluster`, etc.). The
script-based fallback iterates both known claim kinds so even a
missing override still produces a diagnostic.

**No new container images, no chainsaw plugin.** All operations use
chainsaw built-ins + the `kubectl` already on PATH in the chainsaw
job.

## 6. Tests required (per AGENTS.md §6.1)

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_chainsaw_catch_block.sh` | For every `chainsaw-test.yaml` under `tests/chainsaw/` (excluding `_lib/`), parse with `yq` and assert `.spec.catch` is non-empty AND contains operations of type `describe`, `script`, and `events`. Fail with the offending file path if any scenario is missing the block. |
| Unit | same file | Compare each scenario's `.spec.catch` block structurally against `tests/chainsaw/_lib/catch-block.yaml` — only the `describe.kind` field is allowed to differ. Drift in any other field fails the test, forcing future authors to update `_lib/` (single source of truth) rather than fork the block. |
| Chainsaw (meta-test) | `tests/chainsaw/meta-catch-fires/chainsaw-test.yaml` | A scenario with one step that **deliberately fails** (e.g. an `assert:` against a ConfigMap that is never created), wrapped in the shared `catch:` block. The scenario is marked with `metadata.labels.meta: "true"` and is included in the chainsaw run. Because the step is expected to fail, the test is wired with chainsaw's `spec.skip: false` and the runner script (`tests/chainsaw/run.sh`) is updated to invert exit-code expectation for any scenario whose name begins with `meta-`. Pass criterion: the chainsaw stdout for the meta-test contains the literal string `Describe Resource:` (chainsaw's describe-op marker) AND `Events:` AND a line beginning `Name:` — proving all three catch operations executed. |
| Unit | `tests/unit/test_chainsaw_catch_block.sh` (extension) | Assert the meta-test scenario exists and its `catch:` block is the canonical block. Prevents accidental deletion of the meta-test. |

Adversarial review (§6.4) — before authoring the unit + meta-test,
dispatch one `general-purpose` subagent with the §6.4 brief: facts
shipped (4 modified scenarios + 1 new lib + 1 meta-test + 1 unit
test), current plan above, the failure-mode (chainsaw-red-with-no-
context) as bug history, the job text verbatim, and the explicit
non-goal "we are not testing chainsaw's own retry semantics".

## 7. Testing suggestions (unit / integration / e2e)

This section catalogues follow-on tests as the surrounding system matures.
Distinguish from §6: §6 is the gate (the spec is not done without those
tests); §7 is the broader catalogue a future agent may draw from.

**Unit**

1. `tests/unit/test_chainsaw_catch_block.sh` — assert that for a
   synthetically generated `chainsaw-test.yaml` with no `catch:` field,
   the script exits non-zero and prints the offending path. Confirms the
   negative case is caught, not just the positive pass.
2. Same file — inject a `catch:` block that omits the `events:` operation
   (only `describe` + `script` present) and assert the structural-diff
   check fails with a message naming the missing operation type. Ensures
   partial compliance does not silently pass.
3. Same file — confirm the check ignores YAML files under `_lib/` itself
   (the canonical fragment should not be self-tested as a scenario).
4. Same file — supply a `catch:` block where `describe.kind` is changed
   to a different XR kind (the only allowed deviation) and assert the
   check still passes. Validates that the kind-override escape hatch
   works without widening the drift window.

**Integration**

1. `tests/integration/01_catch_block_live.sh` — spin up a minimal kind
   cluster with Crossplane installed, apply the meta-test scenario
   (`meta-catch-fires`), and assert the chainsaw stdout contains
   `Describe Resource:` and `Events:`. Proves the `catch:` block fires
   correctly against a real API server, not just as YAML structure.
2. Same script — assert that the happy-path scenario (`_smoke`) does NOT
   produce a `Describe Resource:` line when its step succeeds. Proves the
   catch block is silent on green runs.
3. `tests/integration/02_output_budget.sh` — run the meta-test and pipe
   chainsaw stdout through `wc -c`; assert the catch-block section is
   ≤ 5120 bytes. Validates the truncation constants hold against a real
   API server whose `describe` output may differ from synthetic fixtures.

**E2E**

The `tests/chainsaw/meta-catch-fires/chainsaw-test.yaml` scenario (§6)
already serves as the primary E2E proof — it is a live chainsaw run that
deliberately fails and verifies the catch block fires. Separate E2E
cases beyond the meta-test are not applicable at this time: the feature
is a diagnostic aid whose value is fully captured by the meta-test
scenario and the integration tests above. If chainsaw adds support for
a repo-wide `catch:` in `Configuration` in a future release, a
dedicated E2E scenario testing that mechanism would belong here.

## 8. Documentation updates

- `/home/user/k8-platform/ai/testing-guidelines.md` §6.4 (or wherever
  chainsaw-pattern guidance lives — add a subsection if absent):
  *"Every chainsaw scenario MUST inherit the canonical `catch:` block
  from `tests/chainsaw/_lib/catch-block.yaml`. The block is enforced
  by `tests/unit/test_chainsaw_catch_block.sh`."*
- `/home/user/k8-platform/AGENTS.md` §6.1 — extend the chainsaw row of
  the test-layers table with a parenthetical: *"(every scenario
  inherits the shared catch block — see testing-guidelines)"*.
- `/home/user/k8-platform/tests/chainsaw/README.md` — add an "Authoring
  a new scenario" subsection naming the `_lib/catch-block.yaml`
  paste-and-edit-`kind` pattern and pointing at the meta-test as the
  exemplar.
- No edits to retros or handoff — the change is mechanical.

## 9. Workflow / auto-invocation wiring

`tests/chainsaw/run.sh` discovers every `chainsaw-test.yaml` under
`tests/chainsaw/` automatically (chainsaw's default scenario walk).
The `catch:` block is therefore **auto-invoked** on every failed step
of every scenario with no opt-in flag and no workflow change.

`.github/workflows/chainsaw.yml` runs `bash tests/chainsaw/run.sh` —
the diagnostic output lands in the `Run chainsaw harness` step's
stdout, which the workflow already streams to the job log GitHub
retains for 90 days. No new artifact upload step is needed; the
existing log is the artifact.

`.github/workflows/chainsaw-verify.yml` is unaffected — it queries the
Actions API for a green chainsaw run against the PR's SHA; the
verifier does not parse chainsaw output.

The meta-test (§6) is part of the standard chainsaw run, so the same
auto-discovery covers it. The inverted-exit-code handling lives in
`tests/chainsaw/run.sh` — see §4 file list.

## 10. Discoverability

Three forcing functions, mirroring SPEC-A2's structure:

1. **The unit test fails CI on any new scenario missing the block.**
   `test_chainsaw_catch_block.sh` runs on every push (it lives in
   `tests/unit/run.sh`, which is fired by
   `.github/workflows/unit-tests.yml`). A new scenario authored
   without the block fails the PR check before chainsaw even runs.
2. **AGENTS.md §6.1 + testing-guidelines reference.** A future agent
   reading the chainsaw row of §6.1 sees the inheritance requirement
   and jumps to `tests/chainsaw/_lib/catch-block.yaml`.
3. **Adversarial-review §6.4 trigger.** Add a one-line bullet to
   `testing-guidelines.md` §6.4's adversarial-review checklist: *"For
   new chainsaw scenarios, confirm the shared `catch:` block is
   present and the kind override is correct."* This makes the
   reviewer subagent flag missing blocks during the test-drafting
   gate.

## 11. Verification checklist

Concrete observable checks the agent runs after implementing this
spec:

- [ ] `bash tests/unit/test_chainsaw_catch_block.sh` exits 0 with one
  `PASS` line per scenario YAML discovered (currently 5 + 1 meta).
- [ ] `yq '.spec.catch | length' tests/chainsaw/platform-secret/00-claim-creates-secret/chainsaw-test.yaml`
  returns ≥ 3 (describe, script, events).
- [ ] Manually edit one scenario step to deliberately fail, run
  `bash tests/chainsaw/run.sh` locally, confirm the chainsaw stdout
  for that scenario contains `Describe Resource:`, `Events:`, and a
  line beginning `Name:` for the XR.
- [ ] Revert the manual edit; rerun; confirm happy-path output
  contains NO `Describe Resource:` line (catch fires only on
  failure).
- [ ] Word-count the diagnostic block in the deliberately-failing
  run: `wc -c` of the catch-block section is ≤ 5120 bytes per
  failed scenario.
- [ ] `bash tests/unit/run.sh` includes the new test and exits 0.
- [ ] `grep -c "catch:" tests/chainsaw/_smoke/chainsaw-test.yaml`
  returns ≥ 1 (and similarly for each other scenario YAML).
- [ ] The meta-test scenario `meta-catch-fires` runs as part of the
  CI chainsaw job and is reported as PASS by `run.sh` (inverted
  exit code) without breaking the overall job exit.

## 12. Rollout notes

- **Coordinate with the impl agent's PR #X chainsaw-tests work**
  (currently in flight per operator brief). Two paths:
  - **Preferred:** land SPEC-A4 first on a small standalone branch
    (`feat/chainsaw-catch-block`), let PR #X rebase and inherit the
    block by editing its new scenarios to paste `_lib/catch-block.yaml`.
    Costs PR #X a 10-minute rebase; saves multiple iteration loops on
    the harder-to-debug failures PR #X is currently hitting.
  - **Fallback:** if PR #X is hours from merging, land SPEC-A4 *after*
    PR #X but immediately follow with a chore PR that retro-adds the
    block to PR #X's new scenarios. Test_chainsaw_catch_block.sh
    enforces no scenario escapes coverage.
- Stay on branch `spec/top-15-immediate-changes` for the spec itself
  per the operator brief. Implementation lands on a separate branch
  per AGENTS.md §3.
- No Terraform, no cloud resources, no AWS quota touched.
- Pluralsight sandbox constraints (us-east-1/us-west-2, t-class only,
  ≤9 EC2, no Bedrock/Marketplace) are not relevant — chainsaw runs in
  kind, AWS calls in scenarios already respect the constraint set.
- Backward compatible — existing scenarios gain output on failure
  paths only; happy-path runs unchanged.
- No account-derived values per AGENTS.md §8.1 — the catch block
  reads `($namespace)` and `${AWS_REGION:-us-east-1}` dynamically.

## 13. Estimated effort

**S** — small.

Justification: one YAML fragment authored once, pasted into five
existing scenarios (with one-line `kind:` edit each), one new
meta-test scenario (~20 lines), one bash unit test (~60 lines), three
small doc edits. No new tooling, no chainsaw plugins, no workflow
changes. Total: ~3–4 hours of focused work including the §6.4
adversarial-review pass and the §11 manual smoke. The load-bearing
risk is the meta-test's inverted-exit handling in `run.sh` — budget
an extra hour for that wiring.
