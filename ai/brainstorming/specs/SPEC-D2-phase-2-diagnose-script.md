# SPEC-D2 — Replace `phase-2-diagnose.yml` with `scripts/diagnose/phase-2.sh`

Brainstorm ID: A6-007 (with cross-comments A1→A6-001, A4→A6-007)
Tier: D (deprecate / simplify)
Applies to phase: 2+

---

## 1. Summary

Delete `.github/workflows/phase-2-diagnose.yml` (~245 lines) and replace it
with `/home/user/k8-platform/scripts/diagnose/phase-2.sh`, a bash script the
agent invokes directly in ~2 seconds. The workflow existed solely because the
agent could not reach `kubectl` at authoring time; that constraint is gone.
The script inlines every diagnostic block from the workflow verbatim (for grep
continuity across PR comments — brainstorm A4→A6-007), adds a CloudTrail
capture section (A1→A6-001), and sits in `scripts/diagnose/` alongside the
tf-drift helper that SPEC-C1/C5 targets for that directory. This is Tier D
cleanup; it removes a superseded dispatch artifact and extends the diagnostic
baseline in a single PR.

---

## 2. Retro pain killed

- **PR #66 / #67 / #68 debug loop — 3-minute round-trip per observation.**
  Each time the lead agent needed a fresh state dump it dispatched
  `phase-2-diagnose.yml`, waited ~3 minutes for the runner to spin up and
  authenticate, and read the log. The same output is now 2 seconds away.
  `ai/handoff.md` "Behavioral rule additions" directly cites this dispatch
  lag as a root-cause amplifier for the PR #66 SA-name mismatch.

- **SPEC-A3 IRSA / Provider-SA / reconcile-error steps would be silently
  lost** if the workflow is deleted without migration. Those steps are
  cross-referenced in `ai/handoff.md` QUICKSTART step 7 and relied on by
  the `crossplane-claim-verify` skill (AGENTS.md §7). This spec migrates
  them into the script so the deletion is an upgrade, not an erasure.

- **PR log search continuity.** Brainstorm comment A4→A6-007 names this
  explicitly: the `══════` section headers in the workflow output are
  referenced across PR comments. Preserving those heading literals in the
  script body keeps that grep trail intact.

- **CloudTrail visibility gap.** Brainstorm comment A1→A6-001 flagged that
  the workflow has no AWS-side audit trace. PRs #66 and #68 required post-hoc
  CloudTrail queries to confirm `sts:AssumeRoleWithWebIdentity` was reaching
  AWS. Promoting that lookup into the standard script collapses a recurring
  manual step.

---

## 3. Out of scope

- **SPEC-A3's three new workflow steps are NOT reimplemented independently
  here.** They are migrated (§5.3). The implementing agent must read SPEC-A3
  §5 in full before authoring the corresponding script sections — the exact
  bash is already specified there and must not drift. See conflict resolution
  below.

- **Mutating the cluster.** The probe-claim block already cleans up after
  itself; that cleanup is preserved. No net-new writes to the cluster.

- **CloudWatch metric snapshots.** A1→A6-001 mentions a "Prom snapshot" in
  the same sentence as CloudTrail. Prometheus/CloudWatch metrics require
  separate tooling (`aws cloudwatch get-metric-statistics`) and a meaningful
  time window to query. Scoping in is a separate spec; this one only adds the
  CloudTrail event lookup.

- **Wiring the script into the `crossplane-claim-verify` skill.** That skill
  calls the workflow via `gh workflow run`. After this spec lands the skill
  should call `bash scripts/diagnose/phase-2.sh` instead. That single-line
  edit is in-scope for the skill's implementing PR, not this spec.

- **Removing SPEC-A3 from the spec directory.** SPEC-A3 describes intent that
  is absorbed here. The file stays as institutional memory; a comment in
  SPEC-A3 §11 pointing to SPEC-D2 is the handoff (see §8 below).

### Conflict resolution: SPEC-D2 vs. SPEC-A3

SPEC-A3 and SPEC-D2 both change the same diagnostic capability. SPEC-A3 was
written first and targets `.github/workflows/phase-2-diagnose.yml`; SPEC-D2
supersedes the medium (workflow) but inherits all of SPEC-A3's content.

Resolution rule: **SPEC-D2 absorbs SPEC-A3.** The implementing PR for SPEC-D2
must include every bash fragment specified in SPEC-A3 §5 (steps a, b, c and
the 2-line probe-label addition) as sections of the new script. SPEC-A3 §6
test requirements (unit test for YAML parse and step-name presence) are
re-targeted to the script: the new unit test asserts the script's section
headings rather than a YAML step list.

If SPEC-A3 has already been implemented (i.e. the three workflow steps exist
in the file when this spec is picked up), the implementing agent reads those
step bodies directly out of the live workflow file and ports them into the
script. The probe-label amendment (`kubectl label ns "$PROBE_NS"
diag-probe=true`) is preserved in the script's probe block.

Branch sequencing: SPEC-D2 replaces SPEC-A3's PR slot. If a SPEC-A3 PR is
open, close it and open SPEC-D2 with the merged scope. Do not ship both.

---

## 4. Files to change / create

| Path | Action | Notes |
|---|---|---|
| `/home/user/k8-platform/scripts/diagnose/phase-2.sh` | **Create** | New file; main deliverable |
| `/home/user/k8-platform/scripts/diagnose/` | **Create dir** | Does not yet exist |
| `/home/user/k8-platform/.github/workflows/phase-2-diagnose.yml` | **Delete** | ~245 lines removed |
| `/home/user/k8-platform/tests/unit/test_phase_2_diagnose_script.sh` | **Create** | Replaces/supersedes the unit test SPEC-A3 specified for the workflow YAML |
| `/home/user/k8-platform/tests/unit/run.sh` | **Modify** | Wire in new unit test (one line) |
| `/home/user/k8-platform/ai/brainstorming/specs/SPEC-A3-phase-2-diagnose-irsa-steps.md` | **Modify** | Add a one-paragraph note in §11 pointing to SPEC-D2 as the implementing spec |

---

## 5. Implementation notes

### 5.1 Script skeleton and invocation

```bash
#!/usr/bin/env bash
# scripts/diagnose/phase-2.sh — Phase 2 read-only diagnostic bundle.
# Replaces .github/workflows/phase-2-diagnose.yml (SPEC-D2).
# Usage: bash scripts/diagnose/phase-2.sh
# Requires: kubectl for k8-platform-mgmt, aws CLI, creds in env.
set -euo pipefail
set +e   # individual lookup failures are non-fatal
AWS_REGION="${AWS_REGION:-us-east-1}"
trap 'echo "[DIAG COMPLETE] phase-2.sh finished at $(date -u +%Y-%m-%dT%H:%M:%SZ)"' EXIT
```

The script exits 0 regardless of individual lookup failures (same contract as
the workflow). The `trap` sentinel lets callers confirm the full run finished.

### 5.2 Section heading discipline (grep continuity)

Every logical block's `echo` lines must be byte-for-byte identical to the
workflow's corresponding `echo` lines. This is the A4→A6-007 preservation
requirement: PR comments search for these strings.

The `# ===...===` comment fences must also be preserved. New sections from
SPEC-A3 and A1→A6-001 follow the same `══════ ... ══════` pattern:

```bash
echo "══════ IRSA SA-name vs trust-doc diff (Crossplane roles) ══════"
echo "══════ Provider Deployment — running serviceAccountName ══════"
echo "══════ Crossplane core reconcile-error events (last 5) ══════"
echo "══════ CloudTrail — sts:AssumeRoleWithWebIdentity last 30m ══════"
```

### 5.3 Diagnostic blocks to preserve (complete inventory)

The implementing agent reads the current workflow file before writing a single
line of the script. Blocks must appear in this order:

1. **Preflight** — `aws sts get-caller-identity` + `aws eks update-kubeconfig`
   (workflow lines 37–38). Becomes a guard: if `kubectl cluster-info` fails,
   exit 1 rather than produce empty output.

2. **Bug 3 — ArgoCD applications + sync diffs** (lines 43–71). Port verbatim:
   four named Applications, `describe`/`comparedTo`/`conditions`/
   `operationState.message`/per-resource sync/health.

3. **Bug 4 — Crossplane providers + functions** (lines 76–88). Port verbatim.

4. **Bug 4 — ESO controller + ClusterSecretStore** (lines 89–103). Port
   verbatim including per-pod log tail-80.

5. **Bug 4 — probe claim and observe** (lines 105–227). Port verbatim,
   including the `go-template` MR walk, XR conditions, events. Insert the
   SPEC-A3 probe-label amendment immediately after `kubectl create ns
   "$PROBE_NS"`: `kubectl label ns "$PROBE_NS" diag-probe=true --overwrite`.

6. **AWS-side ASM + IRSA check** (lines 229–244). Port verbatim.

7. **SPEC-A3 step (a) — IRSA SA-name vs trust-doc diff** (SPEC-A3 §5a).
   `aws iam list-roles` + per-role trust-subject loop with `MATCH:/MISS:`
   output. ≤10 lines per role, ≤4 roles.

8. **SPEC-A3 step (b) — Provider Deployment serviceAccountName** (SPEC-A3
   §5b). `kubectl get deploy -l pkg.crossplane.io/provider` custom-columns
   + per-Deployment jsonpath SA name.

9. **SPEC-A3 step (c) — reconcile-error events (last 5)** (SPEC-A3 §5c).
   Probe-namespace re-derivation via `kubectl get ns -l diag-probe=true` +
   crossplane-core log grep. ≤5 lines per pod, ≤2 pods.

10. **CloudTrail capture** — net-new, see §5.4.

### 5.4 CloudTrail capture block (net-new, A1→A6-001)

```bash
echo ""
echo "══════ CloudTrail — sts:AssumeRoleWithWebIdentity last 30m ══════"
START_TIME=$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || python3 -c "from datetime import datetime,timedelta,timezone; \
     print((datetime.now(timezone.utc)-timedelta(minutes=30)) \
     .strftime('%Y-%m-%dT%H:%M:%SZ'))")
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --start-time "$START_TIME" \
  --query 'Events[*].{Time:EventTime,User:Username,Error:ErrorCode}' \
  --output table 2>&1 | head -60 || echo "(CloudTrail lookup failed — check permissions)"
```

The `--start-time` window of 30 minutes covers a fresh diagnose run;
`head -60` caps output at ~3 KB. The fallback `echo` ensures a missing
`cloudtrail:LookupEvents` permission produces a named finding rather than
a silent gap. Full script output budget: ≤50 KB total.

### 5.5 Idempotency and partial-failure handling

`set +e` is active throughout; no individual lookup failure aborts the run.
Probe namespace cleanup (`--wait=false`) is preserved; if the CRD is absent
the probe block exits 0 early. Running the script twice leaves no persistent
side effects (probe namespaces use `$(date +%s)` for uniqueness). The script
requires no cluster-admin; it uses only `get`, `describe`, `logs`, and
namespace-scoped `create`/`delete` for the probe.

---

## 6. Tests required

Per AGENTS.md §6.1. Applicable layers: unit and manual-verify.

**`tests/unit/test_phase_2_diagnose_script.sh`** asserts:

1. `bash -n scripts/diagnose/phase-2.sh` exits 0.
2. All seven required `══════` headings from §5.3 are present (one `grep -q`
   per heading: `all Applications`, `providers`, `ClusterSecretStore`,
   `IRSA SA-name vs trust-doc`, `Provider Deployment`, `reconcile-error
   events`, `CloudTrail`).
3. `grep -q 'diag-probe=true' scripts/diagnose/phase-2.sh` exits 0.
4. `grep -q 'tail -5' scripts/diagnose/phase-2.sh` exits 0.
5. `grep -q 'DIAG COMPLETE' scripts/diagnose/phase-2.sh` exits 0.
6. `! test -f .github/workflows/phase-2-diagnose.yml` (workflow deleted).

`tests/unit/run.sh` — add one invocation line (standard convention).

**Kyverno / Chainsaw**: not applicable — no new cluster-resource contract.

**Manual-verify**: invoke the script against a live cluster once before
opening the PR; paste terminal output confirming `[DIAG COMPLETE]` in the
PR description. Not a CI gate but required for sign-off.

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Fast (<10 s each). Names follow `tests/unit/test_<name>.sh`.

1. **`test_phase_2_diagnose_script.sh` — heading completeness**: assert all
   ten `══════` headings listed in §5.3 exist in the script. Fails if any
   heading is accidentally omitted or renamed during authoring.

2. **`test_phase_2_diagnose_script.sh` — probe-label guard**: assert that
   `diag-probe=true` appears in the script exactly once in a `kubectl label`
   call. Prevents silent removal of the label that SPEC-A3's step (c) depends
   on for probe-namespace re-derivation.

3. **`test_phase_2_diagnose_script.sh` — CloudTrail head cap**: assert that
   `head -60` (or a comparable truncation) is present in the CloudTrail block.
   Prevents unbounded output if the account has a large event volume.

4. **`test_phase_2_diagnose_script.sh` — workflow file absent**: assert
   `.github/workflows/phase-2-diagnose.yml` does not exist. Prevents the
   scenario where someone re-adds the workflow without removing the script.

5. **`test_phase_2_diagnose_script.sh` — shebang + strict-mode**: assert
   `#!/usr/bin/env bash` and `set -euo pipefail` are both present. The
   `set +e` that follows is an intentional override for per-block
   non-fatality; both must coexist.

### Integration

Names follow `tests/integration/NN_<name>.sh`. These are suggestions for
a future PR; not required for the implementing PR.

1. **`tests/integration/50_diagnose_script_runs.sh`**: run the script, assert
   it completes and its stdout contains `[DIAG COMPLETE]` within 120 s.

2. **`tests/integration/50_diagnose_script_argocd_section.sh`**: assert the
   ArgoCD section emits at least one `══════ describe Application` line.

3. **`tests/integration/50_diagnose_script_cloudtrail.sh`**: assert the
   CloudTrail block emits either a result row or the named fallback string
   without a bash error exit.

### E2E

Not applicable. The script is a read-only diagnostic tool; no chainsaw
scenario can exercise it meaningfully (kind has no CloudTrail, no real IRSA).
The E2E gate is the manual-verify live-cluster run documented in §6.

---

## 8. Documentation updates

- `/home/user/k8-platform/ai/handoff.md` QUICKSTART step 7: replace the
  pointer to `gh workflow run phase-2-diagnose.yml` with
  `bash scripts/diagnose/phase-2.sh`. One sentence change.

- `/home/user/k8-platform/ai/handoff.md` "Behavioral rule additions —
  Pointers": update the `phase-2-diagnose.yml` entry to `scripts/diagnose/
  phase-2.sh` and extend the description to note the CloudTrail capture.

- `/home/user/k8-platform/AGENTS.md` §7 (Testing loops — companion skills):
  the `crossplane-claim-verify` bullet that currently references
  `phase-2-diagnose.yml` should reference the script path. One line.

- `/home/user/k8-platform/ai/brainstorming/specs/SPEC-A3-phase-2-diagnose-irsa-steps.md`
  §11 (Verification checklist): add a paragraph noting that SPEC-A3's scope
  was absorbed into SPEC-D2 and the implementing PR is SPEC-D2's. This
  preserves the SPEC-A3 document as institutional memory without creating
  a ghost spec.

---

## 9. Workflow / auto-invocation wiring

The workflow was `workflow_dispatch`-only. The replacement is a runbook-style
tool invoked directly: `bash scripts/diagnose/phase-2.sh`. No CI workflow
auto-invokes it. The `scripts/diagnose/` directory follows AGENTS.md §11
("Diagnostic helper scripts (read-only)"); SPEC-C1/C5's
`scripts/diagnose/tf-drift-check.sh` is the peer pattern.

---

## 10. Discoverability

1. **Mechanical enforcement**: unit test assertion 6 (`! test -f
   .github/workflows/phase-2-diagnose.yml`) fails the CI push check if the
   workflow is re-added without updating the test.

2. **Documentation pointer**: AGENTS.md §7's `crossplane-claim-verify` bullet
   (updated per §8) is the canonical landing point — one hop to the script.

3. **Adversarial-review trigger**: add a bullet to `ai/testing-guidelines.md`
   §6.4: "For diagnostic script ports, confirm every `══════` heading from
   the source workflow is present in the script." Surfaces coverage gaps at
   the test-drafting gate.

---

## 11. Verification checklist

- [ ] `bash -n /home/user/k8-platform/scripts/diagnose/phase-2.sh` exits 0.
- [ ] `bash /home/user/k8-platform/tests/unit/test_phase_2_diagnose_script.sh` exits 0 with all sub-assertions passing.
- [ ] `! test -f /home/user/k8-platform/.github/workflows/phase-2-diagnose.yml` — confirm the workflow file is gone.
- [ ] `grep -c '══════' /home/user/k8-platform/scripts/diagnose/phase-2.sh` returns ≥ 20 (ten sections × 2 open/close pairs — adjust if some headings use a single echo line).
- [ ] `grep -q 'diag-probe=true' /home/user/k8-platform/scripts/diagnose/phase-2.sh` exits 0.
- [ ] `grep -q 'AssumeRoleWithWebIdentity' /home/user/k8-platform/scripts/diagnose/phase-2.sh` exits 0 (CloudTrail block present).
- [ ] `grep -q 'DIAG COMPLETE' /home/user/k8-platform/scripts/diagnose/phase-2.sh` exits 0 (trap present).
- [ ] `grep -q 'phase-2-diagnose' /home/user/k8-platform/AGENTS.md` returns non-zero — i.e., old workflow reference has been removed or updated.
- [ ] `bash /home/user/k8-platform/tests/unit/run.sh` exits 0 with the new test included.
- [ ] (Live cluster) `bash scripts/diagnose/phase-2.sh 2>&1 | tail -5` ends with `[DIAG COMPLETE]` within 120 s. Paste run output URL or terminal capture in the PR description.

---

## 12. Rollout notes

- **Backward compatibility**: the workflow was `workflow_dispatch`-only and
  no other workflow or cron triggers it. Deleting it breaks nothing
  automated. The only change callers see is that `gh workflow run
  phase-2-diagnose.yml` no longer exists; they call the script directly.

- **Audit before merge**: run `grep -r 'phase-2-diagnose.yml'
  /home/user/k8-platform/` and confirm the only hits are the files listed
  in §8. No other file depends on the workflow.

- **SPEC-A3 coordination**: if SPEC-A3's implementing PR is open, close it
  and absorb its changes into the SPEC-D2 PR. If SPEC-A3 has already merged,
  port the merged step bodies from the live workflow before deleting it.

- **Pluralsight sandbox constraints**: not relevant. The CloudTrail lookup
  requires `cloudtrail:LookupEvents`; if the sandbox lacks it, the fallback
  echo fires and the script exits 0. No EC2, no Terraform.

- **Branch sequencing**: SPEC-A3 was Cluster 6 (standalone, anytime). SPEC-D2
  replaces that slot. Branch off `main`; no dependency on clusters 1–5.
  Suggested branch name: `feat/phase-2-diagnose-script`.

- **Net line count**: −245 YAML + ~220 bash + ~60 unit test = roughly neutral
  in lines, but the CI runner overhead (checkout, credentials, step YAML
  scaffolding) is entirely removed and the 3-minute dispatch round-trip is
  gone.

---

## 13. Estimated effort

**S** (≤1 hr).

- **Script authoring (25 min)**: port ten blocks from the workflow, strip YAML
  indentation, add the four new headings. No net-new logic beyond the
  CloudTrail block (~10 lines).
- **Unit test (15 min)**: six one-liner `grep`/`test -f` assertions.
- **Documentation edits (10 min)**: four files, one sentence each.
- **Smoke run + PR description (10 min)**: `bash -n` + unit run + one
  live-cluster invocation for the `[DIAG COMPLETE]` sentinel.

SPEC-A3 absorption is not a time risk: the resolution rule in §3 is
deterministic. §12 covers the "SPEC-A3 already merged" case explicitly.
