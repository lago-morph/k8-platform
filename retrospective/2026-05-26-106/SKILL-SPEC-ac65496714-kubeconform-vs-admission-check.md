# Spec: `kubeconform-vs-admission-check`

- **ID**: SKILL-SPEC-ac65496714
- **Source retrospective**: ../2026-05-26-106.md

## Intent

When migrating Crossplane manifests to a new major API version, the static kubeconform JSON schema may accept fields that the live admission webhook rejects (e.g., v2 XRDs accept `connectionSecretKeys` in the schema but reject it at admission). Dispatch a live chainsaw apply against the branch SHA before relying on kubeconform-only validation for v2-shape correctness.

## Trigger

**Direct**: "is this v2 manifest valid?", "did kubeconform catch everything?", "do I need a live apply check before merging this XRD?"

**Proactive**: When a PR modifies `crossplane/xrds/*.yaml` or `crossplane/compositions/*.yaml` across a major API-version boundary (e.g., changes `apiextensions.crossplane.io/v1` to `/v2`, or renames `*.aws.upbound.io` to `*.aws.m.upbound.io`), AND kubeconform passes, the skill should activate to recommend a live chainsaw dispatch before merge.

**Negative**: Skip when the diff is purely additive to an existing major version (e.g., new schema field on a v1 XRD with no API-version change). Skip for compositions/render-fixture-only PRs that don't touch XRDs.

## Inputs

- Current branch (must be pushed)
- Commit SHA of the branch HEAD
- Whether `chainsaw.yml` workflow exists and is dispatchable

## Outputs

- A green chainsaw run (specifically the `xrd-establishes` scenario at minimum) cached on the commit SHA
- Or: a clear failure log identifying the live admission rejection that kubeconform missed
- Updated PR description with the verified chainsaw run URL

## Workflow

1. Verify the PR touches XRD/Composition files: `git diff main..HEAD --name-only | grep -E 'crossplane/(xrds|compositions)/'`.
2. If kubeconform CI is already green on the PR: still dispatch chainsaw — the whole point is that kubeconform passing isn't sufficient.
3. Capture `SHA=$(git rev-parse HEAD)`.
4. Dispatch `chainsaw.yml` against `BRANCH` with `commit_sha=$SHA` and `scenario_filter=""` (full set) OR `scenario_filter="_smoke xrd-establishes"` for a fast minimum gate.
5. Poll the dispatched run until terminal. Use `terraform-ci-watch` pattern.
6. On failure: fetch the chainsaw stdout via ext-github `op_c08d23e5bd6966cb` per testing-guidelines §10 BEFORE forming hypotheses. Common failure shapes:
   - `is invalid: spec: Invalid value: ...` — admission rejected a field the static schema accepted. Fix the manifest.
   - `kubectl wait --for=condition=Offered timed out` — v1-era condition assertion on a v2 XRD. Fix the scenario.
   - `no matches for kind PlatformSecret` — v1 claim kind in a v2 cluster. Rewrite to `X<Kind>` (v2 XR kind).
7. On success: paste the run URL into the PR description under "§6.7 chainsaw contract" so the chainsaw-verify check can find it.
8. Only THEN consider the PR ready to merge.

## Concrete examples

### Example 1 — the `connectionSecretKeys` rejection (2026-05-26)

The SEG-1 subagent confirmed `connectionSecretKeys` was valid on a v2 XRD using the regenerated kubeconform schema (`kubeconform-schemas/apiextensions.crossplane.io/compositeresourcedefinition_v2.json` accepts the field). Wave 2 PR #104 merged green. After merge, chainsaw `xrd-establishes` against the post-Wave-2 SHA failed with:

```
CompositeResourceDefinition.apiextensions.crossplane.io "xplatformclusters.platform.k8-platform.io"
is invalid: spec: Invalid value: "object": XR connection secrets aren't supported in
apiextensions.crossplane.io/v2
```

**The skill's effect**: had this been dispatched before merging PR #104, the failure would have surfaced pre-merge. Hotfix PR #105 was opened to remove the field. Net cost of skipping the skill: one extra hotfix PR + 2 chainsaw iterations.

### Example 2 — the `vpcConfig[0]` array→object change (caught locally)

The same SEG-1 subagent ran kubeconform locally against the regenerated v2.5.0 schemas and discovered `vpcConfig[0].subnetIds` (v1 array form) was rejected because the v2 `.m.upbound.io` CRD changed it to `vpcConfig.subnetIds` (single object form). The subagent fixed it before pushing. **This is the kubeconform-catches case** — the new v2 schema disagreed with the v1 manifest shape because the schema field structure actually changed. Schema-based check works here. The `connectionSecretKeys` case (Example 1) was different: the schema didn't change; the admission webhook added handler logic that the schema can't express.

## Anti-patterns

- **Treating kubeconform green as "v2 ready to merge"** when the PR crosses a major API-version boundary. The static schema can lag the admission webhook's rejection logic.
- **Dispatching chainsaw smoke-only** for an XRD migration PR. `_smoke` doesn't apply the XRD; you must include `xrd-establishes` or full set.
- **Skipping the §10 log-fetch on chainsaw failure**. The chainsaw stdout names the exact admission error verbatim. Hypothesizing without it wastes iteration loops.

## Acceptance criteria

1. The skill activates only on PRs that touch XRD or Composition files across a major API-version boundary.
2. The skill produces a dispatchable command (workflow_dispatch via `gh` or `ext-github`) targeting the branch SHA.
3. On failure, the skill fetches and surfaces the relevant chainsaw stderr block (not the full log) per testing-guidelines §10.
4. On success, the skill updates the PR body with a chainsaw run URL referencing the SHA.
5. The skill does NOT block merge automatically; it surfaces the gate and lets the operator merge.

## Files this skill creates / modifies

- The PR body (appended chainsaw run URL under `§6.7 chainsaw contract`).
- No files created on disk; the chainsaw run is the artifact, cached in GitHub Actions logs.
