# SPEC-LA1 — crossplane-version-report.sh: unified version landscape script

Brainstorm ID: A1-039. Tier A item LA1 per `ai/brainstorming/specs/larger-list-preferences.md`.

---

## 1. Summary

Add `/home/user/k8-platform/scripts/crossplane-version-report.sh`, a
read-only diagnostic script that prints the complete Crossplane version
landscape of the management cluster in a single run: the Crossplane core
chart version (from the `crossplane` Helm release), every
`provider.pkg.crossplane.io` object (name, package ref, Healthy/Installed
conditions), every `function.pkg.crossplane.io` object, every
`DeploymentRuntimeConfig` and the Provider it services, and the expected
versions from `tests/chainsaw/versions.env` as a drift column so
live-vs-pinned skew is visible without mental arithmetic. A `--json` flag
emits machine-readable output for CI comparisons. The script is the
canonical first command before and after any Crossplane version bump. It
depends on `scripts/_lib/k8s-helpers.sh` (kubectl retry helpers) from
SPEC-S7; a four-line inline stub provides backward compatibility if
SPEC-S7 has not yet landed. No cluster state is mutated.

---

## 2. Retro pain killed

- **`retrospective/2026-05-25-76.md` Phase 2 — Bug 3 (open):** provider
  `v1.12.0` behaved slowly under Crossplane core `2.3.0`
  (`CreatedExternalResource` at `t+2m9s` vs. expected `~10s`), causing
  chainsaw timeouts at `245s`. Diagnosing this required correlating Helm
  output, `kubectl get provider.pkg`, and `versions.env` manually across
  three commands. This script collapses all three into one.

- **`retrospective/2026-05-25-76.md` ADR `b6c3c40133`:** the ADR names
  provider-vs-core version skew as the central upgrade-iteration risk and
  proposes no tooling. This spec is that tooling.

- **`retrospective/2026-05-25-76.md` Phase 2 — Bug 1/2 (beta flag
  names):** flag divergence between `helm.tf` and `run.sh` required
  manual comparison. The version report's CORE section surfaces live
  `helm get values` flags alongside the pinned version.

- **`retrospective/2026-05-24-62.md` Phase 4 ("claim Waiting"):** five
  chainsaw failures across PRs `#52`/`#53` required multiple slow
  diagnose dispatches before the provider layer was implicated. A
  version-skew report at PR-open time would have surfaced provider health
  before the first chainsaw run.

- **`retrospective/2026-05-25-70.md` Phase 2 — PRs #66–#68 (IRSA SA
  name mismatch):** resolving the SA-name bug required opening
  `terraform/management/helm.tf` to read the DRC manifest. The DRC
  BINDINGS table (Provider → DRC → pinned SA name) makes that binding
  visible in one command.

---

## 3. Out of scope

- **No cluster mutation.** Read-only throughout.
- **No IRSA or provisioning diagnosis.** That is SPEC-A1. This script
  reports the version landscape only.
- **No Composition/XRD inventory.** Those live in the application layer;
  this script covers the package-manager layer only.
- **No time-series or trend storage.** Point-in-time snapshot only.
- **Does not implement SPEC-S7.** The `k8s-helpers.sh` stub (§5.4)
  decouples sequencing; this spec lands independently.

### Considered and rejected

- **Inline into `diag-component.sh crossplane`:** that script dumps pod
  logs and events — a different query class. Mixing them obscures both.
  Separate scripts, separate concerns.
- **Python / jq-only pipeline:** all existing `scripts/` are bash; a
  Python dependency breaks the "kubectl + jq + helm on PATH" invariant.
- **ConfigMap snapshot for diffing:** over-engineering. The git-committed
  `versions.env` is the canonical version truth.

---

## 4. Files to change / create

| Path | What changes |
|---|---|
| `/home/user/k8-platform/scripts/crossplane-version-report.sh` | **Create.** The script (see §5). |
| `/home/user/k8-platform/scripts/README.md` | Add one inventory-table row. |
| `/home/user/k8-platform/tests/unit/test_crossplane_version_report.sh` | **Create.** Unit tests (see §6). |
| `/home/user/k8-platform/tests/unit/fixtures/version-report/` | **Create.** Stub `kubectl`, `helm`, `aws` scripts (skew fixture + no-skew fixture). |
| `/home/user/k8-platform/AGENTS.md` §6.3 | Add one sentence: "Before and after any Crossplane version bump, run `scripts/crossplane-version-report.sh` and confirm the SKEW column shows `ok` for all rows." |
| `/home/user/k8-platform/ai/handoff.md` | One-line addition in the scripts inventory naming the script and the Bug-3 motivation. |

---

## 5. Implementation notes

### 5.1 Invocation

```
scripts/crossplane-version-report.sh [--json] [--help]
```

`--json` emits a single JSON object to stdout. `--help` prints the
two-line synopsis and exits 0 without calling kubectl or helm.

### 5.2 Sections and fail-soft behavior

Each section is independently fail-soft: a failed `kubectl get` prints
`<SECTION>: unavailable (<reason>)` and the script continues. Exit code
is `0` unless no cluster is reachable at all.

1. **HEADER** — timestamp, `kubectl config current-context`,
   `aws sts get-caller-identity --query Arn` (pre-flight per AGENTS §8.1).
2. **CORE** — `helm list -A -o json | jq '.[] | select(.name=="crossplane")'`.
   Drift column: compare `chart_version` against `CROSSPLANE_CHART_VERSION`
   from `versions.env`; emit `ok` or `SKEW(live=X pinned=Y)`.
3. **PROVIDERS** — `kubectl get provider.pkg.crossplane.io -o json`.
   Columns: name, package tag, Healthy, Installed, pinned (from
   `versions.env` by name match), drift. Unmatched rows show `—`.
4. **FUNCTIONS** — `kubectl get function.pkg.crossplane.io -o json`.
   Same columns. Compare against `FUNCTION_PATCH_AND_TRANSFORM_VERSION`.
5. **DRC BINDINGS** — `kubectl get deploymentruntimeconfigs.pkg.crossplane.io
   -o json`. Columns: DRC name, `spec.deploymentTemplate.spec.serviceAccountName`,
   the Provider whose `.spec.runtimeConfigRef.name` matches this DRC.
   This is the binding that was opaque during PRs #66–#68.
6. **SKEW SUMMARY** — `All versions ok` or
   `SKEW DETECTED: <comma-separated names>`.

### 5.3 Output format (abbreviated example)

```
== CROSSPLANE VERSION REPORT ==
Generated: 2026-05-25T14:03:22Z  context: ...k8-platform-mgmt

── CORE ─────────────────
  chart       installed  pinned  drift
  crossplane  2.3.0      2.3.0   ok

── PROVIDERS ────────────
  name                         tag      healthy  pinned   drift
  provider-family-aws          v1.12.0  True     v1.12.0  ok
  provider-aws-secretsmanager  v1.12.0  True     v1.12.0  ok

── FUNCTIONS ────────────
  name                          tag     healthy  pinned  drift
  function-patch-and-transform  v0.8.2  True     v0.8.2  ok

── DRC BINDINGS ─────────
  drc-name             pinned-sa                    services-provider
  provider-family-aws  upbound-provider-family-aws  provider-family-aws

── SKEW SUMMARY ─────────
  All versions ok
== END REPORT ==
```

### 5.4 `--json` schema

```json
{
  "generated": "<ISO8601>", "context": "<arn>",
  "core": {"installed": "2.3.0", "pinned": "2.3.0", "drift": "ok"},
  "providers": [{"name": "provider-family-aws", "package_tag": "v1.12.0",
    "healthy": true, "pinned": "v1.12.0", "drift": "ok"}],
  "functions": [{"name": "function-patch-and-transform",
    "package_tag": "v0.8.2", "healthy": true, "pinned": "v0.8.2", "drift": "ok"}],
  "drc_bindings": [{"drc_name": "provider-family-aws",
    "pinned_sa": "upbound-provider-family-aws",
    "services_provider": "provider-family-aws"}],
  "skew_detected": false, "skew_names": []
}
```

CI gate: `jq '.skew_detected == false'` on the `--json` output.

### 5.5 SPEC-S7 stub fallback

```bash
if [ -f "$(dirname "$0")/_lib/k8s-helpers.sh" ]; then
  source "$(dirname "$0")/_lib/k8s-helpers.sh"
else
  kube_retry() { "$@"; }  # no retry until SPEC-S7 lands
fi
```

### 5.6 `versions.env` sourcing

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "${REPO_ROOT}/tests/chainsaw/versions.env"
```

If the file is absent, all drift columns show `—` and a warning is
printed to stderr. The script does not fail.

### 5.7 Performance and AWS calls

Target wall-clock under 5 seconds (four `kubectl get -o json` + one
`helm list` + one `aws sts get-caller-identity`). Retry adds up to 6s
per transient failure; hard per-section timeout is 15 seconds.
`aws sts get-caller-identity` is the only AWS call. No IAM, no CloudTrail.

---

## 6. Tests required (per AGENTS.md §6.1)

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_crossplane_version_report.sh` | `bash -n` exits 0 (syntax). |
| Unit | same | `--help` exits 0, prints "Usage:", no kubectl call. |
| Unit | same (skew fixture) | stdout contains `SKEW(live=2.2.0 pinned=2.3.0)`; SKEW SUMMARY names `crossplane`. |
| Unit | same (no-skew fixture) | drift column shows `ok`; summary shows `All versions ok`. |
| Unit | same (provider unavailable) | script exits 0; stdout contains `PROVIDERS: unavailable`; remaining sections render. |
| Unit | same (`--json`) | `jq '.skew_detected'` returns `false`; `.providers | length` is 2; `.drc_bindings | length` is 1. |

The skew fixture deliberately sets the stub `helm` to return
`chart_version=2.2.0` while `versions.env` pins `2.3.0`. Both fixtures
(matching and mismatching) must be present to prove the detection fires
only on real skew.

Per AGENTS.md §6.4, the implementing agent runs an adversarial subagent
review before authoring tests. Brief covers: drift-column values, `--json`
schema, fail-soft semantics, no-mutation guarantee, repo-root detection,
Bug 3 history (`retrospective/2026-05-25-76.md`), and explicit non-goals
(no live cluster in unit layer, no IRSA testing, no AWS mutations).

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fixtures in `tests/unit/fixtures/version-report/` override `kubectl`,
`helm`, and `aws` via `PATH` prepend. Beyond the §6 gate tests:

1. **versions-env missing:** stub removes file; assert drift shows `—`
   and warning appears on stderr; exits 0.
2. **DRC with no provider reference:** stub provider has no
   `runtimeConfigRef`; assert `services-provider` column shows `—`.
3. **Multiple providers, partial skew:** stub returns three providers,
   one with mismatched tag; assert SKEW SUMMARY names only that one.
4. **Empty cluster:** all stubs return `No resources found.`; assert
   every section shows `unavailable`/`(none)`, exits 0, `--json` is
   valid JSON with all lists empty.

### Integration

Not part of the default unit CI gate; run manually against a kind cluster.

1. `tests/integration/13_version_report_smoke.sh` — after chainsaw kind
   cluster is up, assert CORE shows version matching `versions.env` and
   SKEW SUMMARY shows `All versions ok`.
2. Mutate a temp copy of `versions.env` to `CROSSPLANE_CHART_VERSION=99.0.0`;
   assert SKEW SUMMARY lists `crossplane`. Restore file.

### E2E

No dedicated chainsaw scenario — this is a read-only diagnostic, not a
cluster-state assertion. The real-world e2e coverage comes from the
`crossplane-v2-upgrade-triage` skill (SKILL-SPEC-befefff7cb), whose
Phase 0 ("establish baseline") should invoke
`scripts/crossplane-version-report.sh --json` and capture the before
snapshot. This is a deliberate scope decision, not an oversight.

---

## 8. Documentation updates

- **`AGENTS.md` §6.3:** one sentence added (see §4). Joins the existing
  `kyverno-policies.sh` / `kyverno-violations.sh` pattern.
- **`scripts/README.md`:** one inventory row — "Crossplane core + Provider
  + Function + DRC version landscape; live-vs-pinned drift column."
- **`ai/handoff.md`:** one-line scripts-inventory entry with Bug-3
  motivation and `--json` flag note.
- **`ai/testing-guidelines.md` §6.4:** add a Crossplane-specific bullet:
  "Was `crossplane-version-report.sh` run before and after the bump to
  confirm zero drift?"

---

## 9. Workflow / auto-invocation wiring

Manual-invoke by default. Three forcing functions:

1. **`AGENTS.md §6.3` (amended):** any agent performing a version bump
   reads §6.3 and sees the explicit instruction to run the script. No
   memory required; the procedure names the command.
2. **`crossplane-v2-upgrade-triage` skill Phase 0:** a one-line addition
   to SKILL-SPEC-befefff7cb invokes `--json` and saves the before snapshot.
   Scoped to that skill's own authoring PR.
3. **Optional future CI gate:** `--json | jq '.skew_detected == false'`
   as a pre-flight step in `.github/workflows/chainsaw.yml`. Not required
   in the implementing PR; deferred until the team is ready for the gate.

No new workflow file is created by this spec.

---

## 10. Discoverability

1. **Mechanical enforcement:** `AGENTS.md §6.3` names the command inside
   the mandatory test-bundle procedure. Skipping §6.3 is a documented
   procedure violation. Future CI hardening: `jq '.skew_detected'` on
   `--json` output as a chainsaw pre-flight step (§9 option 3).
2. **Documentation pointer:** `scripts/README.md` inventory table and
   `ai/handoff.md` scripts section both name the script. An agent reading
   either before a version-bump task encounters it without prior knowledge.
3. **Adversarial-review trigger:** new bullet in `ai/testing-guidelines.md`
   §6.4 Crossplane subsection: "Was `crossplane-version-report.sh` run
   before and after the bump?" The review subagent flags missing evidence.

---

## 11. Verification checklist

- [ ] `bash -n scripts/crossplane-version-report.sh` exits 0.
- [ ] `scripts/crossplane-version-report.sh --help` exits 0, prints
  "Usage:", makes no kubectl or helm call.
- [ ] `bash tests/unit/test_crossplane_version_report.sh` exits 0 with
  PASS lines for all six §6 cases.
- [ ] Against skew fixture: stdout contains literal `SKEW(`.
- [ ] Against no-skew fixture: stdout contains `All versions ok`; zero
  occurrences of `SKEW(`.
- [ ] `scripts/crossplane-version-report.sh --json | jq '.skew_detected'`
  returns `false` against no-skew fixture.
- [ ] `grep -c "crossplane-version-report" scripts/README.md` returns ≥ 1.
- [ ] `grep -c "crossplane-version-report" AGENTS.md` returns ≥ 1.
- [ ] With `_lib/k8s-helpers.sh` absent: script warns and exits 0 against
  the no-skew fixture (stub fallback active).
- [ ] `wc -l scripts/crossplane-version-report.sh` is between 80 and 180.

---

## 12. Rollout notes

- **Backward compatibility:** new file only. Nothing existing changes
  behavior. The `AGENTS.md §6.3` edit is additive.
- **Audit before merge:** no existing resource manifests, Terraform, or
  CI workflows require updating. Confirm the new test file is picked up
  by `tests/unit/run.sh` (add explicitly if the glob does not cover it).
- **Pluralsight sandbox:** `aws sts get-caller-identity` is read-only;
  kubectl/helm are in-cluster reads. No EC2, no Bedrock, no Marketplace.
  Fully within constraints.
- **Branch sequencing:** independent of all in-flight branches. The
  SPEC-S7 stub (§5.5) means this can land before or after SPEC-S7 without
  a blocked dependency. The SKILL-SPEC-befefff7cb Phase-0 wiring is a
  follow-on one-line chore.

---

## 13. Estimated effort

**S** (approximately 1 hour).

- Script authoring (~25 min): four `kubectl get -o json | jq` pipelines,
  one `helm list` parse, one `versions.env` source, drift comparison,
  `--json` mode (~20 extra lines), SPEC-S7 stub (4 lines).
- Unit tests + fixtures (~20 min): minimal shell stubs echoing canned
  JSON; test harness pattern from `test_chainsaw_kind_config.sh`.
- Doc edits — `AGENTS.md`, `scripts/README.md`, `ai/handoff.md`,
  `ai/testing-guidelines.md` (~5 min combined).
- §6.4 adversarial review + smoke against stub fixtures (~10 min).

Rollout audit cost is negligible: no existing behavior changes; the only
risk is a malformed `--json` output, caught by the unit test.
