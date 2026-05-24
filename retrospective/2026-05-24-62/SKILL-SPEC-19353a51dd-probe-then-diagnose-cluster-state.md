# Spec: `probe-then-diagnose-cluster-state`

- **ID**: SKILL-SPEC-19353a51dd
- **Source retrospective**: ../2026-05-24-62.md

## Intent

When the agent needs to know "is this thing actually working on the cluster?" but has no direct kubectl/API access, the cheapest reliable answer is: apply a throwaway probe resource, wait, dump all relevant state, clean up. Faster than re-running a full apply-and-verify, more informative than checking individual statuses one at a time.

Grounded in: `phase-2-diagnose.yml` (PR #60) probe step. Applied a throwaway `PlatformSecret` claim, slept 90s, dumped the claim status + composite XR + describe + provider logs + ESO logs + ExternalSecret + ASM-tag scan, then cleaned up. The dump immediately surfaced Bug 4's exact error message (`string transform type is required`) which had been invisible across five chainsaw failures.

## Trigger

**Direct user phrases:**
- "Diagnose [system]"
- "What's wrong with [resource type]?"
- "Why doesn't [X] work?"

**Proactive triggers:**
- Before consuming a ~15-min apply-and-verify cycle on a system the agent suspects is broken
- After N (≥2) similar failures with insufficient signal
- When a resource is reported `Ready=False` with `reason=Waiting` (i.e., the resource is waiting for *something downstream* that the diagnostic chain doesn't surface)

**Negative triggers:**
- Bugs already root-caused with clear evidence (no diagnostic needed)
- Production cluster with sensitive data (probe-claims may create real resources costing real $$)

## Inputs

- The XRD / CRD / kind under test (e.g., `PlatformSecret`, `ExternalSecret`)
- A throwaway namespace name (e.g., `diag-probe-$(date +%s)`)
- A minimal claim manifest for the kind
- An adequate wait period (≥90s for Crossplane composite XRs; ≥30s for ESO refresh)
- The cleanup scope (what to delete and when)

## Outputs

- A single workflow run log containing:
  - Pre-probe cluster state (apps, providers, ClusterSecretStore, CRDs)
  - The probe claim's status YAML
  - The composite XR's status (including conditions[].message — usually the smoking gun)
  - Describe output on the managed resources the composite tries to render
  - Controller logs (tail-N) for the providers that should be reconciling
  - Any related ESO ExternalSecrets + their conditions
  - Cleanup confirmation

## Workflow

1. **Author a read-mostly workflow** (`.github/workflows/diagnose-<system>.yml`) with `workflow_dispatch` only, no inputs (or minimal).
2. **Add pre-flight steps**: AWS sts get-caller-identity, kubectl update-kubeconfig, kubectl get nodes — fail fast if cluster unreachable.
3. **Add an "applications + providers + CRDs" inventory step.** Dump `kubectl get application -n argocd -o custom-columns`, `kubectl get provider.pkg.crossplane.io -o name`, etc.
4. **Add a probe step:**
   ```bash
   PROBE_NS="diag-probe-$(date +%s)"
   kubectl create ns "$PROBE_NS"
   kubectl apply -f - <<'YAML'
   <minimal claim>
   YAML
   sleep 90  # tunable per resource class
   ```
5. **Dump the claim → composite → managed resources chain.** Especially the composite XR's `status.conditions[].message` (Crossplane puts the actual error here).
6. **Dump controller logs (tail-80)** for every provider/function/ESO pod relevant to the chain.
7. **Cleanup** (`kubectl delete ns "$PROBE_NS" --wait=false`) — don't block the workflow on cleanup.
8. **Dispatch and read** per `dispatch-then-poll-then-readlog`. If the log is too big use `subagent-log-extraction`.

## Concrete examples

### Example 1 — phase-2-diagnose.yml (the session's real artifact)

[Live in main as `.github/workflows/phase-2-diagnose.yml`](../../.github/workflows/phase-2-diagnose.yml). The probe step applies a `PlatformSecret` claim, waits 90s, dumps claim YAML + XR YAML + describes + ASM managed Secret + ExternalSecret + provider-aws-secretsmanager logs + crossplane core logs. Output surfaced:

> `cannot compose resources: pipeline step "patch-and-transform" returned a fatal result: invalid Function input: resources[0].patches[0].transforms[0].string.type: Required value`

— that one line root-caused 5+ prior chainsaw failures.

### Example 2 — debug a stuck ExternalSecret (hypothetical follow-up)

Author `.github/workflows/diagnose-eso-sync.yml`. Probe: apply an ExternalSecret pointing at a known ASM key with refreshInterval=15s. Sleep 30s. Dump:
- `kubectl describe externalsecret …` → look at `.status.refreshTime` and `.status.conditions[].reason`
- `kubectl logs -n external-secrets …` → look for `unable to fetch from secrets manager`
- `aws secretsmanager describe-secret --secret-id …` → confirm secret exists in AWS

Cleanup the ExternalSecret + namespace. Read the log. Root-cause.

## Anti-patterns

- **Probe in a real-data namespace.** Always create a fresh throwaway namespace.
- **Probe a resource that costs >$$$ to create.** Don't probe PlatformCluster (EKS) this way — too expensive. Use a smaller proxy or don't probe.
- **Skip cleanup.** Leaves leak. Always `kubectl delete ns` even if cleanup fails (use `|| true`).
- **Wait too short.** Composite XRs take 30-90s to settle even on success. Wait 90s minimum.
- **Wait too long.** Beyond 5min the probe pollutes the log and may hit workflow timeouts.
- **Dump everything globally.** Scope to the probe's namespace + the providers relevant to the chain. Cluster-wide dumps drown the signal.

## Acceptance criteria

1. The workflow file has `workflow_dispatch:` only (no `push:` or schedule).
2. The workflow has `permissions: contents: read` (read-only).
3. The probe runs in a fresh, timestamped namespace.
4. Cleanup runs even on failure.
5. The dump includes the composite XR's `status.conditions[].message` for Crossplane-backed kinds.
6. Logs are tail-bounded (e.g., `kubectl logs --tail=80`) to keep the artifact size sane.

## Files this skill creates / modifies

- `.github/workflows/diagnose-<system>.yml` — one per system being diagnosed.
- (Optional) `ai/diagnostics-catalog.md` — index of diagnose workflows + what each surfaces.
