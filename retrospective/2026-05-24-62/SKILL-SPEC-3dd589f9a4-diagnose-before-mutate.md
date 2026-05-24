# Spec: `diagnose-before-mutate`

- **ID**: SKILL-SPEC-3dd589f9a4
- **Source retrospective**: ../2026-05-24-62.md

## Intent

Before consuming any expensive mutating operation (apply-and-verify on management cluster ~15 min; tear-down + rebuild ~30 min; EKS provisioning ~15 min), run a cheap read-only diagnose first. Confirm the inputs are right; surface latent bugs that would waste the long cycle. The asymmetry is huge: a 2-minute diagnose can save 15+ minutes of CI per mistake.

Grounded in: this session dispatched `phase=management apply-and-verify` against an unfixed phase-2 state, burned 25 minutes of CI, and the result was a 1-line policy-09 admission failure that a diagnose would have surfaced beforehand. The next dispatch after PR #52 worked, but a diagnose first would have caught that too.

## Trigger

**Direct user phrases:**
- "Apply X"
- "Run the bring-up"
- "Tear down + rebuild"

**Proactive triggers:**
- About to dispatch any `*-apply-and-verify` workflow
- About to dispatch `mode=teardown-phase-2` / `mode=rebuild` from integration-tests.yml
- About to manually sync an ArgoCD app that provisions expensive cloud resources (PlatformCluster claim, etc.)
- After a long break / fresh session where cluster state is uncertain

**Negative triggers:**
- The diagnose itself failed N times — no value in another diagnose; escalate
- The mutating op is itself the diagnose (e.g., `terraform plan` is read-only)
- The mutating op is fast enough that "just try it" beats diagnose (e.g., <30s ops)

## Inputs

- The mutating operation about to be performed (workflow_id, inputs, target cluster)
- The corresponding diagnostic workflow (if it exists)
- The expected pre-state for the operation to succeed

## Outputs

- Either: a "GO" decision quoting the diagnose evidence that the pre-state is good
- Or: a "NO-GO" decision quoting the evidence of the blocker + the suggested remediation

## Workflow

1. **Identify the diagnose workflow that maps to the mutating op.** Examples:
   - `phase=management apply-and-verify` → `phase-2-diagnose.yml` (read-only) OR `terraform plan` first
   - `integration-tests.yml mode=test test_filter=11` → pre-flight kubectl get applications already in workflow
   - PlatformCluster claim manual sync → `phase-2-diagnose.yml` + verify subnet IDs substituted
   - phase-2 teardown → `verify-absent` mode as POST-check, no pre-check needed beyond "is phase 2 currently working?"

2. **Dispatch the diagnose.** Per `manual-dispatch-as-kubectl-bridge` + `dispatch-then-poll-then-readlog`.

3. **Read the output for blockers.** Specific checks:
   - Is the cluster reachable? (kubectl get nodes)
   - Are dependencies in expected state? (ArgoCD apps Synced+Healthy, CRDs installed, ClusterSecretStore Ready)
   - Any "OutOfSync" / "Degraded" that would break the mutating op?
   - Any recent error events?

4. **If blockers:** STOP. Fix the blocker first (file a PR, ask the user, etc.). Do NOT proceed to the mutating op.

5. **If clear:** proceed to the mutating op. Quote the diagnose evidence in the announcement: "Phase 2 verified Synced+Healthy per [diagnose run URL]; proceeding to apply-and-verify."

## Concrete examples

### Example 1 — the anti-example fixed (handoff Step 0 #4)

**Anti:** session dispatched `phase=management apply-and-verify` without checking that PR #52 (policy 09 relocation) was in main. Result: 15-min apply failed on Kyverno admission. Cost: 15 min CI + agent context spent on diagnosis.

**With this skill:**
1. Identify diagnose: `git log origin/main --oneline | head -5` (or `pull_request_read` for #52).
2. Read: `cb6fd70 fix(policy): move PlatformSecret namespace policy …` IS in main? Yes → GO; No → STOP, merge first.

The handoff Step 0 #4 codifies exactly this for the next session — verify PR #61 merged before dispatching Step 1.

### Example 2 — phase-3 PlatformCluster claim sync (next session, hypothetical)

**Setup:** about to manually sync `argocd/apps/platform-cluster-claim.yaml`. The sync provisions a real EKS cluster (~15 min, real $$).

**Diagnose first:**
1. Dispatch `phase-2-diagnose.yml`. Read: confirm phase 2 fully working (`crossplane-resources` Synced, PlatformCluster XRD Established).
2. Author a one-off `phase-3-precheck.yml`: dump `terraform output -json private_subnet_ids` (or ask user); verify the `clusters/platform/platform-cluster-claim.yaml` has real subnet IDs (not `subnet-REPLACE-ME-AZ1`).
3. Both green → sync. Otherwise STOP.

## Anti-patterns

- **"Just try it"** for expensive ops. The cost of a wasted 15-min CI cycle dominates the cost of a 2-min diagnose.
- **Diagnose AFTER the mutating op fails.** That's debugging, not prevention.
- **Skip diagnose because "I already checked" 30 minutes ago.** Cluster state changes; re-diagnose if the gap exceeds the operation's cycle time.
- **Diagnose results not quoted in the GO/NO-GO decision.** Per `verify-evidence-not-exit-codes`: quote the evidence.

## Acceptance criteria

1. Every dispatch of a mutating workflow >5 min is preceded by a diagnose dispatch within the last 5 min.
2. The GO/NO-GO decision is announced with a verbatim quote from the diagnose output.
3. NO-GO leads to a fix-then-diagnose-again cycle, not the mutating op.
4. The handoff Step 0 explicitly enumerates the pre-conditions to verify before Step 1.

## Files this skill creates / modifies

- One-off `.github/workflows/<system>-precheck.yml` files when the existing diagnose doesn't cover the use case
- (Optional) `ai/precheck-catalog.md` — index of pre-check workflows by mutating-op target
