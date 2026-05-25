# SPEC-S5 — scripts/phase-status.sh: live phase-state oracle

## 1. Summary

Add `scripts/phase-status.sh`, a read-only diagnostic tool that walks phases
0–6 and probes the live AWS + Kubernetes environment to classify each phase as
`not-coded`, `code-only`, `applied`, or `verified`. The script treats the
handoff doc as belief, not ground truth (AGENTS.md §8.1), and derives
state entirely from API calls. It prints a human-readable table by default
and a machine-readable JSON snapshot when invoked with `--json`; the JSON
output is the artifact a drift oracle diffs between runs. Two cross-comments
against brainstorm A1-002 expand the scope: comment A2→A1-002 promotes the
script as a chainsaw `assert:` oracle, and comment A3→A1-001 adds the JSON
snapshot diff capability that turns live probes into a recurring regression
guard. The script depends on `scripts/whereami.sh` (SPEC-S4) for cluster
identity pre-flight. This is part of the S-cluster (scripts/utilities).

## 2. Retro pain killed

- **`retrospective/2026-05-25-70.md` line 65** — the 2026-05-25 session
  scrubbed ~12 hardcoded account IDs from `ai/handoff.md` after the user
  flagged the anti-pattern. The scrub was correct, but it left the Environment
  State table unable to report what was actually live. Phase-status.sh replaces
  that table's "applied / verified" cells with verifiable live-probe output.
- **`ai/handoff.md` Phase states note** — *"Cross-session `applied`/`verified`
  are NOT durable (AGENTS.md §8.1)."* Despite the caveat, the session-start
  procedure in QUICKSTART still asks agents to read and trust that table.
  Without a live probe, a new session on a fresh account always starts from
  ambiguity: "the handoff says applied; is it?" The script resolves this in
  seconds and eliminates the trust-then-verify round-trip.
- **`retrospective/2026-05-24-62.md` line 92** — a `phase-2-diagnose.yml`
  workflow was dispatched to extract state from a 60 KB log to determine what
  was live. A dedicated phase-status tool would have answered the same question
  without a CI dispatch, a subagent extraction step, and ~10 minutes of latency.
- **`retrospective/2026-05-25-70.md` IRSA cascade** — PRs #66–#68 each
  included a verify step that re-examined individual components without a
  unified view of which phases were actually healthy end-to-end. Having a
  per-phase `verified` signal would have made "phase 2 is still broken after
  #66" immediately visible rather than requiring a full re-run of the
  diagnose workflow.
- **`ai/handoff.md` Bug 3 table** — the table records Bug 3 as open, but only
  against phase 2. A future session that fixes Bug 3 must manually update the
  handoff table, risking drift. With phase-status.sh the table becomes
  derivable; the A6→A1-002 cross-comment proposes replacing it entirely.

## 3. Out of scope

- **Auto-remediation.** The script diagnoses; it does not apply Terraform, run
  ArgoCD sync, or patch any resource. Diagnosis only.
- **Phase 3–6 probe depth.** Phases 3–6 do not exist on the current cluster;
  their probes are stubs that emit `not-coded` (no Terraform resource found and
  no CRD found) until those phases are implemented. Stub depth is sufficient
  for the drift-oracle use case.
- **Replacing the handoff doc entirely.** The A6→A1-002 cross-comment suggests
  deleting the Environment State table; that is a separate spec decision.
  This spec only makes the live probe available.
- **Parallel probe execution** (`make -j7 probe-phase-{0..6}`). The A5→A1-002
  cross-comment is a performance optimization; the initial implementation is
  serial. Parallelism is a follow-on if total runtime exceeds ~60 seconds.
- **Writing probe results back to handoff.md.** The script prints; callers
  decide whether to commit. An agent may choose to update the handoff from the
  JSON output, but the script itself does not write files.

### Considered and rejected

- **Re-using `scripts/diag-component.sh` as the phase probe.** That script is
  component-focused (ArgoCD, Crossplane, ESO individually) rather than
  phase-focused. Composing it per phase would couple two orthogonal concerns.
  Kept separate so each script can evolve independently.
- **Embedding probes inside `ai/testing-guidelines.md` as a procedure.** A
  prose procedure can't emit JSON or be called from chainsaw. Script is the
  right artifact.
- **Querying Terraform state directly.** `terraform show -json` would tell us
  what was *last applied* but not whether the live cluster matches. Live API
  probes are the only source that reveals drift; Terraform state is itself a
  form of handoff belief.

## 4. Files to change / create

| Path | What changes |
|---|---|
| `/home/user/k8-platform/scripts/phase-status.sh` | **Create.** Main script; ~180 lines. |
| `/home/user/k8-platform/tests/unit/test_phase_status_format.sh` | **Create.** Unit test against mocked probe functions. |
| `/home/user/k8-platform/tests/unit/fixtures/phase-status/` | **Create.** Directory with mock JSON responses per phase. |
| `/home/user/k8-platform/tests/integration/13_phase_status_smoke.sh` | **Create.** Integration smoke against a live cluster. |
| `/home/user/k8-platform/tests/chainsaw/phase-status-assert/chainsaw-test.yaml` | **Create.** Chainsaw scenario that uses the script as an `assert:` oracle. |
| `/home/user/k8-platform/tests/unit/run.sh` | **Modify.** Add `test_phase_status_format.sh` to the test list. |
| `/home/user/k8-platform/AGENTS.md` | **Modify.** §8.1: add a sentence naming `scripts/phase-status.sh` as the live-probe alternative to trusting the handoff table. |
| `/home/user/k8-platform/ai/handoff.md` | **Modify.** "Phase states" section: add a one-line note that `scripts/phase-status.sh --json` is the authoritative source. |

## 5. Implementation notes

### Pre-flight (always)

The script sources `scripts/whereami.sh` output or calls it inline if not
already in scope. The first two operations are always:

```bash
set -euo pipefail
source "$(dirname "$0")/whereami.sh" --export  # sets CLUSTER, AWS_REGION, etc.
aws sts get-caller-identity >/dev/null          # per AGENTS.md §8.1 ritual
```

If `whereami.sh` cannot confirm a cluster (e.g. no EKS cluster exists yet),
the script continues and emits `not-coded` for all phases rather than aborting.

### State classification rules

Four mutually exclusive states, tested in priority order:

| State | Rule |
|---|---|
| `not-coded` | No Terraform resource file exists for the phase (e.g. `terraform/base/` absent) AND no live cloud resource found |
| `code-only` | Terraform/YAML source files exist for the phase but the canonical live sentinel is absent |
| `applied` | Live sentinel resource exists but the end-to-end functional probe fails or is not attempted |
| `verified` | Live sentinel exists AND end-to-end functional probe passes |

### Per-phase probe table

| Phase | Sentinel check | Functional (verified) probe |
|---|---|---|
| 0 base | `aws route53 list-hosted-zones` returns a zone matching `*.realhandsonlabs.net` | Cognito user pool exists: `aws cognito-idp list-user-pools --max-results 10` returns ≥1 pool |
| 1 management | `aws eks describe-cluster --name k8-platform-mgmt` exits 0 | `kubectl get nodes --no-headers` returns ≥1 Ready node; ArgoCD pod Running in `argocd` namespace |
| 2 xrds | CRD `platformsecrets.platform.k8-platform.io` exists in cluster | `kubectl get crd xplatformsecrets.platform.k8-platform.io` exists AND `kubectl get provider.pkg/provider-family-aws -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}'` returns `True` |
| 3 platform | CRD `platformclusters.platform.k8-platform.io` exists in cluster | A non-management EKS cluster reachable from ArgoCD (stub: `not-coded` until phase 3 lands) |
| 4 observability | Grafana Helm release exists: `kubectl get helmrelease -n monitoring grafana` | Grafana pod Running AND `curl -sf https://grafana.platform.$DOMAIN/api/health` returns 200 (stub until phase 4 lands) |
| 5 auth | Keycloak Helm release or Deployment in cluster | ArgoCD login via OIDC returns 200 (stub until phase 5 lands) |
| 6 workload | ≥1 `PlatformCluster` claim exists in cluster | Claim is `Ready=True` AND the derived EKS cluster exists in AWS |

Each probe function is named `probe_phase_N` and returns one of the four state
strings. Probes are fail-soft: a `kubectl` or `aws` error emits `applied`
(something exists but verification failed) rather than crashing the script.

### Interactive output (default)

```
scripts/phase-status.sh
```

Prints a table to stdout:

```
Phase  State       Sentinel                              Functional probe
-----  ----------  ------------------------------------  -------------------
0      verified    Route53 zone <acct>.realhandsonlabs   Cognito pool found
1      verified    EKS k8-platform-mgmt (ACTIVE)         2 nodes Ready
2      applied     CRD platformsecrets OK                provider Healthy=False (Bug 3)
3      not-coded   no CRD                                —
4      not-coded   no CRD                                —
5      not-coded   no CRD                                —
6      not-coded   no CRD                                —
```

Color-coding via ANSI codes when stdout is a TTY: `verified`=green,
`applied`=yellow, `code-only`=cyan, `not-coded`=grey. Colors suppressed
with `--no-color` or when stdout is piped.

### JSON output mode (`--json`)

```bash
scripts/phase-status.sh --json
```

Emits a single JSON object to stdout:

```json
{
  "generated_at": "2026-05-25T14:32:00Z",
  "cluster": "k8-platform-mgmt",
  "region": "us-east-1",
  "account": "<redacted — derive at runtime>",
  "phases": {
    "0": { "state": "verified",  "sentinel": "Route53 zone found", "probe": "Cognito pool found" },
    "1": { "state": "verified",  "sentinel": "EKS ACTIVE",          "probe": "2 nodes Ready" },
    "2": { "state": "applied",   "sentinel": "CRD present",         "probe": "provider Healthy=False" },
    "3": { "state": "not-coded", "sentinel": null,                  "probe": null },
    "4": { "state": "not-coded", "sentinel": null,                  "probe": null },
    "5": { "state": "not-coded", "sentinel": null,                  "probe": null },
    "6": { "state": "not-coded", "sentinel": null,                  "probe": null }
  }
}
```

The `account` field is populated with the live account ID at runtime (from
`aws sts get-caller-identity`) and never hardcoded. The JSON snapshot is
written to `/tmp/phase-status-<timestamp>.json` after printing, allowing
the drift oracle use case: `diff <(cat /tmp/phase-status-prev.json) <(scripts/phase-status.sh --json)`.

### Chainsaw oracle mode (`--assert-phase N verified`)

```bash
scripts/phase-status.sh --assert-phase 1 verified
```

Exits 0 if the named phase has the named state, non-zero otherwise.
This is the interface the A2→A1-002 cross-comment calls for: a chainsaw
`script:` step can call `--assert-phase 2 verified` to gate a scenario
on phase 2 being actually healthy, not just "the handoff says so".

### Drift oracle

A regression CI step (see §9) captures the JSON snapshot after every
`apply-and-verify` run and diffs it against the prior snapshot committed
to `tests/fixtures/phase-status-baseline.json`. Any state regression
(e.g. `verified` → `applied`) fails CI. This is the A3→A1-001 extension.

### Performance expectations

Serial probe of all 7 phases on a live cluster: ≤30 seconds total. The
slowest step is the EKS cluster describe (~2s) and CRD queries (~1s each).
For `not-coded` phases the probe short-circuits after the first sentinel miss
(<100 ms per phase). Total wall-clock for a fully-applied cluster: ~15s.

## 6. Tests required

Per AGENTS.md §6.1, all applicable layers are required.

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_phase_status_format.sh` | Mock `aws` and `kubectl` using fixture files; assert (a) output contains all 7 phase rows, (b) column headers present, (c) `--json` output is valid JSON with keys `phases.0` through `phases.6`, (d) `--assert-phase 1 verified` exits 0 when fixture sets phase 1 to verified, (e) `--assert-phase 1 applied` exits 1 against same fixture. |
| Unit | `tests/unit/test_phase_status_format.sh` (same file) | Simulate a probe error on phase 2 (`kubectl` returns non-zero); assert script exits 0 (fail-soft), phase 2 state is `applied` not `verified`, and remaining phases still emit rows. |
| Integration | `tests/integration/13_phase_status_smoke.sh` | Against live cluster: run `scripts/phase-status.sh --json`, assert JSON is valid, `phases.0.state` and `phases.1.state` are `verified` or `applied` (not `not-coded`), script exits 0. |
| Chainsaw | `tests/chainsaw/phase-status-assert/chainsaw-test.yaml` | After the standard cluster setup, call `scripts/phase-status.sh --assert-phase 1 verified` as a `script:` step; assert exit 0. Add a negative step that calls `--assert-phase 6 verified` and asserts exit non-zero (phase 6 not deployed in chainsaw kind cluster). |

Per AGENTS.md §6.4, an adversarial subagent review is required before
authoring the fixture corpus. Key contracts to attack: fail-soft behavior
when AWS is unreachable, TTY-detection for color, JSON schema stability,
and the account-ID redaction rule (no live account IDs in JSON snapshots
committed to the repo).

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast (<10s each). Test the shell logic in isolation using function-level mocks.

1. `test_phase_status_format.sh` — nominal: all 7 phases emit a row in table mode.
2. Same file — `--json` produces valid JSON parseable by `jq`.
3. Same file — `--assert-phase` exits 0 on match, 1 on mismatch, 2 on unknown phase.
4. Same file — TTY-detection: when stdout is a pipe, ANSI codes are absent.
5. Same file — `code-only` path: fixture where Terraform source exists but
   sentinel AWS resource absent; assert state is `code-only` not `not-coded`.

### Integration

Against a live cluster (EKS in the sandbox). Slower (seconds–minutes).

1. `tests/integration/13_phase_status_smoke.sh` — run with no flags;
   assert exit 0 and that phase 0 and phase 1 are not `not-coded`.
2. Same file — run with `--json`; pipe to `jq '.phases | keys'`; assert
   returns `["0","1","2","3","4","5","6"]`.
3. Same file — run twice in 5 seconds; assert both outputs have matching
   `phases.0.state` (idempotency check).
4. Same file — run with `--assert-phase 1 verified` when the cluster is
   healthy; assert exit 0.
5. Same file — deliberately target a non-existent cluster via
   `KUBECONFIG=/dev/null`; assert all phases emit `not-coded` and
   script exits 0 (not crashing).

### E2E

Full chainsaw / end-to-end scenarios.

1. `tests/chainsaw/phase-status-assert/chainsaw-test.yaml` — standard
   chainsaw kind cluster with phases 0–2 deployed; assert `--assert-phase 2 verified`
   exits 0 after the PlatformSecret claim becomes Ready=True.
2. Same scenario — inject a broken provider (wrong image tag); assert
   `--assert-phase 2 applied` exits 0 (sentinel exists, probe fails) and
   `--assert-phase 2 verified` exits 1 — proves the oracle distinguishes
   applied-but-broken from verified.
3. A nightly drift-oracle run (see §9): capture JSON snapshot before and after
   a synthetic drift injection (delete a CRD); assert diff output is non-empty
   and contains the regressed phase.

## 8. Documentation updates

- **`AGENTS.md` §8.1** — add one sentence after the "Treat the handoff doc's
  account-level statements as belief" instruction:
  *"Run `scripts/phase-status.sh` (SPEC-S5) to derive the live state instead
  of trusting the handoff table."*
- **`ai/handoff.md` Phase states section** — add a one-line note:
  *"Live probe: `scripts/phase-status.sh --json` (SPEC-S5) is the authoritative
  source; this table is the session-author's last-known state."*
- **`scripts/README.md`** (if it exists) — add a one-line entry for
  `phase-status.sh` in the scripts inventory.
- **`ai/testing-guidelines.md` Phase 1 (orient)** — reference
  `scripts/phase-status.sh` as a quick-orient tool alongside the manual
  `aws eks describe-cluster` command already there.

## 9. Workflow / auto-invocation wiring

- **Session-start hook**: the `SessionStart` hook in `.claude/settings.json`
  (or project hooks) should run `scripts/phase-status.sh` and print the table
  to the terminal as part of orient step. Agents receive the table before any
  task begins, replacing the "read the handoff table" step.
- **`apply-and-verify` post-step**: the `terraform-test.yml` workflow's
  `apply-and-verify` action should call `scripts/phase-status.sh --json` and
  upload the snapshot as a workflow artifact. CI stores it at
  `tests/fixtures/phase-status-baseline.json` on main for the drift oracle.
- **Drift oracle CI job**: a new nightly GitHub Actions workflow
  (`phase-drift-check.yml`) runs `scripts/phase-status.sh --json`, fetches the
  baseline snapshot, diffs, and fails on any state regression (verified →
  applied or applied → not-coded). This implements the A3→A1-001
  cross-comment.
- **Chainsaw `assert:` oracle**: chainsaw scenarios that depend on a minimum
  phase state call `scripts/phase-status.sh --assert-phase N <state>` as a
  `script:` step in their `setup:` block. If the phase isn't at the required
  state, the scenario is skipped rather than failing spuriously.

The script is also callable manually at any time; it has no side effects.

## 10. Discoverability

1. **Mechanical enforcement** — the `apply-and-verify` CI step uploads the
   JSON snapshot. If the snapshot is missing from a PR's artifact list, the
   post-apply job fails. This forces every apply-and-verify run through the
   script without relying on agent memory.
2. **Documentation pointer** — `AGENTS.md` §8.1 (after the edit described in
   §8 above) names the script by path. §8.1 is the section agents are already
   required to read when picking up a session on a new account; the reference
   appears at the exact moment the agent is deciding whether to trust the
   handoff table.
3. **Adversarial-review trigger** — the §6.4 review checklist item "does the
   plan include a mechanism to verify phase state from live APIs rather than
   the handoff?" surfaces this script. Any future test plan for a phase
   bring-up that doesn't cite `scripts/phase-status.sh` or an equivalent live
   probe is a §6.4 finding.

## 11. Verification checklist

- [ ] `bash scripts/phase-status.sh` exits 0 and prints a 7-row table with
  headers `Phase`, `State`, `Sentinel`, `Functional probe`.
- [ ] `bash scripts/phase-status.sh --json | jq '.phases | keys'` returns
  `["0","1","2","3","4","5","6"]`.
- [ ] `bash scripts/phase-status.sh --json | jq '.account'` returns a
  non-null string (the live account ID, not the literal word `null` or a
  hardcoded ID).
- [ ] `bash scripts/phase-status.sh --assert-phase 1 verified` exits 0 on a
  cluster with a healthy phase-1 (≥1 Ready EKS node, ArgoCD Running).
- [ ] `bash scripts/phase-status.sh --assert-phase 6 verified` exits non-zero
  on a cluster where phase 6 has not been deployed.
- [ ] With `KUBECONFIG=/dev/null AWS_DEFAULT_REGION=us-east-1 bash scripts/phase-status.sh`
  all phases emit `not-coded` or `code-only` (no crash, no `verified`).
- [ ] `bash tests/unit/test_phase_status_format.sh` exits 0 with one `PASS`
  line per fixture case.
- [ ] `bash tests/unit/run.sh` includes `test_phase_status_format.sh` in its
  output and exits 0.
- [ ] Chainsaw scenario `tests/chainsaw/phase-status-assert/chainsaw-test.yaml`
  passes in the standard `tests/chainsaw/run.sh` run.
- [ ] `grep 'phase-status.sh' /home/user/k8-platform/AGENTS.md` returns ≥1
  match (doc update landed).

## 12. Rollout notes

- **Backward compatibility.** The script is purely additive. No existing file
  changes behavior; the handoff table remains as-is until a follow-on spec
  (the A6→A1-002 suggestion) proposes removing it.
- **Audit-before-merge.** No existing tests reference `phase-status.sh`, so
  there is no baseline breakage to repair. The unit test and chainsaw scenario
  are new files; they land green on the first commit.
- **Sandbox constraints.** All AWS API calls are read-only (`describe-cluster`,
  `list-hosted-zones`, `list-user-pools`, `sts get-caller-identity`). None
  cost meaningfully in us-east-1 or us-west-2. No Bedrock, no Marketplace.
  Region guard: the script must check `$AWS_REGION` is `us-east-1` or
  `us-west-2` before making any AWS call (mirrors the guard pattern in
  SPEC-A1's chain walk).
- **In-flight branch coordination.** If SPEC-S4 (`whereami.sh`) is not yet
  merged, `phase-status.sh` must inline the cluster-identity pre-flight rather
  than sourcing `whereami.sh`. Stack this branch on top of the SPEC-S4 branch
  when both are in flight.
- **Cluster availability.** The integration test (`13_phase_status_smoke.sh`)
  requires a live EKS cluster. It is gated with the same `SKIP_INTEGRATION`
  guard used by the existing integration tests.

## 13. Estimated effort

**M** (1–3 hours).

- **Script authoring (~60 min)**: ~180 lines of bash across the pre-flight,
  seven `probe_phase_N` functions, the table formatter, the JSON emitter, and
  the `--assert-phase` dispatch. The per-phase probe table in §5 is the full
  design; the implementing agent copies each row into a function body.
- **Unit test + fixtures (~40 min)**: seven fixture JSON files (one per phase
  state class) + the test harness that mocks `aws` and `kubectl` using
  `PATH` override. The assertion set in §6 is enumerated; this is mechanical
  authoring.
- **Chainsaw scenario (~20 min)**: a two-step scenario (assert phase 1
  verified, assert phase 6 non-verified) against the standard kind cluster.
  No new cluster configuration required.
- **Integration test + doc edits (~20 min)**: the smoke test is five
  assertions against `--json` output. Doc edits are two short sentences in
  two files.
- **Rollout audit (~10 min)**: no existing files call the new script, so the
  audit pass is confirming no collisions in `tests/unit/run.sh` and the
  chainsaw `run.sh` manifest.

Total: ~2.5 hours of focused work, well within the M bracket.
