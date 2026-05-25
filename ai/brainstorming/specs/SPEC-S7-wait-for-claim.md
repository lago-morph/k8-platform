# SPEC-S7 — `scripts/wait-for-claim.sh` canonical wait primitive

Tier S item S7 from `ai/brainstorming/specs/larger-list-preferences.md`.
Brainstorm origin: A1-021. Part of the Tier S multiplier primitives sequence.

---

## 1. Summary

Add `scripts/wait-for-claim.sh <kind> <name> [ns] [timeout]` as the canonical
wait primitive for every integration test, chainsaw scenario, and operator
probe that must block until a Crossplane claim reaches `Ready=True`. The script
polls `kubectl get <kind>/<name>` on a configurable interval, exits 0 on
`Ready=True`, and on timeout auto-dumps the last-seen `.status.conditions`,
recent composition events, and cluster events in the `±5 min` window — so
each failed wait is self-describing without a subsequent `kubectl describe`
round-trip (per brainstorm cross-comment A1→A2-013 and the larger-list
§S7 quote-on-timeout extension). The script is the single caller-facing
interface; its shared internals live in a new `scripts/_lib/k8s-helpers.sh`
module (the first use of that shared library, which later specs S2, A2, A3,
and A5 also consume). It pairs with A3-042 (canonical `wait_for` library in
`tests/integration/lib/test-lib.sh`) as the same helper expressed through
two interfaces — one as a sourced bash function for tests, one as a
standalone executable for scripts and chainsaw `script:` blocks.

---

## 2. Retro pain killed

- **PR #59 silent-PASS class** (`retrospective/2026-05-24-62.md` Phase 5,
  lines 83–88): all 11 `tests/integration/NN_*.sh` scripts used
  `set -uo pipefail` without `-e`. The existing `wait_for` returning 1 on
  timeout did NOT abort the calling script; the next `ok "..."` line ran
  and the test reported PASS while four assertions had just failed. A
  standalone script that `exit 1`s on timeout cannot be silenced by a
  missing `-e` in the caller.

- **UID-shadowing collision** (same retro, lines 86–88): `UID` is a bash
  readonly builtin (= `1001` on Actions runners). `UID=$(kubectl get ...)`
  failed silently under `set -u`; every claim wrote to the same ASM key
  `k8-platform/1001`. A canonical helper that uses `CLAIM_UID` (or passes
  the name through) ensures the bug class cannot recur through a name
  collision with a builtin — defending the same contract as the
  `test_shell_readonly_var_assignment.sh` lint added in PR #59.

- **Blind timeout loops** (`retrospective/2026-05-24-62.md` Phase 4,
  line 78): chainsaw failed five times with `Ready=False reason=Waiting`
  and each iteration was blind. PRs #52/#53 required a `dump_diagnostics`
  post-mortem function. With this spec, every wait loop auto-dumps on
  timeout — the evidence is present on the first failure without adding
  per-test dump logic.

- **Copy-paste wait loops** (brainstorm A6→A1-007): eleven integration
  scripts each contain a bespoke `wait_for "Claim <X> becomes Ready" <N>
  <interval> -- bash -c "kubectl get ... | grep -q True"` block. Any
  change to wait semantics (e.g. adding the timeout dump) requires eleven
  edits. This spec collapses them to one call.

- **PR #67 silent no-op class** (`ai/brainstorming/specs/larger-list-
  preferences.md` S10): wait loops that silently succeed when the claim
  never actually reached Ready, because the `jsonpath` expression resolved
  to empty string and `grep -q True` matched nothing (empty string does
  not fail grep — it produces no output, grep returns 1 on no match, but
  the outer condition was checking for `True` not `non-empty`). The helper
  uses `[[ "$status" == "True" ]]` for exact equality, not a pipeline.

---

## 3. Out of scope

- **ArgoCD application waits** — those belong to a separate
  `scripts/wait-for-argocd.sh` (brainstorm A4-039), which also consumes
  `scripts/_lib/k8s-helpers.sh`. This spec does not implement it.
- **MR-level Synced+Ready waits** — `scripts/wait-for-claim.sh` waits on
  the claim's own `Ready` condition. Walking down to check MR conditions
  is the domain of SPEC-A1's chain-walk extension to
  `crossplane-claim-verify`.
- **Chainsaw `until` replacement for non-claim resources** — the helper
  is Crossplane-claim-specific. General `kubectl wait` on Deployments /
  Pods / etc. is out of scope.
- **Auto-fix on timeout** — the script diagnoses; it does not patch,
  delete, or re-apply anything. Diagnosis only.
- **CloudTrail / IRSA inspection on timeout** — that is SPEC-A1's chain
  block. This spec dumps cluster-side conditions and events only.

**Considered and rejected:**

- *Inline the timeout dump into `test-lib.sh`'s existing `wait_for`.*
  Rejected because `wait_for` takes a generic `<command>` and cannot know
  the claim kind/name needed for `kubectl describe`. A claim-specific
  script is the right interface boundary.
- *Use `kubectl wait --for=condition=Ready --timeout=Ns` directly.*
  Rejected because `kubectl wait` on timeout emits only
  `error: timed out waiting for the condition on <resource>/<name>` with
  no dump. The verbose output added here requires the polling loop.
- *Single script handling both `wait-for-claim` and `wait-for-argocd`.*
  Rejected to keep each script under ~100 lines and avoid the "blob
  helper" pattern that makes future changes risky.

---

## 4. Files to change / create

**Create:**

| Path | What |
|---|---|
| `/home/user/k8-platform/scripts/wait-for-claim.sh` | New canonical wait-primitive executable |
| `/home/user/k8-platform/scripts/_lib/k8s-helpers.sh` | New shared module (first use); contains `k8s_get_condition`, `k8s_dump_claim_timeout` |
| `/home/user/k8-platform/tests/unit/test_wait_for_claim.sh` | Unit tests for the script (§6) |
| `/home/user/k8-platform/tests/unit/fixtures/wait-for-claim/claim-ready.json` | Fixture: claim with `Ready=True` |
| `/home/user/k8-platform/tests/unit/fixtures/wait-for-claim/claim-not-ready.json` | Fixture: claim with `Ready=False reason=Waiting` |
| `/home/user/k8-platform/tests/unit/fixtures/wait-for-claim/claim-no-conditions.json` | Fixture: claim with empty `.status.conditions` |

**Modify:**

| Path | What changes |
|---|---|
| `/home/user/k8-platform/tests/integration/06_crossplane_xrd_claim.sh` | Replace `wait_for "Claim TestBucket/$BUCKET becomes Ready" ...` block with `wait-for-claim.sh TestBucket $BUCKET $TEST_NS 240` |
| `/home/user/k8-platform/tests/integration/11_platform_secret_e2e.sh` | Replace `wait_for "PlatformSecret/$CLAIM Ready=True" ...` block with `wait-for-claim.sh PlatformSecret $CLAIM $TEST_NS 180` |
| `/home/user/k8-platform/tests/integration/05_crossplane_managed_resource.sh` | Replace `wait_for "Bucket $BUCKET reaches Synced+Ready" ...` with `wait-for-claim.sh Bucket $BUCKET "" 180` (cluster-scoped MR, ns omitted) |
| `/home/user/k8-platform/AGENTS.md` | §6.1: note `scripts/wait-for-claim.sh` as canonical; §11: add `scripts/_lib/` to file layout |
| `/home/user/k8-platform/ai/testing-guidelines.md` | One paragraph in the integration-test section naming `wait-for-claim.sh` as the required wait interface for Crossplane claims |

---

## 5. Implementation notes

### 5.1 `scripts/_lib/k8s-helpers.sh` — shared module

First file in the new `scripts/_lib/` directory. Later specs S2, A2, A3, A5
also source it. Scope: read-only kubectl helpers shared across scripts.

Two functions this spec introduces:

**`k8s_get_condition <kind> <name> <ns> <type>`** — emits the `.status.conditions`
value (`True`/`False`/`Unknown`/empty) for the named condition type.
Uses `kubectl get <kind>/<name> [-n <ns>] -o jsonpath='{.status.conditions[?(@.type=="<type>")].status}'`.
`ns=""` omits `-n`, enabling cluster-scoped resources.

**`k8s_dump_claim_timeout <kind> <name> <ns>`** — called on timeout. Emits three
sections, each truncated with `head -c 800` for a ≤3 KB combined budget:

```
=== TIMEOUT DUMP: <kind>/<name> ===
-- conditions:
  <.status.conditions[*] formatted as "type=status reason=X msg=Y">
-- composition events (XR):
  <kubectl get events --field-selector involvedObject.name=<xr-name>>
  (or "(XR ref not yet set)" if spec.resourceRef is absent)
-- recent cluster events (<ns>, ±5 min):
  <kubectl get events -n <ns> --sort-by=.lastTimestamp, last 20 lines>
=== END TIMEOUT DUMP ===
```

The `±5 min` window references brainstorm cross-comment A1→A2-013 ("cluster
events ±5 min") and the §S7 larger-list quote-on-timeout extension.
Output budget (≤3 KB) is smaller than SPEC-A1's chain-block 5 KB — this
is a fast-path dump, not a full IRSA/cloud diagnostic.

### 5.2 `scripts/wait-for-claim.sh`

Interface: `wait-for-claim.sh <kind> <name> [ns] [timeout-seconds]`

- Sources `scripts/_lib/k8s-helpers.sh`.
- Polls `k8s_get_condition <kind> <name> <ns> Ready` every `POLL_INTERVAL`
  seconds (default 5). Exits 0 when value is exactly `"True"` — string
  equality, not a grep pipeline. This prevents the empty-string false-
  positive from the PR #67 no-op class.
- On timeout: prints `wait-for-claim: TIMEOUT after Ns — Ready=<status>`,
  calls `k8s_dump_claim_timeout`, then `exit 1`. The exit is unconditional
  — it propagates to any caller regardless of whether the caller has `-e`.
  This is the direct fix for the PR #59 silent-PASS class.
- `set -uo pipefail` without `-e`; the script manages its own exit path.
- `NS=""` (empty or omitted) → cluster-scoped resource, no `-n` flag.
- `TIMEOUT` default 300 s; `POLL_INTERVAL` overridable via environment.
- Does NOT use `$UID` anywhere — guards the PR #59 readonly-variable class.

### 5.3 Migration pattern for `tests/integration/*.sh`

Each claim-specific `wait_for "Claim ... becomes Ready" N interval -- bash -c
"kubectl get ... | grep -q True"` block is replaced with:

```bash
"$(cd "$(dirname "$0")/../.." && pwd)/scripts/wait-for-claim.sh" PlatformSecret "$CLAIM" "$TEST_NS" 180
```

Tests 05, 06, and 11 are the primary migration targets (§4 table). Tests
01, 02, 03, 04, 07, 08, 09, 10 use `wait_for` for non-claim resources
(ArgoCD apps, Route53 records, pods, ExternalSecrets) and are NOT in scope
for this migration — those use the generic `wait_for` from `test-lib.sh`
appropriately.

### 5.4 Pair with A3-042 (`wait_for` library)

A3-042 refactors `test-lib.sh`'s `wait_for` to exit non-zero AND print
last-seen state; S7 adds a claim-specific executable wrapper with the richer
±5 min event dump. Neither replaces the other: `wait_for` (test-lib) handles
ALL wait shapes in integration tests; `wait-for-claim.sh` is the entry point
for claim waits from chainsaw `script:` blocks and runbooks where `test-lib.sh`
is not sourced. If A3-042 lands first, `wait-for-claim.sh`'s polling loop
should delegate to it; if S7 lands first, A3-042 should align with
`_lib/k8s-helpers.sh`'s dump to avoid divergence.

---

## 6. Tests required

Per AGENTS.md §6.1 and §6.4.

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_wait_for_claim.sh` | Given fixture `claim-ready.json` mocked as `kubectl` output, script exits 0 within one poll cycle |
| Unit | same | Given `claim-not-ready.json` with `TIMEOUT=1 POLL_INTERVAL=1`, script exits 1 and stdout contains `=== TIMEOUT DUMP:` |
| Unit | same | Given `claim-not-ready.json`, stdout contains `conditions:` and `recent cluster events` sections |
| Unit | same | Given `claim-no-conditions.json`, timeout dump prints `(conditions unavailable)` or zero-length conditions block — does NOT hang |
| Unit | same | Running `bash -n scripts/wait-for-claim.sh` and `bash -n scripts/_lib/k8s-helpers.sh` both pass (syntax check) |
| Unit | same | `grep -c 'UID' scripts/wait-for-claim.sh scripts/_lib/k8s-helpers.sh` returns 0 — neither file references `$UID` (guards PR #59 readonly-variable class) |
| Integration | `tests/integration/06_crossplane_xrd_claim.sh` (modified) | Existing test passes with the new `wait-for-claim.sh` call replacing the `wait_for` block; no change to observable assertions |
| Integration | `tests/integration/11_platform_secret_e2e.sh` (modified) | Same — PlatformSecret Ready=True reached and test passes end-to-end |

Adversarial subagent review (§6.4) is required before authoring the unit
tests. Brief must include: contracts (exact-equality `Ready=True` not grep,
`exit 1` on timeout, dump ≤3 KB, `CLAIM_UID` / `UID` guard, empty-conditions
path, cluster-scoped MR path, `POLL_INTERVAL` override), bug history
(PR #59 silent-PASS + UID shadowing, PR #52/#53 blind timeout loops), and
explicit non-goals (no IRSA/CloudTrail inspection, no ArgoCD waits,
no auto-fix).

---

## 7. Testing suggestions

### Unit

- `tests/unit/test_wait_for_claim.sh` case: invoke with a mock `kubectl`
  that returns `Ready=True` on the second call — assert script exits 0
  and reports elapsed time. Defends the "waits at least one poll" contract.
- Same file: invoke with TIMEOUT=0 (or very short) and assert exit code is
  1 AND output contains both `TIMEOUT DUMP` header and `END TIMEOUT DUMP`
  footer — proves the dump block completes even with minimal clock.
- `tests/unit/test_k8s_helpers_lib.sh` (future, when A3-042 lands): source
  `k8s-helpers.sh` in a bats/bash test and call `k8s_dump_claim_timeout`
  with a mock `kubectl`; assert output length is ≤ 3072 bytes. Guards the
  output-budget promise independently of the script wrapper.
- Shellcheck lint: `shellcheck -x scripts/wait-for-claim.sh` and
  `shellcheck -x scripts/_lib/k8s-helpers.sh` both exit 0 with no
  warnings. Add to `tests/unit/run.sh` as a fast gate.

### Integration

- `tests/integration/12_wait_for_claim_timeout_dump.sh` (new, skip-by-default):
  applies a deliberately broken claim (invalid `compositionRef`) and invokes
  `wait-for-claim.sh` with `TIMEOUT=30`. Asserts exit code 1 AND that stdout
  contains `=== TIMEOUT DUMP:` and at least one `conditions:` line. Runnable
  against a live cluster to prove the dump fires in a real environment.
- Modify `tests/integration/run.sh` to export `VERBOSE=1` for the
  `wait-for-claim.sh` calls when `VERBOSE` is set — confirms per-poll
  progress lines are forwarded through the wrapper.

### E2E

Not directly applicable as a standalone chainsaw scenario — `wait-for-claim.sh`
is a helper consumed BY chainsaw steps, not a scenario subject itself. The
correct E2E coverage is the migration of existing chainsaw scenarios to use
the script in their `try.script` blocks; those scenarios already have their
own `chainsaw-test.yaml` coverage under `tests/chainsaw/platform-secret/` and
`tests/chainsaw/platform-cluster/`. When those scenarios' `script:` blocks
are updated to call `wait-for-claim.sh`, their existing chainsaw runs serve
as the E2E gate. No new chainsaw scenario is required for S7 alone.

---

## 8. Documentation updates

- **`AGENTS.md` §6.1** — extend the Integration row of the test-layers table
  with: "(claim waits use `scripts/wait-for-claim.sh`; see SPEC-S7)".
- **`AGENTS.md` §11** — add `scripts/_lib/` to the file-layout block with a
  one-line description: "Shared bash helpers sourced by scripts/ executables".
- **`ai/testing-guidelines.md`** — add a sub-section under integration-test
  guidance: "Claim waits must call `scripts/wait-for-claim.sh` not a bespoke
  `until kubectl get` loop. The script exits 1 on timeout and auto-dumps
  conditions + events, eliminating the need for per-test dump logic."
- **`scripts/README.md`** — add one row to the scripts table:
  `wait-for-claim.sh | Polls claim Ready=True; dumps conditions+events on timeout`.

---

## 9. Workflow / auto-invocation wiring

`scripts/wait-for-claim.sh` is a passive executable — it is invoked
explicitly by integration tests and chainsaw `script:` blocks, not
auto-triggered by a hook or CI event. No new workflow file is needed.

The unit tests (`test_wait_for_claim.sh`) run via `tests/unit/run.sh`,
which `.github/workflows/unit-tests.yml` invokes on every push. Adding
the new test to `tests/unit/run.sh` is the only wiring required.

Chainsaw usage: scenarios that currently contain inline `until kubectl get
... | grep Ready; do sleep` patterns in their `try.script` blocks should
be updated to call `bash /scripts/wait-for-claim.sh ...` — but this is
a follow-on migration, not a blocking requirement for this spec.

---

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_wait_for_claim.sh` (unit
   layer) runs on every push via `unit-tests.yml`. A future integration test
   that duplicates the bespoke `until kubectl get ... | grep True` pattern
   will be flagged by the adversarial-review §6.4 gate, which now has a
   checklist item: "claim waits must use `wait-for-claim.sh`."
2. **Documentation pointer** — `AGENTS.md` §6.1 Integration row and
   `ai/testing-guidelines.md` integration-test section both name the script.
   An agent reading those sections before authoring tests is directed here.
3. **Adversarial-review trigger** — the §6.4 adversarial-review brief
   template gains a standing bullet: "For any test that waits on a Crossplane
   claim, confirm `wait-for-claim.sh` is used and not a bespoke loop."
   This makes the reviewer subagent flag missing usages at the test-drafting
   gate, before the test is committed.

---

## 11. Verification checklist

- [ ] `bash -n scripts/wait-for-claim.sh` exits 0 (syntax clean).
- [ ] `bash -n scripts/_lib/k8s-helpers.sh` exits 0 (syntax clean).
- [ ] `shellcheck -x scripts/wait-for-claim.sh` exits 0 with no warnings.
- [ ] `shellcheck -x scripts/_lib/k8s-helpers.sh` exits 0 with no warnings.
- [ ] `grep 'UID' scripts/wait-for-claim.sh` returns empty (no `$UID` reference).
- [ ] `bash tests/unit/test_wait_for_claim.sh` exits 0 with a PASS line for
  each of the six cases described in §6.
- [ ] `TIMEOUT=2 POLL_INTERVAL=1 bash scripts/wait-for-claim.sh PlatformSecret
  nonexistent-claim "" 2` exits 1 within ~3 seconds and stdout contains
  `=== TIMEOUT DUMP: PlatformSecret/nonexistent-claim ===` (proves the dump
  fires against a live cluster for a missing resource).
- [ ] Running the modified `tests/integration/06_crossplane_xrd_claim.sh`
  against a live cluster with the AWS provider healthy exits 0 and the log
  shows `wait-for-claim: Ready=True after` (not the old `✓ Claim ... (after`
  format from `wait_for`).
- [ ] Running `tests/integration/11_platform_secret_e2e.sh` against a live
  cluster exits 0 end-to-end with the claim-wait replaced.
- [ ] `wc -c` of the TIMEOUT DUMP section output in a real or fixture-driven
  run is ≤ 3072 bytes.
- [ ] `tests/unit/run.sh` exits 0 with the new test included.

---

## 12. Rollout notes

- **Backward compatibility:** the three modified integration tests
  (`05`, `06`, `11`) each replace one `wait_for` call with a `wait-for-claim.sh`
  call. All other `wait_for` calls in those files (for pods, Route53 records,
  ASM secrets, K8s Secrets) are unchanged and continue to use `test-lib.sh`'s
  `wait_for`. No callers outside the three files are affected.
- **Audit-before-merge:** the implementing agent must run
  `tests/unit/run.sh` and the modified integration tests locally before
  opening the PR. The new unit test file must be added to
  `tests/unit/run.sh`'s discovery list (or the discovery pattern must
  already include it via glob).
- **Sandbox constraints:** the script contains only `kubectl` and `date`
  calls — no AWS API, no cloud-specific logic. Pluralsight sandbox
  constraints (region, instance type, EC2 quota, no Bedrock) are not
  relevant.
- **In-flight branches:** if a branch is actively modifying
  `tests/integration/06_crossplane_xrd_claim.sh` or `11_platform_secret_e2e.sh`,
  coordinate so the migration lands in one of the two branches and the other
  rebases. A merge conflict on the `wait_for` lines is expected and trivially
  resolved.
- **Branch sequencing:** S7 is independent of SPEC-A4 (chainsaw catch hook)
  and SPEC-A1 (chain walk). It may land before or after them. If A3-042
  (canonical `wait_for` library) is in flight simultaneously, coordinate on
  whether `wait-for-claim.sh` delegates to `test-lib.sh`'s `wait_for` or
  owns its own polling loop (see §5.4).
- **`scripts/_lib/` directory:** this spec creates it for the first time.
  Later specs (S2, S3, A2) that plan to source `k8s-helpers.sh` will depend
  on this PR having merged. Stack those branches off this one if they are
  authored in the same session.

---

## 13. Estimated effort

**S** (≤1 hour).

Breakdown:
- `scripts/_lib/k8s-helpers.sh` — ~40 lines, ~20 min to author and lint.
- `scripts/wait-for-claim.sh` — ~60 lines, ~20 min to author and lint.
- Three fixture JSON files — ~10 min each, ~30 min total (copy from a
  `kubectl get -o json` output and redact).
- `tests/unit/test_wait_for_claim.sh` — six test cases, ~45 min with the
  adversarial-review pass.
- Migration of three integration tests — five lines of change each, ~15 min.
- `tests/unit/run.sh` addition + doc edits — ~10 min.

Total: ~2.5 hours including the §6.4 adversarial-review subagent and
the §11 checklist smoke run. The rollout-audit cost is low: only three
integration-test files change, and the diff is mechanical (one function
call replaced with another). No chainsaw or Terraform files touched.
