# SPEC-LA6 — `scripts/crossplane-reset-provider.sh <provider>`

Brainstorm ID: A1-056. Tier A item LA6 from `ai/brainstorming/specs/larger-list-preferences.md`.

---

## 1. Summary

Add a single executable script at
`/home/user/k8-platform/scripts/crossplane-reset-provider.sh` that accepts
a provider name argument (e.g. `provider-family-aws`,
`provider-aws-secretsmanager`) and performs the following sequence: delete
the Crossplane-managed Deployment for that provider using the
`pkg.crossplane.io/provider=<name>` label selector, wait for Crossplane to
re-render the Deployment from the current `DeploymentRuntimeConfig`, then
verify the new pod is Running with the expected ServiceAccount name. This
codifies the manual hack introduced in PR #68 — currently scattered across
retro notes — into one command an agent or operator can call without
reconstructing the steps from memory. The script lives alongside the
existing diagnostic and operational scripts in `scripts/` (e.g.
`scripts/diag-component.sh`). It is part of `CLUSTERING-REVIEW.md` Tier A.
The smallest concrete artifact is one new bash script plus one unit test.

---

## 2. Retro pain killed

- **Three-PR cascade from SA-name drift (PRs #66, #67, #68).**
  `retrospective/2026-05-25-70.md` Phase 2: after PR #67 pinned the SA name
  in `DeploymentRuntimeConfig`, the running provider pod was still mounted on
  the old hash-suffixed SA (`provider-family-aws-24aaab54a3a0`). Root cause:
  Crossplane's Provider controller re-renders its Deployment only when the
  Provider object itself changes; a `DeploymentRuntimeConfig`-only edit
  leaves the Deployment stale. Without a known recovery procedure the session
  burned an extra dispatch cycle and a third PR to land the delete one-liner.

- **Undocumented recovery steps re-derived each session.**
  The exact label selector and `--wait=false` flag (`kubectl delete deploy -l
  pkg.crossplane.io/provider=provider-family-aws --wait=false`) live only in
  the retro narrative. A future agent reading `ai/handoff.md` sees Bug 3's
  fix steps but not the deployment-reset detail.

- **Bug 3 fix will exercise this path again.** `ai/handoff.md` lines 79–91
  direct the next agent to bump `crossplane_provider_family_aws_version` and
  apply to the live EKS cluster. A version bump triggers the same
  Deployment-stale condition. Having a single command removes the need to
  remember the label selector, namespace, and wait strategy.

- **No wait-and-verify in PR #68.** PR #68 deleted the Deployment with
  `--wait=false` and included no follow-up health check. A subsequent
  `terraform apply` or chainsaw run arriving before the new pod became Ready
  could produce a spurious failure. The script adds a deterministic wait.

---

## 3. Out of scope

- **Modifying `DeploymentRuntimeConfig` or Provider manifests.** The script
  only triggers re-render of an already-configured provider. Changing the
  pinned SA name or bumping a provider version is the caller's job.

- **Multi-provider batch reset.** The script resets one provider per
  invocation. Sequential resets are the caller's concern.

- **Crossplane core restart.** This script targets provider Deployments
  only, identified by `pkg.crossplane.io/provider`. Core pod cycling is a
  different failure mode.

- **Automated invocation from CI or the `crossplane-claim-verify` skill.**
  Deleting a running Deployment is a destructive cluster mutation requiring
  explicit operator intent. The skill may suggest the command; it will not
  call it.

### Considered and rejected

- **`kubectl rollout restart deployment`** — recycles pods but does NOT
  cause Crossplane to re-render the Deployment spec from
  `DeploymentRuntimeConfig`. The SA name stays wrong. Rejected.

- **Patching `Provider.spec.revision`** — a same-string patch no-ops; a real
  package hash change re-downloads the OCI image, adding network dependency.
  Rejected in favor of the proven delete-and-wait from PR #68.

- **`kubectl annotate` timestamp touch on Provider** — leaves junk on the
  object and is undocumented. Rejected.

---

## 4. Files to change / create

**Create:**

- `/home/user/k8-platform/scripts/crossplane-reset-provider.sh` — new
  runbook script (executable, bash, ~80 lines).
- `/home/user/k8-platform/tests/unit/test_crossplane_reset_provider.sh` —
  unit test for argument validation, label-selector construction, and
  header-comment presence. ~50 lines.

**Modify:**

- `/home/user/k8-platform/scripts/README.md` — add one row to the scripts
  table.
- `/home/user/k8-platform/AGENTS.md` — add a provider-Deployment-staleness
  note (see §8).
- `/home/user/k8-platform/ai/handoff.md` — extend the Bug 3 fix steps to
  reference the reset script.

---

## 5. Implementation notes

### 5.1 Script header — workaround annotation (mandatory)

```bash
#!/usr/bin/env bash
# Usage: scripts/crossplane-reset-provider.sh <provider-name>
# Example: scripts/crossplane-reset-provider.sh provider-family-aws
#
# TACTICAL HACK — this script codifies the PR #68 workaround.
# Crossplane's Provider controller re-renders its Deployment only when
# the Provider object itself changes; a DeploymentRuntimeConfig-only edit
# creates the new SA but leaves the running pod on the old one. Deleting
# the Deployment forces Crossplane to recreate it from the current config.
#
# This is a workaround, not a long-term fix. It is required whenever a
# DeploymentRuntimeConfig change or provider version bump must propagate
# to a running pod. See retrospective/2026-05-25-70.md Phase 2.
set -euo pipefail
PROVIDER="${1:-}"
NAMESPACE="crossplane-system"
TIMEOUT=120  # seconds

if [[ -z "$PROVIDER" ]]; then
  echo "Usage: $0 <provider-name>" >&2; exit 1
fi
```

The `TACTICAL HACK` block is mandatory. The unit test asserts its presence
so the annotation cannot be silently stripped.

### 5.2 Delete step

```bash
DEPLOY=$(kubectl get deploy -n "${NAMESPACE}" \
  -l "pkg.crossplane.io/provider=${PROVIDER}" \
  -o name 2>/dev/null | head -1)

if [[ -z "$DEPLOY" ]]; then
  echo "[reset] No Deployment found for '${PROVIDER}'. Nothing to delete."
  exit 0
fi

kubectl delete "${DEPLOY}" -n "${NAMESPACE}" --wait=false
echo "[reset] Deleted ${DEPLOY}. Waiting for Crossplane to re-render..."
```

`--wait=false` mirrors PR #68 exactly. The Crossplane controller is the
authoritative reconciler; kubectl `--wait` would block on deletion
completing, not on Crossplane recreating the resource.

### 5.3 Wait condition — verify pod re-rendered with new SA

The step absent from PR #68. After the delete, the script polls until:
(1) a new pod for the provider is `Running`, AND
(2) its `spec.serviceAccountName` matches the expected SA name.

```bash
EXPECTED_SA=$(kubectl get deploymentruntimeconfig "${PROVIDER}" \
  -o jsonpath='{.spec.serviceAccountTemplate.metadata.name}' 2>/dev/null \
  || echo "")
[[ -z "$EXPECTED_SA" ]] && EXPECTED_SA="upbound-${PROVIDER}"
echo "[reset] Expected ServiceAccount: ${EXPECTED_SA}"

ELAPSED=0; INTERVAL=5
while (( ELAPSED < TIMEOUT )); do
  POD=$(kubectl get pods -n "${NAMESPACE}" \
    -l "pkg.crossplane.io/provider=${PROVIDER}" \
    --field-selector=status.phase=Running \
    -o name 2>/dev/null | head -1)
  if [[ -n "$POD" ]]; then
    ACTUAL_SA=$(kubectl get "${POD}" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null || echo "")
    if [[ "$ACTUAL_SA" == "$EXPECTED_SA" ]]; then
      echo "[reset] ${POD} Running with SA '${ACTUAL_SA}'. Reset complete."
      exit 0
    fi
    echo "[reset] Pod up but SA='${ACTUAL_SA}' (want '${EXPECTED_SA}'). Waiting..."
  else
    echo "[reset] No Running pod (${ELAPSED}s). Waiting..."
  fi
  sleep "${INTERVAL}"; (( ELAPSED += INTERVAL ))
done

echo "[reset] TIMEOUT after ${TIMEOUT}s. Investigate:" >&2
echo "  kubectl get pods -n ${NAMESPACE} -l pkg.crossplane.io/provider=${PROVIDER}" >&2
exit 1
```

**Wait semantics:** poll every 5s up to 120s. A fresh provider pod
typically starts in 15–30s on EKS with a warm image cache; 120s covers a
cold OCI pull. Exit 0 only when both conditions hold — prevents the caller
from proceeding with a pod still on the wrong identity.

**SA-name derivation:** reads `DeploymentRuntimeConfig.spec.serviceAccountTemplate.metadata.name`.
Falls back to `upbound-<provider>` if the DRC is absent or unpinned. The
fallback may be wrong for non-Upbound providers; the mismatch will be
caught by the wait loop's SA comparison, producing a non-zero exit and a
diagnostic hint rather than a silent success.

**Idempotency:** if no matching Deployment exists, the script exits 0 with
an informational message. Safe to call as a precaution before any
provider-touching apply.

**Performance:** delete is sub-second; wait loop adds at most `TIMEOUT`
seconds. Typically completes in ~20s. Not suitable for tight CI loops.

---

## 6. Tests required (per AGENTS.md §6.1)

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_crossplane_reset_provider.sh` | No-arg invocation exits non-zero and prints "Usage:" to stderr. |
| Unit | same | `shellcheck -S error scripts/crossplane-reset-provider.sh` exits 0. |
| Unit | same | `test -x scripts/crossplane-reset-provider.sh` passes (executable bit set). |
| Unit | same | `grep -q "TACTICAL HACK" scripts/crossplane-reset-provider.sh` passes (workaround annotation present). |
| Unit | same | Script body contains literal string `pkg.crossplane.io/provider=` (correct label key). |

No cluster required for unit tests. Integration and e2e layers (§7) cover
the actual delete-and-wait behavior.

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

All in `/home/user/k8-platform/tests/unit/test_crossplane_reset_provider.sh`.
Fast, no cluster. The five cases in §6 are the gate; additional cases:

1. **TIMEOUT env override** — invoke with `TIMEOUT=0` and a fake provider
   name pre-configured in a mock `kubectl` stub; assert exit 1 and the
   "TIMEOUT" message in stderr.
2. **Idempotent no-Deployment path** — stub `kubectl get deploy` to return
   empty; assert exit 0 and "Nothing to delete" in stdout.

### Integration

File: `/home/user/k8-platform/tests/integration/14_crossplane_reset_provider.sh`.
Requires a kind or EKS cluster with Crossplane installed.

1. **Happy path** — with a test provider Deployment present and a
   `DeploymentRuntimeConfig` specifying a pinned SA, run the script and
   assert it exits 0 and the new pod's SA matches the DRC value.
2. **Already-absent Deployment** — no Deployment present; assert exit 0
   and "Nothing to delete" message (idempotency).
3. **SA name match** — verify `kubectl get pod … -o jsonpath='{.spec.serviceAccountName}'`
   equals the DRC-pinned value after script exits 0.
4. **Timeout path** — invoke with `TIMEOUT=1`; assert exit 1 and "TIMEOUT"
   in stderr without hanging longer than ~5s.

The integration tests should be run against a dev cluster only — the
script performs a destructive Deployment delete.

### E2E

**Not applicable for chainsaw.** The script is an imperative runbook step;
chainsaw's assert/apply loop cannot safely delete a provider Deployment
inside a test run without destabilizing other scenarios in the same
cluster. The integration layer covers the behavioral contract. If a future
"provider health recovery" chainsaw scenario class is introduced, this
script becomes the `script:` step body at that point.

---

## 8. Documentation updates

- `/home/user/k8-platform/AGENTS.md` — add a short subsection (§8.2 or
  extend §8) titled "Provider Deployment staleness": *"When a
  `DeploymentRuntimeConfig` change does not propagate to a running provider
  pod, run `scripts/crossplane-reset-provider.sh <provider>` before opening
  another PR. See `retrospective/2026-05-25-70.md` Phase 2."*

- `/home/user/k8-platform/scripts/README.md` — add one row:
  `crossplane-reset-provider.sh <provider>` | Delete and wait for re-render
  of a provider Deployment. Runbook for DRC-change propagation.

- `/home/user/k8-platform/ai/handoff.md` — in the Bug 3 fix steps (lines
  77–97), after step 6 add: *"If the provider pod is still running with the
  old SA after apply, run `scripts/crossplane-reset-provider.sh
  provider-family-aws` (and similarly for `provider-aws-secretsmanager`)."*

---

## 9. Workflow / auto-invocation wiring

This script is **purely manual** — a runbook tool, not an automated step.
It must not be wired into pre-commit hooks or CI workflows:

1. Deleting a running Deployment is a destructive cluster mutation requiring
   a conscious operator decision.
2. The stale-SA condition has no cheap automated detector that can safely
   gate on it without risking false positives.

The `crossplane-claim-verify` skill may surface "run
`scripts/crossplane-reset-provider.sh`" as a suggested remediation when
it detects an SA-name mismatch pattern. That extension is out of scope here.

---

## 10. Discoverability

1. **Mechanical enforcement — shellcheck in unit CI.** The unit test runs in
   `tests/unit/run.sh`, fired by `.github/workflows/unit-tests.yml` on every
   push. An edit removing the `TACTICAL HACK` annotation or breaking
   shellcheck compliance fails CI red, making the workaround intent visible
   at review time.

2. **Documentation pointer — AGENTS.md §8 + handoff.md.** An agent reading
   the Bug 3 fix instructions in `ai/handoff.md` sees the reset-provider
   step explicitly. The AGENTS.md addition ensures any agent encountering
   "provider pod running with wrong SA" finds the script without reading the
   full retro.

3. **Adversarial-review trigger — §6.4.** Add to `ai/testing-guidelines.md`
   §6.4 checklist: *"For any PR modifying a `DeploymentRuntimeConfig` or
   bumping a provider version: confirm the agent ran
   `scripts/crossplane-reset-provider.sh` post-apply and verified the new
   pod is Running with the expected SA."*

---

## 11. Verification checklist

After implementing this spec, the agent runs:

- [ ] `test -x /home/user/k8-platform/scripts/crossplane-reset-provider.sh`
  exits 0 (script exists and is executable).
- [ ] `shellcheck -S error /home/user/k8-platform/scripts/crossplane-reset-provider.sh`
  exits 0.
- [ ] `bash /home/user/k8-platform/scripts/crossplane-reset-provider.sh 2>&1; echo "exit:$?"`
  includes "Usage:" in output and `exit:1`.
- [ ] `grep -c "TACTICAL HACK" /home/user/k8-platform/scripts/crossplane-reset-provider.sh`
  returns ≥ 1.
- [ ] `grep -c "pkg.crossplane.io/provider=" /home/user/k8-platform/scripts/crossplane-reset-provider.sh`
  returns ≥ 1.
- [ ] `bash /home/user/k8-platform/tests/unit/test_crossplane_reset_provider.sh`
  exits 0 with a PASS line per assertion.
- [ ] `grep -c "crossplane-reset-provider" /home/user/k8-platform/scripts/README.md`
  returns ≥ 1.
- [ ] `grep -c "crossplane-reset-provider" /home/user/k8-platform/AGENTS.md`
  returns ≥ 1.
- [ ] `grep -c "crossplane-reset-provider" /home/user/k8-platform/ai/handoff.md`
  returns ≥ 1.
- [ ] `bash /home/user/k8-platform/tests/unit/run.sh` exits 0 (new unit
  test integrates cleanly with the existing bundle).

---

## 12. Rollout notes

- **Backward compatible.** Purely additive — a new script and a new unit
  test. No existing behavior is changed.
- **Audit-before-merge.** No existing file is in violation of a new lint
  rule; the unit test passes on the first run because the script it tests
  is created in the same PR.
- **Pluralsight sandbox constraints** (us-east-1/us-west-2, t-class only,
  ≤9 instances, no Bedrock/Marketplace) — not relevant. The script runs
  `kubectl` against whatever cluster is current; no AWS API calls, no cloud
  resources created.
- **Coordination.** Preferred sequencing: land this script before the Bug 3
  version-bump PR so the fix branch can reference and invoke it. If Bug 3
  lands first, add this script immediately after as a chore PR.
- **Branch sequencing.** No dependency on other Tier A specs; can be
  implemented at any time on a standalone branch.

---

## 13. Estimated effort

**S** — approximately 1–1.5 hours total.

Breakdown: script authoring (~30 min, patterns lifted directly from PR #68
and the retro narrative, no design uncertainty); unit test (~20 min, five
static-analysis assertions, no cluster); documentation edits (~15 min,
three small edits); rollout audit and `tests/unit/run.sh` verification
(~10 min); optional live-cluster smoke test during the Bug 3 session
(~15 min). The load-bearing risk is the SA-name fallback heuristic: if
`DeploymentRuntimeConfig` is absent, the `upbound-<provider>` guess may
be wrong for non-Upbound providers. That risk is bounded by the wait
loop's SA comparison — a wrong guess produces a non-zero exit with a
diagnostic message, not a silent success.
