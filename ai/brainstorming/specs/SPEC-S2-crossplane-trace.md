# SPEC-S2 — `scripts/crossplane-trace.sh`: claim-to-atProvider chain walker

Brainstorm ID: A1-019. Tier S item S2 from
`/home/user/k8-platform/ai/brainstorming/specs/larger-list-preferences.md`.

---

## 1. Summary

Add `/home/user/k8-platform/scripts/crossplane-trace.sh` — a single bash
script that walks claim → XR → resourceRefs → managed resources → atProvider,
printing `.status.conditions` at every layer. The script accepts `--watch`
(re-print the full chain every 10 s until `Ready=True` or timeout) and
`--json` (emit one JSON snapshot suitable for diffing across runs). Output
fits in one screenful for a four-layer chain; worst-case stays under 5 KB.
Ranked "the single highest-leverage tool in the entire brainstorm" in
`larger-list-preferences.md` S2 because it collapses the recurring
"where in the claim → XR → MR → provider chain is the break?" question into
a 5-second local command, replacing 3-minute workflow dispatches and 166 KB
log subagent delegation. No cluster-side changes, no new CRDs — read-only
kubectl + jq + aws.

---

## 2. Retro pain killed

- **PRs #66, #67, #68 — IRSA SA-name cascade** (`retrospective/2026-05-25-70.md`
  Phase 2): root question at each of three dispatches was "where in the chain
  is the break?" One `crossplane-trace.sh` run would have surfaced the MR
  `AccessDenied` condition and the provider pod SA mismatch in under 5 s with
  no log download or subagent delegation.

- **PR #64 — phase-2-diagnose truncation** (`retrospective/2026-05-25-70.md`
  Phase 1): `phase-2-diagnose.yml` truncated the XR at `head -120`, hiding
  `.status.conditions`. A dedicated trace script eliminates the need for
  ad-hoc diagnostic workflow enhancements each time a field is hidden.

- **PR #67 silent no-op** (`retrospective/2026-05-25-70.md` Phase 2): after
  `Apply complete! Resources: 0 added`, a second subagent dispatch was needed
  to confirm conditions hadn't changed. A `--watch` loop would have confirmed
  within 10 s that the chain was unchanged.

- **PRs #52/#53/#56 — five chainsaw "Ready=Waiting" failures**
  (`retrospective/2026-05-24-62.md` Phase 4): claims stuck `Ready=False
  reason=Waiting` with no visibility into XR or provider state. PR #56
  added a bespoke `dump_diagnostics` function as a workaround. The trace
  script as a chainsaw `catch:` hook (cross-comment A2→A1-005) replaces
  that bespoke function permanently.

- **`retrospective/2026-05-24-62.md` Phase 4 — XR zero conditions**: empty
  `.status.conditions` on the XR after PR #53's composition landed; five
  chainsaw iterations before the composition layer was implicated. A trace run
  would have emitted `XR.conditions=<empty>` in the first iteration.

---

## 3. Out of scope

- **No cluster mutations.** Script is read-only: `kubectl get`, `aws iam
  get-role`, `aws sts get-caller-identity` only.
- **No auto-fix.** Diagnosis only; the `crossplane-claim-verify` skill's Phase
  6 taxonomy owns remediation.
- **No event-bus integration** (A5→A1-006). That cross-comment is a follow-on;
  the script stands alone without a bus.
- **No composition-pipeline trace.** `crossplane render` dry-run (A1-040) is a
  separate tool targeting authoring-time, not live-cluster state.
- **Does not retire `phase-2-diagnose.yml` in this PR.** Cross-comment
  A6→A1-006 notes the workflow could be deleted once the script exists; that
  deletion is Tier D chore D2 and belongs in its own PR.
- **No Mermaid output** (cross-comment to A4-005). A diagram generator can
  consume `--json` output in a follow-on.

### Considered and rejected

- **`crossplane beta trace` as the backend.** The CLI's `beta trace` output
  format has changed across minor versions; wrapping it makes the script fragile.
  Plain `kubectl get -o json | jq` is more durable and testable with fixtures.
- **Python implementation.** Most scripts in `/home/user/k8-platform/scripts/`
  are bash; consistency lowers the barrier for an agent to inline-edit. Rejected.
- **Watch via `watch(1)`.** `watch` clears the terminal and is not pipe-friendly.
  A `while` loop with a timestamp header is grep-able in CI logs. Rejected.

---

## 4. Files to change / create

| Path | What changes |
|---|---|
| `/home/user/k8-platform/scripts/crossplane-trace.sh` | **Create.** ~180-line bash implementation; see §5. |
| `/home/user/k8-platform/tests/unit/test_crossplane_trace.sh` | **Create.** Unit tests against JSON fixtures; see §6. |
| `/home/user/k8-platform/tests/unit/fixtures/crossplane-trace/` | **Create.** Five canned `kubectl get -o json` fixture files (claim-ok, claim-failing, xr-empty-conditions, mr-access-denied, provider-sa-mismatch). |
| `/home/user/k8-platform/tests/integration/12_crossplane_trace_smoke.sh` | **Create.** Live-cluster smoke; skipped unless `CROSSPLANE_TRACE_LIVE=1`. |
| `/home/user/k8-platform/AGENTS.md` §7 | **Modify.** One sentence: "When a claim is stuck or slow, run `scripts/crossplane-trace.sh <kind>/<name> [-n <ns>]` for a condition walk; use `--watch` while waiting for reconciliation." |
| `/home/user/k8-platform/ai/handoff.md` | **Modify.** One bullet in scripts inventory with synopsis and flag summary. |

---

## 5. Implementation notes

### 5.1 Invocation surface

```
scripts/crossplane-trace.sh <kind>/<name> [-n <ns>] [--watch] [--json] [--timeout <s>]
```

- `<kind>/<name>` — case-insensitive kind (lowercased internally).
- `-n` — defaults to `default`.
- `--watch` — re-print every `${TRACE_INTERVAL:-10}` seconds; exit 0 on
  `Ready=True`, exit 2 on timeout (default 600 s).
- `--json` — emit one JSON object to stdout (see §5.4), then exit immediately.
- `--timeout` — only meaningful with `--watch`.

### 5.2 Pre-flight (always first)

Per AGENTS.md §8.1:

```bash
aws sts get-caller-identity --query 'Account' --output text > /dev/null 2>&1 \
  || { echo "ERROR: aws sts get-caller-identity failed" >&2; exit 1; }
REGION=${AWS_REGION:-us-east-1}
[[ "$REGION" != "us-east-1" && "$REGION" != "us-west-2" ]] \
  && { echo "WARN: region=$REGION — AWS sections skipped"; SKIP_AWS=1; }
```

kubectl connectivity is implicitly checked: the first `kubectl get` error
causes the script to print the error and exit 1.

### 5.3 Layer traversal (fail-soft per layer)

Each layer is a function. On error it prints `LAYER: <reason>` and returns;
the script continues to the next layer. Mirrors the fail-soft contract in
SPEC-A1 §5.

**Layer 0 — CLAIM:** `kubectl get <kind>/<name> -n $ns -o json`. Extract
`spec.compositionRef.name`, `spec.resourceRef.{kind,name}`, and
`status.conditions[]` (messages truncated to 160 chars).

**Layer 1 — XR:** cluster-scoped `kubectl get` on the resourceRef. Extract
`status.conditions[]` (emit `<empty — Composition pipeline may not have
reconciled yet>` if none) and `spec.resourceRefs[]` (cap at 12, `(+N more)`
if truncated).

**Layer 2 — MANAGED RESOURCES:** `kubectl get <kind>/<name> -o json` per
resourceRef. Per MR: `[OK]` or `[FAIL]`, `Synced=`, `Ready=`, `reason=`,
first `message` truncated to 200 chars. Cap detail output at 5 `[FAIL]` MRs;
emit `(+N more failing MRs)` for the rest.

**Layer 3 — PROVIDER + IRSA:** Derive provider package from the first failing
MR's `apiVersion` group (same derivation as SPEC-A1 §5 §4). Print
`provider.pkg/<name>` Healthy/Installed conditions, provider pod name/phase/
restarts, and pod `spec.serviceAccountName` (the load-bearing value from PRs
#66/#68). Unless `SKIP_AWS`: extract IRSA role ARN from the SA annotation,
call `aws iam get-role`, extract the OIDC trust subject, print `MATCH` or
`MISMATCH` on its own line.

**Layer 4 — atProvider snapshot:** for each `[FAIL]` MR, extract
`.status.atProvider` as compacted JSON, capped at 400 chars per MR.

### 5.4 Output formats

**Human-readable (default):**

```
=== CROSSPLANE TRACE: <kind>/<name> -n <ns>  [HH:MM:SSZ] ===
CLAIM    <kind>/<name>  compRef=<composition>
  Synced=<S> reason=<R> | Ready=<S> reason=<R>  message: <...160 chars...>
  XR-ptr: <XR-kind>/<XR-name>
XR       <XR-kind>/<XR-name>
  conditions: <...> | <empty — Composition pipeline may not have reconciled yet>
  resourceRefs (<N> total):
    [OK]   <kind>/<name>  Synced=True Ready=True
    [FAIL] <kind>/<name>  Synced=True Ready=False  reason=<R>
           message: <...200 chars...>
PROVIDER provider.pkg/<name>  Healthy=<S> Installed=<S>
  pod:    <pod-name>  phase=<P>  restarts=<N>
  pod-SA: <sa-name>
IRSA     role: <role-arn>
  trust-subject: <oidc>:sub = system:serviceaccount:<ns>:<sa>
  MATCH | MISMATCH
ATPROVIDER (failing MRs)
  <kind>/<name>: <compacted JSON, ≤400 chars>
=== END TRACE ===
```

`[FAIL]` and `MATCH`/`MISMATCH` are greppable from chainsaw logs without
JSON parsing.

**JSON mode (`--json`):** one object containing `timestamp`, `claim`,
`xr`, `managedResources`, `provider`, `irsa` top-level keys. This is the
input format for the A3→A1-003 snapshot-diff pattern:

```bash
# Save two snapshots and diff
scripts/crossplane-trace.sh platformsecret/s --json > /tmp/t1.json
# ... wait ...
scripts/crossplane-trace.sh platformsecret/s --json > /tmp/t2.json
diff <(jq -S . /tmp/t1.json) <(jq -S . /tmp/t2.json)
```

### 5.5 Watch loop

```bash
INTERVAL=${TRACE_INTERVAL:-10}; ELAPSED=0
while true; do
  run_trace
  claim_is_ready && { echo "=== CLAIM READY — watch exiting 0 ==="; exit 0; }
  [[ $ELAPSED -ge $TIMEOUT ]] \
    && { echo "=== TIMEOUT (${TIMEOUT}s) — claim not Ready ==="; exit 2; }
  sleep "$INTERVAL"; ELAPSED=$(( ELAPSED + INTERVAL ))
done
```

### 5.6 Output budget and shared helpers

Typical trace: ~19 lines / ~800 bytes. Worst case (12 resourceRefs, 5 failing
MRs with max-length messages): ~4 KB — within the ~5 KB budget established
by SPEC-A1.

The script sources `/home/user/k8-platform/scripts/_lib/k8s-helpers.sh` if
present (per the shared-infra table in `larger-list-preferences.md`; S7
introduces this helper). If absent, inline fallbacks are used with warning
`WARN: _lib/k8s-helpers.sh not found — using inline fallbacks`, keeping
the script usable before S7 lands.

---

## 6. Tests required (per AGENTS.md §6.1)

| Layer | File | Assertion |
|---|---|---|
| Unit | `/home/user/k8-platform/tests/unit/test_crossplane_trace.sh` | Feed five fixtures through the rendering functions; assert (a) output starts with `=== CROSSPLANE TRACE:` and ends `=== END TRACE ===`, (b) ≤ 5120 bytes, (c) SA-mismatch fixture contains exactly one `MISMATCH`, (d) xr-empty-conditions contains `<empty`, (e) access-denied fixture contains `[FAIL]`. |
| Unit | same file | Assert `--json` emits valid JSON (`jq .` exits 0) with all five required top-level keys. |
| Unit | same file | Assert watch exit codes: `Ready=True` fixture → exit 0; not-ready + `--timeout 0` → exit 2. |
| Integration | `/home/user/k8-platform/tests/integration/12_crossplane_trace_smoke.sh` | Skipped unless `CROSSPLANE_TRACE_LIVE=1`. Asserts exit 0 or 2 (not 1), output contains `=== END TRACE ===`, `--json` parses. |

Per AGENTS.md §6.4, dispatch one adversarial subagent before authoring these
tests with: the four contracts above, failure history from PRs #66/#67/#68
and chainsaw PRs #52/#53, and the explicit non-goals (no AWS-write tests,
no live-cluster assertions in the unit layer, no provider-internals tests).

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast (< 10 s). Names follow `tests/unit/test_<name>.sh`.

1. **sa-mismatch fixture**: assert `MISMATCH` appears exactly once and
   `pod-SA:` appears exactly once. Guards the PR #66/#68 signal.
2. **xr-empty-conditions fixture**: assert output contains `<empty` and
   does NOT contain `[FAIL]` (XR-layer empty is distinct from MR-layer fail).
3. **output-budget gate**: assert the 12-resourceRefs + 5-failing-MRs fixture
   produces ≤ 5120 bytes. Prevents format bloat.
4. **json-roundtrip**: assert `--json` output is valid JSON with `irsa.match`
   false for SA-mismatch fixture and true for SA-ok fixture.
5. **watch-timeout-exit-code**: `--timeout 0` with a not-ready fixture exits 2.
   Guards the watch-loop exit semantics for automation consumers.

### Integration

Gated on `CROSSPLANE_TRACE_LIVE=1`. Names follow `tests/integration/NN_<name>.sh`.

1. **happy-path**: run against a known-ready claim; assert exit 0 and `MATCH`
   in output (IRSA healthy).
2. **watch-exits-on-ready**: apply a test claim, run `--watch --timeout 900`;
   assert the script exits 0 (not 2) when the claim converges.
3. **json-structurally-valid**: `--json | jq '.managedResources | length'`
   returns ≥ 1 (real MR data populated).

These intentionally overlap the unit layer per AGENTS.md §6.1.

### E2E

Chainsaw scenarios under `tests/chainsaw/<scenario>/chainsaw-test.yaml`. These
are follow-on work — they belong in the SPEC-A4 catch-block update PR, not in
this spec's PR.

1. **`crossplane-trace-error-hook/`**: broken Composition `catch:` block runs
   `crossplane-trace.sh`; assert output contains `=== END TRACE ===` and
   at least one `[FAIL]`. Validates A2→A1-005 integration.
2. **`crossplane-trace-provider-unhealthy/`**: Provider with
   `packagePullPolicy: Never`; assert trace emits `Installed=False`.
3. **`crossplane-trace-watch-converge/`**: valid PlatformSecret claim +
   `--watch --timeout 300`; assert exits 0 within step timeout.

E2E is applicable (not skippable) because the watch convergence behavior
cannot be validated against static fixtures.

---

## 8. Documentation updates

- **`/home/user/k8-platform/AGENTS.md` §7** — one sentence in the companion
  skills block directing agents to `scripts/crossplane-trace.sh` when a claim
  is stuck or slow.
- **`/home/user/k8-platform/ai/handoff.md`** — one bullet in scripts
  inventory: synopsis + `--watch`/`--json` flags.
- **`/home/user/k8-platform/ai/testing-guidelines.md`** — one sentence in
  chainsaw-authoring guidance: "For any claim-level assertion failure, invoke
  `scripts/crossplane-trace.sh` from the `catch:` block."
- **`/home/user/k8-platform/scripts/README.md`** — one-line entry (if the
  file exists).

---

## 9. Workflow / auto-invocation wiring

The script is a **runbook primitive — manually invoked**. CI already has the
`crossplane-claim-verify` skill as its automated check; this script is the
human-speed companion.

Three planned auto-invocation paths, each owned by a different spec:

1. **Chainsaw `catch:` block** (SPEC-A4 implementation PR): update
   `tests/chainsaw/_lib/catch-block.yaml` to call `crossplane-trace.sh` in
   the `script:` step.
2. **`crossplane-claim-verify` skill Phase 6.0** (SPEC-A1 implementation PR):
   delegate to `crossplane-trace.sh --json` as the canonical chain-block
   source.
3. **`AGENTS.md` §7 trigger** (this spec): any agent reading §7 before
   touching a stuck claim will be directed to the script.

No cron, no pre-commit hook, no CI trigger added in this PR.

---

## 10. Discoverability

1. **Mechanical enforcement**: once SPEC-A4's `catch-block.yaml` invokes this
   script, a chainsaw failure log without `=== END TRACE ===` indicates the
   script is missing or broken — a greppable CI signal.
2. **Documentation pointer**: `AGENTS.md` §7 (after this spec's edit) is the
   canonical entry point for any agent reading the "testing loops — companion
   skills" section.
3. **Adversarial-review trigger**: after the `ai/testing-guidelines.md` edit,
   an adversarial reviewer checking a new chainsaw scenario for missing
   `catch:` coverage (per AGENTS.md §6.4) will see the reference and flag
   its absence from the catch block.

---

## 11. Verification checklist

- [ ] `bash /home/user/k8-platform/tests/unit/test_crossplane_trace.sh`
      exits 0 with a `PASS` line for each of the five fixture cases.
- [ ] `bash /home/user/k8-platform/scripts/crossplane-trace.sh --help`
      prints usage containing `--watch` and `--json`.
- [ ] `scripts/crossplane-trace.sh platformsecret/nonexistent -n default`
      exits non-zero AND prints `CLAIM: lookup-failed` (fail-soft; no stack trace).
- [ ] `scripts/crossplane-trace.sh platformsecret/nonexistent --json`
      exits non-zero AND `jq . < <(…)` exits 0 (valid JSON even on failure).
- [ ] `scripts/crossplane-trace.sh platformsecret/nonexistent --timeout 0 --watch`
      exits 2 within 1 second.
- [ ] `wc -c` of the 12-resourceRefs + 5-failing-MRs fixture output is ≤ 5120.
- [ ] `grep -c MISMATCH` of the SA-mismatch fixture output returns exactly 1.
- [ ] `bash /home/user/k8-platform/tests/unit/run.sh` exits 0 (new test included).
- [ ] `grep -n crossplane-trace /home/user/k8-platform/AGENTS.md` returns ≥ 1
      match in §7.
- [ ] `shellcheck /home/user/k8-platform/scripts/crossplane-trace.sh` exits 0
      (suppressed warnings annotated with `# shellcheck disable=SCnnnn`).

---

## 12. Rollout notes

- **Backward compatibility**: net-new file; nothing existing depends on it.
- **Audit before merge**: unit test file and five fixtures must ship in the
  same PR as the script. §11 checklist is the gate.
- **Sandbox constraints**: all calls are read-only. AWS region guard is in
  the pre-flight. No EC2, no EKS mutations. No Bedrock/Marketplace. Fully
  orthogonal to sandbox limits.
- **Coordination with SPEC-A1**: both specs share claim→XR→MR→IRSA traversal
  logic. Land this script first (primitive), then update SPEC-A1's
  `reference/chain-walk.md` to reference `crossplane-trace.sh --json` as the
  canonical source. Do not implement both in the same PR — stacked PRs per
  AGENTS.md §3.
- **Coordination with SPEC-A4**: the `catch-block.yaml` update to invoke this
  script belongs in the SPEC-A4 implementation PR, not here. State the
  dependency in that PR's description.
- **Branch**: `feat/crossplane-trace-script`. Standalone; no blocking
  dependencies on other open specs.

---

## 13. Estimated effort

**M** (approximately 2.5 hours).

- Script (~75 min): ~180 lines; IRSA block adapted from SPEC-A1 §5 (~20 lines).
- Fixtures (~30 min): five trimmed `kubectl get -o json` JSON files.
- Unit tests (~20 min): five cases × ~10 lines each.
- Rollout audit + doc edits (~15 min): script is net-new, no prior audit.
- Review cycle (~20 min): self-contained and straightforwardly testable.

Effort dominated by bash/jq rendering pipelines. Chainsaw e2e scenarios (§7
E2E) are deferred to the SPEC-A4 PR and excluded from this estimate.
