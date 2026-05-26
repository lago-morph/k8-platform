# 30 — SEG-4 review R1A: EXECUTION + SEQUENCING

**Reviewer angle:** PR slicing, schema-regen hinge, golden ordering,
trace-bug independence, render-fixture coordination.
**Verdict:** REVISE-MINOR

## Strengths

- DAG correctly identifies the schema store as the hinge and isolates
  PR-T1 from SEG-1's manifest churn (schemas come from upstream URLs,
  not from in-repo manifests).
- crossplane-trace.sh L215 fix is cleanly factored out of regen and the
  case-branch preserves the v1 alternative — the right call given
  v1 fixtures still exist on PR-T1's branch.
- PR-T3 is correctly placed last, on the C4 branch, behind
  SEG-1/2/3+chainsaw-green. No attempt to capture goldens prematurely.

## Flaws

1. **URL-scheme assumption is unverified and gates everything.** §2.2
   commits to `v1.12.0` → `v2.5.4` + `.upbound.io_` → `.m.upbound.io_`
   in the URL path but only flags verification as Open Question #2.
   This is the literal first action of PR-T1 and an unmerged provider
   may publish CRDs under a different file naming convention (per-
   service sub-package, monorepo split, or kept-as-`.upbound.io_`
   filename with `.m.` only in `spec.group`). Action: a `curl -I`
   matrix on all 7 URLs must be Step 0 of PR-T1, BEFORE the executor
   touches the script. The plan ought to elevate Q2 to a pre-flight
   gate.

2. **PR-T1 silently depends on SEG-1's kubeconform fixture choices.**
   PR-T1 edits `tests/unit/fixtures/kubeconform/*.yaml` to drop
   `deletionPolicy` and add `kind: ClusterProviderConfig`, but
   SEG-1 §3 Q2 still has `ClusterProviderConfig` vs namespaced
   `ProviderConfig` open. If SEG-1 picks namespaced, PR-T1's fixtures
   are wrong on day one. Fix: either pin the decision now in the
   review, or defer the kubeconform-fixture edits to PR-T2 (which
   already waits for SEG-1).

3. **PR-T2 ordering is fragile.** The plan says "SEG-1 merged →
   PR-T2." But SEG-1's drain+cutover is a single PR that touches
   `crossplane/xrds/*/render-fixtures/input.yaml` indirectly (via the
   ArgoCD include-glob tightening). If SEG-1 lands without moving the
   fixtures out of `crossplane/`, PR-T2 can land safely; if SEG-1
   takes Open-Q4's "move fixtures to `tests/`" path, PR-T2's file
   paths are stale before it opens. Coordinate with SEG-1 review now.

4. **T2 cannot land before T1** (correctly serialized) but the plan
   never says PR-T1 itself can land WITHOUT SEG-1. It can and should
   — schemas are URL-derived. Make this explicit; PR-T1 unblocks
   SEG-1 authors who want to lint locally.

5. **Trace bug fix is correctly independent** of regen and could
   theoretically ship in its own micro-PR ahead of PR-T1. Plan bundles
   it; acceptable, but flag as separable for emergency hot-fix.

## Required revisions

- Promote Open Q2 to a pre-flight gate with explicit `curl -I` matrix.
- Pin Open Q2 cross-segment (`ClusterProviderConfig` vs namespaced) or
  move kubeconform fixture edits to PR-T2.
- State explicitly: PR-T1 does not block on SEG-1.
