# SPEC-A3 — extend `phase-2-diagnose.yml` with IRSA / Provider-SA / reconcile-error dumps

## 1. Summary

Add three deterministic steps to `.github/workflows/phase-2-diagnose.yml`
that capture the three lookups every recent PlatformSecret debug session
has had to author ad-hoc: (a) per-Crossplane-IRSA-role trust-document
vs. cluster ServiceAccount-name diff, (b) the actual `serviceAccountName`
on each provider-family-aws Deployment as deployed, and (c) the last 5
reconcile-error events from Crossplane core logs filtered to a claim's
namespace. These three dumps were authored inline in PRs #66 and #68
and are still being re-typed by hand each session — promoting them into
the diagnose workflow makes them a one-dispatch artifact for every
future bring-up.

## 2. Retro pain killed (with cited PRs/bugs)

- **PR #66** (root-cause of composite-not-Ready) — the SA-name-vs-trust
  mismatch was discovered only after the agent manually authored
  `aws iam get-role --query Role.AssumeRolePolicyDocument` and
  cross-referenced against the rendered provider-family-aws SA name.
  Step (a) of this spec promotes that lookup so it runs on every
  dispatch.
- **PR #68** (provider Deployment not rolled after `DeploymentRuntimeConfig`
  edit) — confirmation that the Deployment's running `serviceAccountName`
  was still the hash-suffixed legacy form required `kubectl -n crossplane-system
  get deploy -l pkg.crossplane.io/provider=* -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}'`
  authored ad-hoc inside the PR debug loop. Step (b) promotes it.
- **PR #67** (`triggers_replace` miss) — needed visibility into "the apply
  ran but did the new SA name actually take?" — same lookup as (b), again
  authored inline.
- **`ai/handoff.md` "Behavioral rule additions"** — *"It applied
  successfully ≠ the change reached the cluster"* — steps (a) + (b)
  produce the evidence that lets the next session apply that rule without
  re-typing the lookups.
- **Step 7 of QUICKSTART** (handoff.md ~line 95) — "investigate the
  SECONDARY bug" instructs the agent to read crossplane core logs
  filtered to the claim's namespace. Step (c) of this spec captures that
  read in a stable form (last 5 reconcile-error events) so the agent
  doesn't have to compose the grep on the fly.

## 3. Out of scope

- Mutating the cluster (the diagnose workflow is read-only — the existing
  probe-claim step already deletes after itself; nothing new added here
  mutates).
- Fixing IRSA / SA misalignment — this spec captures the evidence; the
  fix lives in `terraform/management/helm.tf` and is out of scope.
- Adding new roles to the trust-doc check beyond the Crossplane IRSA
  roles named by `terraform/management/irsa.tf` (`-crossplane`). ESO,
  ArgoCD, ExternalDNS IRSA roles are not in the failure class PRs #66/#68
  addressed; if a future PR needs them, extend in a follow-up spec.
- Cross-region IRSA dumps — sandbox is us-east-1 / us-west-2; no
  additional region-walking logic needed.
- Authoring/altering the SPEC-A2 decision-tree skill or the
  crossplane-claim-verify skill. They are *consumers* of this evidence,
  not producers; the wiring point is §9.

## 4. Files to change / create

**Modify only:** `.github/workflows/phase-2-diagnose.yml`.

Insertion points (line numbers reference the current file as read at
spec-authoring time; the agent should re-locate by step name if drift
has occurred):

1. **New step (a)** — insert AFTER the existing `"AWS-side ASM + IRSA
   check"` step that ends at line 244. The existing step already dumps
   the SA annotation; the new step extends it with the actual trust-doc
   parse and SA-name diff. Name: `"IRSA — SA-name vs trust-doc diff
   (Crossplane roles)"`.

2. **New step (b)** — insert AFTER step (a), BEFORE the file's EOF.
   Name: `"Provider Deployment — running serviceAccountName"`. Lives
   adjacent to the IRSA check so the two are read together.

3. **New step (c)** — insert AFTER step (b). Name: `"Crossplane core
   reconcile-error events (last 5 per claim namespace)"`. Re-uses the
   `PROBE_NS` variable produced by the existing `"Bug 4 — try a probe
   claim and observe"` step (lines 105–227). If that step did not run
   (CRD absent → early-exits at line 111), step (c) falls through with
   `"probe namespace not set — skipping per-namespace event walk"` and
   instead dumps reconcile errors filtered to the `crossplane-system`
   namespace as a fallback.

   Because the existing probe step exports nothing across steps
   (variables die at step boundary), step (c) must re-derive the probe
   namespace from the cluster: `kubectl get ns -l diag-probe=true
   -o name` (so the probe step must also be amended to add the label
   `diag-probe=true` at namespace creation — line 117 area). This is a
   2-line additive change in the existing step and the only
   modification to existing code.

No other files modified. No new files created. No changes to
`terraform/`, `crossplane/`, `argocd/`, `clusters/`, `platform-services/`,
`tests/`, `policies/`, `scripts/`.

## 5. Implementation notes

### Step (a) — IRSA SA-name vs. trust-doc diff

Concrete invocations (informal; the agent will adjust quoting for the
YAML literal block per the lesson from PR #65):

```
ROLES=$(aws iam list-roles \
  --query 'Roles[?starts_with(RoleName,`k8-platform-mgmt-crossplane`)].RoleName' \
  --output text)

for role in $ROLES; do
  echo "── role: $role ──"
  TRUST_SUBJECTS=$(aws iam get-role --role-name "$role" \
    --query 'Role.AssumeRolePolicyDocument.Statement[*].Condition.StringEquals' \
    --output json \
    | jq -r '.[] | to_entries[] | select(.key | endswith(":sub")) | .value | (if type=="array" then .[] else . end)')
  echo "trust subjects:"
  printf '  %s\n' $TRUST_SUBJECTS

  for subj in $TRUST_SUBJECTS; do
    ns="$(echo "$subj" | awk -F: '{print $(NF-1)}')"
    sa="$(echo "$subj" | awk -F: '{print $NF}')"
    if kubectl -n "$ns" get sa "$sa" >/dev/null 2>&1; then
      ARN=$(kubectl -n "$ns" get sa "$sa" \
        -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
      echo "  MATCH: $ns/$sa exists, annotated arn=$ARN"
    else
      echo "  MISS:  $ns/$sa does NOT exist in cluster (or wrong name)"
    fi
  done
done
```

Output bounds: one block per IRSA role, ≤10 lines per role. With ≤4
Crossplane roles realistically present this is well under 5 KB.

Idempotency: read-only against AWS + cluster. Safe to re-dispatch.

### Step (b) — Provider Deployment serviceAccountName

```
kubectl -n crossplane-system get deploy \
  -l pkg.crossplane.io/provider \
  -o custom-columns=NAME:.metadata.name,SA:.spec.template.spec.serviceAccountName,READY:.status.readyReplicas

for d in $(kubectl -n crossplane-system get deploy -l pkg.crossplane.io/provider -o name); do
  echo "── $d ──"
  kubectl -n crossplane-system get "$d" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
  # also surface the label that names the provider (so SA name can be
  # cross-referenced to the provider Crossplane object)
  kubectl -n crossplane-system get "$d" \
    -o jsonpath='provider-label={.metadata.labels.pkg\.crossplane\.io/provider}{"\n"}'
done
```

Cross-references step (a): when (a) says trust subject is
`system:serviceaccount:crossplane-system:upbound-provider-family-aws`
and (b) says the Deployment's SA is `provider-family-aws-24aaab54a3a0`,
the mismatch is named in one screen.

Output bounds: one row in the table plus ≤4 lines per Deployment;
realistically 1–3 Deployments. Well under 5 KB.

Idempotency: read-only.

### Step (c) — reconcile-error events filtered to claim's namespace

```
PROBE_NS=$(kubectl get ns -l diag-probe=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$PROBE_NS" ]; then
  echo "no probe namespace labeled diag-probe=true — dumping crossplane-system reconcile errors instead"
  PROBE_NS=crossplane-system
fi
echo "── reconcile errors for namespace: $PROBE_NS (last 5) ──"
for pod in $(kubectl -n crossplane-system get pods -l app=crossplane -o name 2>/dev/null); do
  echo "── $pod ──"
  kubectl -n crossplane-system logs --tail=2000 "$pod" 2>&1 \
    | grep -E "(reconcile error|cannot apply|AssumeRoleWithWebIdentity|403|forbidden)" \
    | grep -E "$PROBE_NS|crossplane-system" \
    | tail -5
done
```

The `tail -5` enforces the ≤5-events contract from the brief. With
≤2 crossplane core pods (HA replica count is 2) the total output is
bounded at ≤10 matching lines + ≤2 separators ≈ <1 KB.

Output bounds: ≤5 lines per crossplane pod, ≤2 pods → ≤10 lines + headers.

Idempotency: read-only. Re-dispatching against the same probe namespace
yields the same window of events (logs are append-only within a pod).

### Probe-step modification (the 2-line additive change)

In the existing `"Bug 4 — try a probe claim and observe"` step
(line 117 area), change:

```
kubectl create ns "$PROBE_NS"
```

to:

```
kubectl create ns "$PROBE_NS"
kubectl label ns "$PROBE_NS" diag-probe=true --overwrite
```

This is the ONLY change to existing step bodies. It is required so
step (c) can locate the probe namespace without inter-step variable
passing (GitHub Actions does not preserve shell variables across `run:`
steps).

### YAML literal-block discipline (lesson from PR #65)

Each new step's `run: |` body must be authored without embedded
heredocs that contain unindented lines — the YAML parser will silently
de-register `workflow_dispatch`. Validate with `python -c "import yaml,
sys; yaml.safe_load(open('.github/workflows/phase-2-diagnose.yml'))"`
locally before the implementing PR is pushed. Use single-quoted shell
strings (`'`) for `kubectl -o jsonpath=` values to avoid YAML-vs-shell
quote interactions.

## 6. Tests required

Per AGENTS.md §6.1 — maximal coverage at applicable layers. The
applicable layers for a workflow-file change are unit and manual-verify.

### Unit (required, runs on every push)

- **New** `tests/unit/test_phase_2_diagnose_workflow_parse.sh` —
  asserts:
  1. `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/phase-2-diagnose.yml'))"` exits 0.
  2. The three new step names exist in the workflow's step list
     (greppable via the `name:` lines).
  3. The probe-step `kubectl label ns ... diag-probe=true` line exists
     (so a future edit that removes it breaks step (c) loudly).
  4. The `tail -5` clause exists in step (c) so the ≤5-event budget
     isn't silently widened.

  This file is added under `tests/unit/` BUT the spec author for SPEC-A3
  does not edit `tests/unit/` directly — the implementing PR does. The
  spec only specifies the assertions.

- **Extend** `tests/unit/run.sh` to invoke the new test (one line, same
  convention as the existing tests).

### Kyverno

N/A — no new cluster-resource pattern introduced.

### Integration

N/A — the workflow itself is the integration harness; dispatching it
IS the integration test (see §6.7 manual-verify).

### Chainsaw

N/A — no XRD or Composition added.

### Manual-verify (per AGENTS.md §6.7)

The diagnose workflow is `workflow_dispatch`-only and is not heavy in
the §6.7 sense (no kind boot, no terraform apply). The implementing PR
must still dispatch it once against the branch HEAD before opening for
review and paste the run URL into the PR description, demonstrating
the three new steps produced output. This is the standard pattern; not
a §6.7 mandated verifier-workflow gate.

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Concrete cases for `tests/unit/test_phase_2_diagnose_workflow_parse.sh`
(a superset of the §6 gate tests — §6 specifies the minimum; this
section catalogues additional cases worth adding as the workflow grows):

1. **YAML parses cleanly** — `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/phase-2-diagnose.yml'))"` exits 0. Covers the PR #65 silent-registration failure class.
2. **Step (a) trust-subject loop present** — `grep -c 'TRUST_SUBJECTS' .github/workflows/phase-2-diagnose.yml` returns ≥ 1. Ensures the diff logic was not accidentally removed during a rebase.
3. **`tail -5` budget enforced in step (c)** — `grep -c 'tail -5' .github/workflows/phase-2-diagnose.yml` returns ≥ 1. Guards against output-budget drift.
4. **`diag-probe=true` label present in probe step** — `grep -c 'diag-probe=true' .github/workflows/phase-2-diagnose.yml` returns ≥ 1. Validates the 2-line additive change that lets step (c) locate the probe namespace.
5. **`set +e` at top of each new step body** — `grep -c 'set +e' .github/workflows/phase-2-diagnose.yml` returns a count ≥ the total new steps (3) plus whatever the existing workflow already had. Prevents a missing-role from aborting the full diagnose run.

### Integration

N/A at the automated layer. The workflow itself IS the integration harness — dispatching `phase-2-diagnose.yml` against a live cluster exercises steps (a), (b), and (c) end-to-end. The §6 manual-verify dispatch (paste run URL into PR description) serves as the integration gate. There is no value in an additional `tests/integration/` wrapper that merely re-dispatches the workflow.

### E2E

N/A. No XRD, Composition, or Crossplane claim is introduced by this spec. The chainsaw suite (`tests/chainsaw/`) exercises claim lifecycle; SPEC-A3 only adds read-only diagnostic steps to an existing workflow and does not alter any claim path. A future spec that adds claim-level fixture tests may reference the step-(c) reconcile-error dump format, but that is out of scope here.

## 8. Documentation updates

- `ai/handoff.md` "QUICKSTART → Step 7" paragraph: add a sentence
  pointing at the new diagnose steps as the first read instead of
  composing the IRSA/SA lookups by hand.
- `ai/handoff.md` "Behavioral rule additions" → "It applied
  successfully ≠ the change reached the cluster": cite the new step (b)
  as the canonical post-apply cluster-side check for SA-name propagation.
- `AGENTS.md` §7 (Testing loops — companion skills): add one bullet
  under `crossplane-claim-verify` noting that `phase-2-diagnose.yml`
  is the read-once snapshot to dispatch before the skill walks the
  claim chain (the skill consumes the artifact; it does not duplicate
  the dumps).

No new docs file; no ADR (this is workflow plumbing, not a design choice).

## 9. Workflow / auto-invocation wiring

`.github/workflows/phase-2-diagnose.yml` is the existing diagnose entry
point. Triggered by `workflow_dispatch` only. The three new steps are
plain `steps:` entries under the existing `diagnose` job; they run on
every dispatch automatically. No matrix, no conditional `if:` —
unconditional execution is the contract (the brief: *"confirm new steps
run on every dispatch"*).

`set +e` at the top of each step body (same convention as existing
steps) so a missing role / missing SA / missing CRD does not abort the
rest of the diagnose run. Each step's exit code is unconditionally 0
unless `actions/checkout` itself fails.

Discoverability of the workflow itself is unchanged — it remains
`gh workflow run phase-2-diagnose.yml` from any branch with the file
present.

## 10. Discoverability (AGENTS.md sections that point to this workflow)

The implementing PR must verify (and add if missing) references in:

- **`ai/handoff.md` Pointers section** — already lists
  `.github/workflows/phase-2-diagnose.yml`; confirm the description
  reflects the IRSA / SA / reconcile-error capture.
- **`AGENTS.md` §7** — add the cross-reference described in §8 of this
  spec.
- **`AGENTS.md` §6.7** — note (one sentence) that phase-2-diagnose is
  the read-only snapshot workflow and is intentionally NOT under the
  manual-verify-then-PR contract because it neither boots a cluster
  nor takes >2 min.
- **SPEC-A2** (`ai/brainstorming/specs/SPEC-A2-claim-decision-tree.md`)
  — if SPEC-A2 lands before this one, add a forward-reference in its
  §9 noting that the decision-tree skill should prefer reading a recent
  `phase-2-diagnose.yml` run's IRSA/SA evidence over re-querying the
  cluster.

## 11. Verification checklist

- [ ] `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/phase-2-diagnose.yml'))"` exits 0.
- [ ] `gh workflow list` shows `Phase 2 diagnose (read-only)` (i.e.
      `workflow_dispatch` re-registered after the edit).
- [ ] Dispatched run on the branch HEAD completes green.
- [ ] The dispatched run's log contains all three new step names.
- [ ] Step (a) output identifies at least one Crossplane IRSA role and
      prints either `MATCH:` or `MISS:` for each trust subject.
- [ ] Step (b) prints a `serviceAccountName` jsonpath value for every
      provider-family-aws Deployment present.
- [ ] Step (c) prints either a `── reconcile errors for namespace: …`
      header followed by ≤5 matches per crossplane pod, OR the
      `no probe namespace …` fallback line.
- [ ] Each new step's output is <5 KB (eyeball the log file size — the
      whole diagnose log shouldn't grow by more than ~15 KB).
- [ ] `tests/unit/test_phase_2_diagnose_workflow_parse.sh` exists, is
      wired into `tests/unit/run.sh`, and passes locally.
- [ ] PR description includes the dispatched run URL.

## 12. Rollout notes

- Single PR off `main` (or stacked on SPEC-A2's implementation PR if
  ordering is convenient — they don't conflict because A2 modifies a
  skill and A3 modifies a workflow + one new unit test).
- No cluster impact: workflow is `workflow_dispatch`-only and the
  inserted steps are read-only. No phase teardown / re-apply needed.
- Backward-compatible: if the cluster is missing the Crossplane IRSA
  role, step (a) prints nothing in the per-role loop (the `ROLES`
  variable is empty); step (b) prints nothing if no provider
  Deployments exist; step (c) falls back to `crossplane-system`. None
  of these cases fail the workflow.
- Account-rotation safe (AGENTS.md §8.1): the role-name pattern
  `k8-platform-mgmt-crossplane` is durable across account rotations;
  the actual ARN is derived at runtime via `aws iam list-roles`.
- Reversible: if a future Crossplane upgrade (e.g. 2.2; see handoff
  pending-followups item 8) changes the provider label or SA naming
  convention, the new steps continue to work — they discover labels
  dynamically rather than hardcoding names.

## 13. Estimated effort

**S** (small) — three additive YAML steps + one 2-line edit to an
existing step + one new shell unit test (≈40 LOC) + three documentation
sentence-level edits. The lesson from PR #65 (YAML literal-block
validation before push) is the only sharp edge; one local
`yaml.safe_load` invocation covers it. Realistic implementation +
dispatch + PR = ½ to 1 working session.
