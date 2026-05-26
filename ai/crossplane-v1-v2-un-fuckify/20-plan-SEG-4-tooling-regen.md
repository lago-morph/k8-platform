# 20 — SEG-4 plan: tooling regeneration

**Segment:** SEG-4 (kubeconform schema store + diagnostic scripts +
fixtures + PR #94 goldens).
**Author:** opus implementation-architect
**Status:** plan; consumed by the executor PR(s) for this segment.

## 1. Scope

Files this plan owns. Counts are the inventory the segment must touch
end-to-end:

| Group | Path(s) | Count | Touch type |
|---|---|---|---|
| Schema store | `kubeconform-schemas/{secretsmanager,ec2,eks,iam}.aws.upbound.io/` and 4 new `.m.upbound.io` siblings | 53 JSON files (regen) + ~9 new files | delete-and-regenerate |
| Schema fetcher | `scripts/fetch-crds-for-kubeconform.sh` | 1 | edit (URL pins + XRD reader) |
| Trace script | `scripts/crossplane-trace.sh` | 1 | edit (bug fix L215 case-branch) |
| Trace fixtures | `tests/unit/fixtures/crossplane-trace/{mr-ok,mr-access-denied,mr-failing-long,xr-ok,xr-with-mrs,xr-12-refs}.json` | 6 | edit (17 apiVersion strings) |
| Kubeconform fixtures | `tests/unit/fixtures/kubeconform/{should_pass_composition,should_fail_string_transform_no_type,should_fail_unknown_field,multi_doc_first_valid_second_invalid,should_pass_skip_header}.yaml` | 5 | edit (apiVersion + v1 fields) |
| Composition-render fixture | `tests/unit/fixtures/composition-render/composition-missing-string-type.yaml` | 1 | edit (apiVersion + drop v1 fields) |
| Render-fixture XR inputs | `crossplane/xrds/{platform-secret,platform-cluster}/render-fixtures/input.yaml` | 2 | conditional rewrite (see §6) |
| Render goldens | `crossplane/xrds/*/render-fixtures/expected.yaml` | 0 (bootstrap mode today) | generate net-new |
| Diag script | `scripts/diag-component.sh` | 1 | edit (jsonpath + grep + CRD probe) |
| Composition-render script | `scripts/composition-render.sh` | 1 | review-only (no v1 strings; depends on regenerated inputs) |
| PR #94 goldens | `tests/chainsaw/platform-secret/{00,01,02}/expected/asm-secret.yaml` (on branch `origin/claude/auto-run-2026-05-25-phase-2-C4`) | 3 (×3 fields each = 9 edits) | regenerate from live chainsaw |
| PR #94 meta-test | `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml` | 1 | edit (kubectl group string) |

Out of scope (owned by other segments): production XRDs/Compositions
under `crossplane/` (SEG-1); Terraform (SEG-2); the unit/integration/
chainsaw scripts themselves (SEG-3, except the C4 meta-test which
co-lives with the C4 goldens).

## 2. Migration approach

### 2.1 Strategy summary

The schema-store regen is the **hinge** of this segment — every fixture
update and every golden regen wants to validate against the new schemas,
and there's no point editing fixture `apiVersion` strings before the
schema store knows the new groups exist.

Two viable paths to obtain v2 CRDs:

| Path | Cost | Coverage | Determinism | Verdict |
|---|---|---|---|---|
| (a) Live v2 cluster (kind + provider apply, or hit a real dev cluster) | high (need a running provider, AWS creds for ProviderConfig) | complete — every installed CRD captured incl. transitive deps | depends on what's installed at scrape time | reject for first cut |
| (b) Pinned upstream CRD YAMLs (the `CRD_URLS` array in `fetch-crds-for-kubeconform.sh`) | low (`curl` only, no cluster) | exactly what we list | byte-deterministic — URLs are immutable refs | **adopt** |

Path (b) is cleaner: the fetch script already supports it as a fallback,
the pinned-URL approach is what the schema store has always actually
been built from in CI, and v2.5.4 provider-family-aws ships the v2 CRDs
under the `.m.upbound.io` group at the same upstream repo
(`crossplane-contrib/provider-upjet-aws`) just at a new tag. We bump
the URL pins from `v1.12.0` → `v2.5.4` and the script does the rest.

Live-cluster mode (path a) is preserved as an opt-in escape hatch (the
fetch script auto-detects `kubectl version`), so anyone with a real v2
cluster can regenerate from it. But CI and the canonical store both run
from the pinned URLs.

### 2.2 Per-area approach

**Schema store.** Bump `CRD_URLS` pins to v2.5.4 (replace `v1.12.0` →
`v2.5.4` and `.upbound.io_` → `.m.upbound.io_` in the URL path
segment). Bump function-patch-and-transform pin to v0.10.6 (the same
version PR #98 puts in `versions.env`). Run the fetch script. **Delete
the four old `*.aws.upbound.io/` schema directories** (53 files) — they
will reappear with `.m.` infix if we don't actively prune. Commit the
new schemas plus the deletion in one PR.

**Fetcher XRD-reader fix.** Lines 196–222 read `spec.claimNames.kind`
from each XRD to also write the claim's schema. In v2 XRDs there is no
`claimNames` — the XR is the user-facing kind. Simplify the loop to
emit only the XR kind. Drop the `(x_kind, claim_kind)` tuple iteration.

**crossplane-trace.sh bug fix (L215).** The case glob
`secretsmanager.aws.upbound.io|*.aws.upbound.io|aws.upbound.io` doesn't
match `.m.upbound.io` groups (the `.m.` infix breaks the glob), so the
PROVIDER and IRSA layers silently disappear for any v2 MR. **This is a
code bug, not a regen.** Replace with a pattern that matches both:

```bash
case "$group" in
  *.aws.upbound.io|aws.upbound.io|*.aws.m.upbound.io|aws.m.upbound.io)
    echo "upbound-provider-family-aws" ;;
```

Keep v1 alternatives in the case for two reasons: (1) defensive — a
fresh-cluster trace might still observe a stale v1 CRD before the v2
provider drops them; (2) the unit-test fixtures cover both shapes after
the regen so the case must accept both.

**Trace JSON fixtures.** Six files, all `secretsmanager.aws.upbound.io
/v1beta1` → `secretsmanager.aws.m.upbound.io/v1beta1`. The mock kubectl
shim dispatches on `kind_lc/name` not apiVersion, so no shim change is
needed (per 13-impact-test-infra §test_crossplane_trace).

**Kubeconform fixtures.** Five fixture YAMLs that exercise the meta-
test paths. Apply the apiVersion bump *and* drop v1 fields
(`deletionPolicy`, bare `providerConfigRef: name:` without `kind:`)
where present, otherwise the regenerated schemas will reject them via
the meta-test's `should_fail_unknown_field.yaml` (unknown-field
rejection now triggers on the wrong field).

**composition-render meta-test fixture.** Apply the same bump
(apiVersion + drop `deletionPolicy` + add `kind: ClusterProviderConfig`
to `providerConfigRef`). The fixture's purpose is to verify
`crossplane render` exits non-zero on a missing
`string transform type` — that bug is API-group-independent, but the
fixture must not fail earlier for unrelated v1 reasons.

**Render-fixture XR inputs (`crossplane/xrds/*/render-fixtures/input.yaml`).**
These use `platform.k8-platform.io/v1alpha1` for the XR — that's our
own group, not an AWS group, so the apiVersion itself is unchanged.
But they may need rewriting depending on what SEG-1 does to the XRD
spec:
- If SEG-1 removes `claimRef` from the spec (because the XR is itself
  the user-facing namespaced object), drop the `spec.claimRef:` block.
- If SEG-1 makes the XR namespaced, add `metadata.namespace: default`.
- The `metadata.uid` pin stays — it's the load-bearing reproducibility
  hack.

This is a **hard coordination point with SEG-1**: this segment can't
finalize the input.yaml shape until SEG-1 lands the XRD migration.
Easiest sequencing: SEG-1 lands first, this segment rebases on top.

**Render goldens (`expected.yaml`).** Currently none exist (the
helper is in bootstrap mode). SEG-1's XRD changes will determine the
render output shape. Once SEG-1 + this segment's input.yaml rewrite
are merged, run `scripts/composition-render.sh --all` against the v2
manifests, redirect the output into per-fixture `expected.yaml`, and
commit. **This is the right time to create the goldens** — bootstrap
mode is what the helper was designed for.

**diag-component.sh.** Three v1 patterns:
- L64: CRD probe list contains `secrets.secretsmanager.aws.upbound.io`
  → change to `.m.upbound.io`.
- L59–60: probes `platformsecrets` / `xplatformsecrets` claim+XR pair
  — under v2 only `xplatformsecrets` exists (no claim CRD). Drop the
  `platformsecrets.platform.k8-platform.io` probe.
- L94–95: jsonpath `.spec.resourceRef.name` for XR lookup — v2 has no
  `spec.resourceRef` on the XR (it IS the user-facing object). Replace
  the claim→XR walk with a direct `kubectl get xplatformsecret -n
  $CLAIM_NS $CLAIM_NAME`. Same rewrite applies to L99–106.
- L105: `kubectl get secrets.secretsmanager.aws.upbound.io` → `.m.`.

This is a script edit, but it's small enough to ride with the
schema-store regen PR.

**PR #94 goldens.** Three `expected/asm-secret.yaml` files contain
`apiVersion: secretsmanager.aws.upbound.io/v1beta1`, `deletionPolicy:
Delete`, and `providerConfigRef: name: default`. The v2 live MR will
have `.m.upbound.io`, no `deletionPolicy`, and `providerConfigRef:
{name: default, kind: ClusterProviderConfig}`. These goldens were
originally captured by running real chainsaw against real AWS (per the
spec) so the regen must do the same: run the C4 chainsaw scenarios
against a v2 cluster on a fresh AWS account, dump the resulting MR
status, hand-trim volatile fields per the spec's normalization rules,
re-commit. This is the **highest-effort and highest-risk task in the
segment** because it blocks on the full v2 stack working end-to-end
(SEG-1 + SEG-2 + SEG-3 all green).

**composition-drift meta-test (PR #94).** Single edit:
`kubectl get secret.secretsmanager.aws.upbound.io` →
`kubectl get secret.secretsmanager.aws.m.upbound.io`. Rides with the
golden regen PR.

### 2.3 Dependency DAG

```mermaid
flowchart TD
  subgraph A["Prereq from outside SEG-4"]
    SEG1["SEG-1: XRD/Composition v2 migration<br/>(XR namespaced, .m.upbound.io groups)"]
    PR98["PR #98: versions.env bump<br/>provider v2.5.4, fn-pt v0.10.6"]
    SEG3["SEG-3: chainsaw scripts updated<br/>(spec.resourceRef walk gone)"]
  end

  subgraph B["SEG-4 work"]
    direction TB
    URLs["Step 1: bump CRD_URLS to v2.5.4<br/>+ fix XRD reader (drop claimNames branch)<br/>scripts/fetch-crds-for-kubeconform.sh"]
    Store["Step 2: regenerate schema store<br/>delete *.aws.upbound.io/ dirs (53 files)<br/>run fetch-crds-for-kubeconform.sh<br/>commit new *.aws.m.upbound.io/ dirs"]
    TraceFix["Step 3a: crossplane-trace.sh L215 case-branch fix<br/>(BUG, not regen)"]
    DiagFix["Step 3b: diag-component.sh<br/>CRD probe + jsonpath + grep updates"]
    Fixtures["Step 4: fixture regen<br/>6 trace JSON + 5 kubeconform YAML +<br/>1 composition-render YAML"]
    RenderInputs["Step 5a: rewrite render-fixture input.yaml<br/>(only if SEG-1 changed XR shape)"]
    RenderGoldens["Step 5b: generate expected.yaml goldens<br/>composition-render.sh --all > expected.yaml"]
    C4Meta["Step 6a: composition-drift kubectl group fix<br/>(PR #94 branch)"]
    C4Goldens["Step 6b: REGENERATE PR #94 asm-secret goldens<br/>requires chainsaw green vs real AWS<br/>(PR #94 branch)"]
  end

  SEG1 --> URLs
  PR98 --> URLs
  URLs --> Store
  Store --> Fixtures
  Store --> TraceFix
  TraceFix --> Fixtures
  SEG1 --> RenderInputs
  Store --> RenderInputs
  RenderInputs --> RenderGoldens
  SEG1 --> C4Goldens
  SEG3 --> C4Goldens
  Store --> C4Goldens
  C4Meta --> C4Goldens

  classDef ext fill:#fee,stroke:#c66
  classDef hinge fill:#ffd,stroke:#aa3,stroke-width:3px
  classDef risk fill:#fdd,stroke:#a33,stroke-width:2px
  class SEG1,PR98,SEG3 ext
  class Store hinge
  class C4Goldens risk
```

### 2.4 Suggested PR slicing

| PR | Contents | Depends on |
|---|---|---|
| **PR-T1** "schema store regen + script fixes" | fetch-crds-for-kubeconform.sh URL bumps + XRD reader simplification; regenerated schema store (delete old, add new); crossplane-trace.sh L215 fix; diag-component.sh updates; all 6 trace JSON fixtures; all 5 kubeconform fixtures; composition-render meta-test fixture | PR #98 merged; SEG-1 manifest changes available on a branch (the schemas don't depend on production manifests, only on the URL pins) |
| **PR-T2** "render-fixture inputs + goldens" | crossplane/xrds/*/render-fixtures/input.yaml rewrites; first-time expected.yaml goldens | SEG-1 merged; PR-T1 merged |
| **PR-T3** "C4 golden regen" (on `origin/claude/auto-run-2026-05-25-phase-2-C4`) | 3 asm-secret.yaml goldens regenerated from live chainsaw; composition-drift kubectl-group fix | SEG-1, SEG-2, SEG-3, PR-T1 all merged; chainsaw green on fresh AWS account |

## 3. Open questions

1. **Cross-segment seam with SEG-1: does the namespaced XR keep
   `spec.claimRef`?** v2 namespaced XRs technically don't need it (the
   XR's own namespace == the user's namespace). If SEG-1 drops
   `claimRef` from the XRD spec, the render-fixture input.yaml must
   drop it too, and Composition patches reading `spec.claimRef.namespace`
   change to a literal or to a `metadata.namespace` reference. Need
   confirmation from SEG-1's plan.

2. **Does `provider-family-aws` v2.5.4 actually publish CRDs at
   `secretsmanager.aws.m.upbound.io_secrets.yaml` in the repo at tag
   `v2.5.4`?** The migration guide says yes, but the URL path needs
   verification before committing the bump (one `curl -I` per URL would
   confirm). If the path scheme differs (e.g. CRDs moved to a
   sub-directory under the new group), the URL builder logic in the
   fetch script needs more than a sed.

3. **Does the v2 ProviderConfig CRD ship under the family-aws package or
   a separate sub-package?** This matters for the URL list — if it's
   separate we need a 13th URL for ProviderConfig schema (currently
   none — ProviderConfig was always pulled from the cluster, not the
   schema store).

4. **For PR #94 goldens: who owns the chainsaw run?** This segment owns
   the file edits, but the actual chainsaw run requires AWS creds and
   the full SEG-1/2/3 stack working. If SEG-3 includes the chainsaw run
   as part of its acceptance, the PR-T3 work might just be "diff the
   output of the SEG-3 run into committed goldens." Coordinate.

5. **Do we keep both v1 *and* v2 schemas in the store during a
   transition period?** Risk: a stale Composition still references the
   v1 group during the migration, kubeconform happily validates against
   the v1 schema, the audit misses the staleness. Recommendation: hard
   cutover — delete v1 schema dirs in PR-T1, accept that any in-flight
   PR touching v1 manifests will go red until rebased.

## 4. Failure recovery

| Failure | Recovery |
|---|---|
| `fetch-crds-for-kubeconform.sh` returns 404 on the new v2 URLs (provider repo path scheme changed) | Manually inspect `https://github.com/crossplane-contrib/provider-upjet-aws/tree/v2.5.4/package/crds`, update the URL template in the fetch script. If the structure is fundamentally different (e.g. per-resource sub-packages), regenerate via path (a) — spin up a kind cluster, `kubectl apply` the provider, scrape live CRDs. |
| Regenerated schemas reject a previously-passing v2 manifest with `additionalProperties false` (the `harden_schema` transformation is too aggressive for some v2 shape) | Add the offending path to the `x-kubernetes-preserve-unknown-fields: true` opt-out list inside the original CRD, OR loosen the converter at the specific node. The transformation is load-bearing (it catches Bug 1 typos) so don't remove it wholesale. |
| `crossplane render` against v2 Compositions/XRDs fails with `function input rejected` or `unknown field` (function-pt v0.10.6 has stricter validation than v0.8.2) | Bisect with the Composition diff in isolation. The render-fixture inputs are minimal so the failure is usually in the Composition itself (SEG-1 scope) — kick back to SEG-1. |
| Chainsaw run for PR #94 goldens passes locally but the captured MR shape differs from CI's run (region, account ID, UID leak) | Re-confirm the chainsaw normalization (the spec lists exactly which fields to strip: uid, resourceVersion, creationTimestamp, ownerReferences, managedFields, status). If a new field leaks through, extend the normalization script in `composition-render.sh` and re-capture — the two specs share a normalizer. |
| crossplane-trace.sh L215 fix introduces a regression for the v1 fixture tests (now both v1 and v2 should map to the same provider) | The case-branch keeps both alternatives, so v1 fixtures still resolve `upbound-provider-family-aws`. Unit tests should be green. If they go red, the unit test is asserting on a path that doesn't go through the case branch — investigate the failure. |
| Schema-store regen produces a different directory layout than expected (e.g. v2 CRDs have a different `spec.group` than just `.m.` prefix) | The fetch script derives the directory from `spec.group` directly, so whatever the CRD declares is what we get. If a Composition uses a different group than the CRD declares, kubeconform will skip — surface this early with a `find kubeconform-schemas -type d` diff in the PR. |

## 5. Hot files

Files most likely to change repeatedly during execution (avoid stacking
two open PRs that both touch them):

1. `scripts/fetch-crds-for-kubeconform.sh` — touched by PR-T1; any
   subsequent provider/version bump will re-touch it. Single owner: this
   segment.
2. `kubeconform-schemas/**` — regenerated by PR-T1, can be re-regen'd
   by any future schema-affecting PR. Treat as generated; never
   hand-edit.
3. `scripts/crossplane-trace.sh` — line 215 only; rest of the script is
   stable. Conflicts unlikely.
4. `tests/chainsaw/platform-secret/{00,01,02}/expected/asm-secret.yaml`
   — lives on the PR #94 branch; will conflict with anything else that
   branch carries.
5. `crossplane/xrds/*/render-fixtures/input.yaml` — first edit in this
   segment + first edit ever by SEG-1 if SEG-1 changes XR shape.
   Sequence carefully.

## 6. Cross-segment dependencies

| From | To | Why |
|---|---|---|
| **SEG-1** → **SEG-4** (PR-T2, PR-T3) | hard | render-fixture inputs and PR #94 goldens depend on the actual production XRD/Composition v2 shape |
| **SEG-2** → **SEG-4** (PR-T3) | hard | C4 golden regen needs a working v2 cluster, which requires SEG-2's IRSA / management-cluster Terraform updates |
| **SEG-3** → **SEG-4** (PR-T3) | hard | chainsaw scripts must be updated to v2 idioms (no `spec.resourceRef` walk) before chainsaw can run green to produce goldens |
| **PR #98** → **SEG-4** (PR-T1) | hard | sets the canonical v2.5.4 / v0.10.6 version strings the fetch script reads |
| **SEG-4 PR-T1** → **SEG-3** | weak | SEG-3's unit tests will validate against the new schema store; if SEG-3 lands first against the old store, the new schemas may cause test churn |
| **SEG-4 PR-T1** → **SEG-1 verification** | weak | SEG-1 manifest authors will want to run `test_kubeconform_manifests.sh` locally against the new store to validate their changes; PR-T1 enables that loop |

## 7. Estimated execution time

| Step | Engineer-time | Wall-clock | Notes |
|---|---|---|---|
| 1. URL pin bump + XRD reader fix in fetch script | 30 min | 30 min | small edit, one verification curl per URL |
| 2. Schema store regen (run fetch script, delete old dirs, commit ~62 files) | 30 min | 30 min | mechanical |
| 3a. crossplane-trace.sh L215 bug fix | 15 min | 15 min | trivial; unit tests already cover the case |
| 3b. diag-component.sh updates | 30 min | 30 min | 3 distinct edits + manual smoke |
| 4. Fixture regen (12 files) | 1 hr | 1 hr | mechanical edits + run unit tests |
| **PR-T1 subtotal** | **2.75 hr** | **2.75 hr** | one PR, single reviewer |
| 5a. Render-fixture input.yaml rewrites | 30 min | depends on SEG-1 wall-clock | blocked until SEG-1 merges |
| 5b. Generate expected.yaml goldens | 30 min | 30 min | `composition-render.sh --all` + commit |
| **PR-T2 subtotal** | **1 hr** | **+ SEG-1 wait** | sequence after PR-T1 |
| 6a. composition-drift kubectl group fix | 10 min | 10 min | one line |
| 6b. C4 asm-secret golden regen (chainsaw against real AWS) | 1 hr edit + 30 min chainsaw + 30 min normalization | 2–4 hr (kind cluster bootstrap + AWS creds + chainsaw scenarios 00/01/02 each run ~5 min) | **highest risk** — flake-prone |
| **PR-T3 subtotal** | **2 hr** | **2–4 hr + SEG-1/2/3 wait** | on PR #94 branch |
| **Segment total** | **~5.75 hr** | **~6 hr** plus blocking on other segments | three PRs, mostly serial |

The wall-clock is dominated by waiting on SEG-1 (manifest migration) and
the AWS chainsaw flake risk. The pure-edit work is < 6 hours of focused
time.
