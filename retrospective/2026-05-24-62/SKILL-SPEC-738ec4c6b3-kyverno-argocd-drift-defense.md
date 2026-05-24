# Spec: `kyverno-argocd-drift-defense`

- **ID**: SKILL-SPEC-738ec4c6b3
- **Source retrospective**: ../2026-05-24-62.md

## Intent

When ArgoCD manages Kyverno ClusterPolicies (or any resource whose controller mutates the spec after admission), the policy will drift `OutOfSync` perpetually because Kyverno's defaults arrive after ArgoCD's apply. The fix is to set the mutated fields explicitly in the source manifest so the controller has nothing to add — OR, as a fallback, add ArgoCD `ignoreDifferences` for those JSON paths.

Grounded in: phase-2-diagnose run 26348711132 revealed `crossplane-resources` Application's only OutOfSync resource was `ClusterPolicy/platform-secret-namespace-allowed`. The session DID NOT fix this; it was documented in the handoff as a follow-up. Bug 3.

## Trigger

**Direct user phrases:**
- "Why is X OutOfSync?"
- "Fix the ArgoCD drift"
- "Authoring a Kyverno policy for GitOps"

**Proactive triggers:**
- About to commit a new ClusterPolicy under any ArgoCD-synced path
- ArgoCD app stays OutOfSync with `selfHeal: true` for a Kyverno-managed kind
- Editing an existing ClusterPolicy whose ArgoCD app drifts

**Negative triggers:**
- Policies applied directly by Terraform (e.g., the 8 policies in `policies/audit/`) — not ArgoCD-synced, drift detection is N/A
- Other Kyverno resource kinds the agent isn't familiar with (escalate)

## Inputs

- The ClusterPolicy YAML being authored
- The ArgoCD Application that syncs it
- (Optional) Diagnostic output showing the specific drifted fields

## Outputs

- A ClusterPolicy with all known Kyverno-defaulted fields set explicitly
- (Optional) ArgoCD app with `ignoreDifferences` for genuinely-uncontrollable fields
- A unit test asserting the explicit-fields pattern

## Workflow

1. **Diagnose first.** Don't guess what Kyverno is adding. Dispatch a workflow that does `kubectl get clusterpolicy <name> -o yaml > live.yaml` and `cat crossplane/policies/<name>.yaml > source.yaml`; `diff` them. The diff IS the drift.

2. **Known Kyverno-injected fields** (at time of this skill authoring; verify against your diff):
   - `spec.background: true` (default-fills when absent)
   - `spec.admission: true` (default-fills when absent)
   - `spec.validationFailureAction: Audit` (default differs across versions — pin explicitly)
   - annotation `pod-policies.kyverno.io/autogen-controllers: <list>` (autogen adds rules for Pod controllers; suppress with `none`)

3. **Set every diffed field explicitly in the source manifest.** Don't rely on defaults.

4. **Author or extend a unit test** at `tests/unit/test_kyverno_policy_no_drift.sh` that scans `crossplane/policies/*.yaml` and asserts each field is explicitly set. Per `tdd-lint-bug-class`.

5. **Verify the fix** by re-dispatching the diagnostic workflow and reading `.status.sync.status` on the ArgoCD app — must read `Synced`.

6. **Fallback (only if explicit fields aren't enough):** add `ignoreDifferences` on the ArgoCD app YAML. Warning: hides future drift in the named paths, including legitimate diffs. Use as last resort.

   ```yaml
   spec:
     ignoreDifferences:
       - group: kyverno.io
         kind: ClusterPolicy
         jsonPointers:
           - /spec/background
           - /spec/admission
   ```

## Concrete examples

### Example 1 — the actual Bug 3 (not fixed in this session; documented for next agent)

**Diagnostic output:** `crossplane-resources` Application OutOfSync with one resource: `ClusterPolicy/platform-secret-namespace-allowed`. Kyverno-side defaulting suspected.

**Fix path** (per handoff Step 5):
1. Re-diagnose to enumerate the exact drifted fields.
2. Edit `crossplane/policies/09-platform-secret-namespace-allowed.yaml` to explicitly set `spec.background: true`, `spec.admission: true`, and add annotation `pod-policies.kyverno.io/autogen-controllers: none`.
3. Add lint `tests/unit/test_kyverno_policy_no_drift.sh`.
4. Verify via `phase-2-diagnose.yml` re-dispatch.

### Example 2 — proactive new ClusterPolicy authoring (hypothetical next addition)

**Setup:** authoring `crossplane/policies/10-platform-cluster-region-restricted.yaml`.

**Author with the pattern:**
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: platform-cluster-region-restricted
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    pod-policies.kyverno.io/autogen-controllers: none   # explicit
spec:
  validationFailureAction: Audit   # explicit
  background: true                  # explicit (Kyverno default = true)
  admission: true                   # explicit (Kyverno default = true)
  rules:
    - name: allowed-regions
      match:
        any:
          - resources:
              kinds: [PlatformCluster]
      validate:
        message: "spec.region must be one of: us-east-1, us-west-2"
        deny:
          conditions:
            ...
```

No drift on first sync.

## Anti-patterns

- **Author a Kyverno policy without setting `background`/`admission` explicitly** — guaranteed drift.
- **Reach for `ignoreDifferences` first** — explicit fields are GitOps-clean; ignoreDifferences hides future drift including legitimate.
- **Fix one drift without lint** — the bug class returns the next time you author a policy.
- **Diagnose by guessing** — the diff command takes 30 seconds; guess-and-check takes hours.

## Acceptance criteria

1. Every ClusterPolicy under ArgoCD-synced paths sets `background`, `admission`, `validationFailureAction` explicitly.
2. Every ClusterPolicy whose rules don't target Pods sets the `pod-policies.kyverno.io/autogen-controllers: none` annotation.
3. A lint at `tests/unit/test_kyverno_policy_no_drift.sh` enforces (1) and (2).
4. After applying this pattern, the ArgoCD app's `.status.sync.status` reads `Synced` on the next refresh.

## Files this skill creates / modifies

- `crossplane/policies/*.yaml` — the policies themselves
- `tests/unit/test_kyverno_policy_no_drift.sh` — the new lint
- (Conditional) `argocd/apps/crossplane-resources.yaml` — ignoreDifferences if needed
