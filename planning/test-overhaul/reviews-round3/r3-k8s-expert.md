# Round-3 Adversarial Review — k8s/Crossplane Mechanism Correctness

**Reviewer persona:** unit+integration testing expert, deep K8s/Crossplane + cluster-admin.
**Target:** `planning/test-overhaul/FINAL-PLAN.md` (round-1 + round-2 resolved; both corrections applied).
**Method:** read cold and full; every load-bearing K8s/Crossplane/IRSA claim re-checked against the tree this session.
**Verdict in one line:** the IRSA/identity/v2/Pipeline mechanics are now *substantially correct* and the plan is honest about the v2 composed-ref spike risk — but **correction #2 ("the trigger is the BUILD, not CI") is built on a repo fiction**: there is no build/bring-up procedure separate from CI. `apply-and-verify` is a `workflow_dispatch` action *inside* `terraform-test.yml`. That single error mis-frames the entire execution-context model and the "one residual operator dependency."

---

## What the plan got RIGHT (verified — must not be lost)

These are correct against the tree and are the spine; do not let any later edit erode them:

- **`source: IRSA`, not `InjectedIdentity`.** `crossplane/providerconfig/00-clusterproviderconfig.yaml` — `kind: ClusterProviderConfig`, group `aws.m.upbound.io/v1beta1`, `spec.credentials.source: IRSA`. Verified. The §3.2 identity gate keying on the exact string `IRSA` (not the unfailable "IRSA or InjectedIdentity") is correct and falsifiable.
- **v2 namespaced XRDs, no claim.** All four `crossplane/xrds/*.yaml` are `apiextensions.crossplane.io/v2`, `scope: Namespaced`, `claimNames: null`. Verified. The v1-claim-shaped `crossplane-claim-verify` port (§9.1) is a genuine prerequisite, not optional.
- **claim-verify is v1-shaped.** `SKILL.md:57` captures `spec.resourceRef.name` on a *claim*; `:81` descends `{range .spec.resourceRefs[*]}`; Phase 1 does `kubectl get <claim-kind>`. On a v2 XR this walks zero MRs. Verified — the "green light over stuck children" hazard is real.
- **EKS authnMode is hardcoded, not XR-driven.** `crossplane/compositions/platform-cluster.yaml:320` is a literal `authenticationMode: API_AND_CONFIG_MAP` in the MR base with no patch from the XR and no XRD field. The §7 / §13-row-1 decision to make this a **composition-text `yq` lint, not an admission negative**, is correct — there is genuinely no field to set to `CONFIG_MAP`, so no rejection path exists.
- **`run.sh` skip-is-green is real.** `tests/integration/run.sh:26-45` counts `exit 2` as SKIP and `exit 0`s whenever `FAIL==0`. All-skipped reads green. The inverted-skip / `all-skip ⇒ RED` / reserved-exit-3 contract (§4.4) is the right fix.
- **All policies are Audit.** 11 ClusterPolicies under `policies/audit/`, every one `validationFailureAction: Audit` (plan says 12 — minor miscount, see Minor-1). The refusal to blanket-mandate `Enforce` + `failurePolicy:Fail` (§7) is correct and outage-aware.

---

## CRITICAL

### C1 — "The trigger is the BUILD, not CI" is a distinction without a referent. `apply-and-verify` IS a CI workflow action.
The entire correction-#2 recast (§4.1, §10, §17.3, §18) rests on the premise that there exists a **build/bring-up procedure distinct from GitHub Actions** into which `tests/live/run.sh` can be wired as a "final phase," and that this is *not* CI. **There is no such thing in this repo.**

Verified: `apply-and-verify` is a value of the `action` `workflow_dispatch` input of `.github/workflows/terraform-test.yml` (`terraform-test.yml:24`; the `[management] e2e-verify` step runs on `action=apply-and-verify`, :235/:315). It reaches the cluster via `aws eks update-kubeconfig --name k8-platform-mgmt` **on the GitHub Actions runner** (:329). Every other apply-and-verify reference in the repo (`ai/brainstorming/specs/SPEC-C3`, `SPEC-LC2`, `SPEC-S5`) treats it as a `terraform-test.yml` dispatch. There is no `scripts/apply-and-verify.sh`, no Makefile bring-up target, no operator runbook script — `grep` finds only the workflow action and spec prose referring to it.

Consequences the plan's three-context model gets wrong:
- **Context 2 ("build-time, NOT CI") and context 3 ("workflow_dispatch") are the same place.** "The build invokes `tests/live/run.sh`" concretely means *adding a step to `terraform-test.yml`'s `apply-and-verify` job* — which is a `workflow_dispatch` GitHub Actions workflow. The plan's own §6.7-citation says cluster-requiring work is `workflow_dispatch`-only; the build-coupled suite IS that. So the plan simultaneously says "build-time is not CI" and "cluster work is workflow_dispatch-only CI" — these collapse into one context, and the prose insisting they are "three strictly-separate execution contexts" (§18.2) is false.
- **The "on by default ⇒ every bring-up" guarantee weakens to "on every `apply-and-verify` *dispatch*."** That is exactly the property the plan claims correction #2 *fixed* relative to "coupled to whoever remembers to dispatch" (§4.3). It did not fix it; it renamed the dispatch. A human/agent still has to fire `terraform-test.yml action=apply-and-verify`. There is no git event, no reconcile event, that auto-runs the live suite.

**Fix:** Drop the fiction that build-time ≠ CI. State plainly: the live suite is a **step added to the `apply-and-verify` job of `terraform-test.yml`** (a `workflow_dispatch` workflow), gated so it runs on `action=apply-and-verify` and is skipped on `action=plan`/`verify`-readonly. Keep the genuinely-correct properties (on-by-default value as a tested invariant; all-skip⇒RED; expect-full-from-git; `verify⇒readonly`). The honest "every bring-up" guarantee is: *every `apply-and-verify` dispatch runs the live suite by default, and a static push lint asserts the step is present in `terraform-test.yml` and on-by-default.* That is real and deliverable; the "it's the build not CI" framing is not — it should be deleted, not defended.

### C2 — The §4.5 deriver fixture-oracle does NOT match the §4.5 extraction command (the WARN-ONLY gate will never go green as written).
The plan's exact extraction command (§4.5, verified working this session) is:
```
yq '.spec.pipeline[]?.input.resources[]? | select(.base) | .base.apiVersion + "/" + .base.kind'
```
Its real output (run against all four comps this session) is **group/version/kind**:
```
iam.aws.m.upbound.io/v1beta1/Role
eks.aws.m.upbound.io/v1beta1/Cluster
rds.aws.m.upbound.io/v1beta1/Instance
...
```
But the "verified MR set the deriver must reproduce" (§4.5 fixture oracle, and the whole §13 matrix) is written as **group/kind**, version dropped: `iam.aws.m.upbound.io/Role`, `eks.aws.m.upbound.io/Cluster`, `rds.aws.m.upbound.io/Instance`. The command emits `…/v1beta1/Role`; the oracle expects `…/Role`. **The fixture-test the plan mandates as the gate-on-green will fail against the command the plan mandates as the extractor.** Since the deriver ships WARN-ONLY *until that fixture-test is green* (§4.5, a stated must-not-weaken), the deriver would be stuck WARN-ONLY forever — i.e. never actually gating — which silently re-opens the "hand-manifest gets edited green" disease the deriver exists to kill.

This is also a correctness trap on its own merits: keying the registry on group/kind while the providers expose `apiVersion: …/v1beta1` means a future v1beta2 bump of any AWS MR changes the extractor output (`…/v1beta2/Role`) but not the registry key — a silent coverage miss exactly when a provider upgrade is the riskiest moment.

**Fix:** Pick ONE key shape and make command + oracle + registry agree. Recommend keying on **group + kind** (version-independent, survives provider bumps), which means the extraction command must strip the version: `… | .base.apiVersion | sub("/.*";"") + "/" + .base.kind` (i.e. group from `apiVersion` before the `/`, then kind). Re-run it against the four comps and paste the *actual* group/kind set as the fixture oracle. Add a unit assertion that the extractor output and the committed oracle are byte-identical, so this drift can't recur.

---

## MAJOR

### M1 — The spoke kube-API is PUBLIC-access-enabled; the "private-CA spoke API, one residual operator dependency" (§14.2, §12) is mis-diagnosed.
`crossplane/compositions/platform-cluster.yaml:328-329` sets the spoke EKS `vpcConfig.endpointPublicAccess: true` (and `endpointPrivateAccess: true`). So the spoke API has a **public endpoint**. The plan's repeated framing — that the curl/behavioral e2e is blocked because CI must reach a *private-CA spoke API* (§10, §14.2, §13 rows 1/6/8, residual-risk #2) — conflates two different things:
- **The sandbox** cannot reach *any* EKS kube-API: the strict-MITM egress gateway can't verify the EKS private CA (AGENTS §6.27). True, and unfixable from the sandbox.
- **A GitHub Actions runner** reaches the mgmt EKS API *today* via `aws eks update-kubeconfig` (integration-tests.yml:74, terraform-test.yml:329) — it bypasses the sandbox gateway entirely. With `endpointPublicAccess: true`, the same runner can reach the **spoke** API the same way, subject only to the public-access CIDR allowlist (and the app-controller AssumeRole/AccessEntry the blockers are about).

So the "spoke-API-from-CI" dependency is **probably already satisfied** (it's the same mechanism that runs all 13 integration tests), and the real gate is whether the public-access CIDR allowlist admits the runner's egress IP — a config question, not the architectural blocker the plan paints. By over-stating it as the lone residual dependency, the plan risks deferring behavioral #1/#6 (the two spoke blockers — 6 of 8 blockers live on the spoke) to a "conditional, maybe never" lane that didn't need deferring.

**Fix:** Re-state §14.2 as: "the spoke API is public-access-enabled (`platform-cluster.yaml:329`); CI reaches it via `aws eks update-kubeconfig` exactly as the integration suite reaches mgmt today. The real precondition is (a) the runner egress IP is in the spoke's public-access CIDR allowlist, and (b) an AccessEntry/AssumeRole path for the CI identity. Verify both at spike time." Demote from "the one genuine residual operator dependency" to "a CIDR/AccessEntry config check." This *strengthens* the plan — it un-strands the two highest-value blockers.

### M2 — `scripts/wait-for-claim.sh` does NOT descend composed MRs; reusing it as a "walk the real MRs" primitive (§3.1, §9.1) is overstated.
The plan repeatedly pairs the v2-ported claim-verify with `scripts/wait-for-claim.sh` as the verify primitive that confirms the composed MRs reconciled under IRSA. Verified: `wait-for-claim.sh` polls only `.status.conditions[type=Ready].status == True` on the **single named object** (header :7, loop :90, exits 0 on top-level Ready :94). It walks nothing. A v2 XR can report `Ready=True` while a child MR is `Synced=False` mid-reconcile *iff* readiness gating is misconfigured — and more importantly, wait-for-claim alone gives you exactly the "XR Ready, children unknown" blind spot the v2 port is supposed to close. The only thing in the toolbox that descends children is the (broken-on-v2) claim-verify Phase 3.

**Fix:** State that wait-for-claim is the *top-level readiness wait only*; the **composed-MR enumeration is solely the responsibility of the v2-ported claim-verify Phase 3**, and that port is the load-bearing new code (not a "reuse existing asset"). The §9.1 caveat ("verify the actual field on the running cluster at spike time — v2 surfaces refs under `spec.crossplane.resourceRefs`/`status` depending on version; do NOT assume `spec.resourceRefs`") is correct and must stay; add that wait-for-claim cannot substitute for it.

### M3 — How composed MRs are enumerated on a v2 XR is unproven, and the plan's two hints are mutually exclusive without saying which.
This is the heart of the persona question ("how are composed MRs enumerated?") and the plan is right to flag it as the #1 spike risk (§14.1) — but it offers `spec.crossplane.resourceRefs` *and* `status` as alternatives "depending on version" without committing. For modern Crossplane v2 (the repo is on a v2.x line per AGENTS §8.2 "v2.5.0"), composed resource refs on a namespaced XR are exposed at **`spec.crossplane.resourceRefs`** (the v2 relocation of the old top-level `spec.resourceRefs`); `status` carries conditions, not the ref list. If the spike author tries `status.resourceRefs` first they'll get empty and may wrongly conclude "no children," masking exactly the failure mode the port targets.

**Fix:** Make the P0 spike's *first* assertion explicit: enumerate via `kubectl get <xr-kind>/<name> -n <ns> -o jsonpath='{.spec.crossplane.resourceRefs[*]}'`, and only if empty fall back to probing `status`/`spec.resourceRefs`, recording which one the live cluster actually uses as a pinned fact in the spike output. The deriver's group/kind set (C2, now corrected) is the oracle for *which* MRs must appear in that ref list — wire the spike to assert the enumerated refs ⊇ the derived kinds, so "Ready but children missing" reds.

### M4 — `verify ⇒ readonly` is asserted as a unit test, but `terraform-test.yml` has no `verify` action wired to the live suite — the guard guards nothing yet.
§4.1 mandates `LIVE_MODE=mutating|readonly` with `verify ⇒ readonly` and a unit test asserting it, "so an agent's frequent `verify` calls never provision NLBs/IAM/secrets." But `terraform-test.yml`'s action enum is `plan`/`apply-and-verify`/`destroy` (and `verify` appears only in the `e2e-verify` step name and a `RUN_MODE` mapping at :505/:232). There is no `action=verify` that invokes `tests/live/run.sh`. The unit test on the mapping is fine, but the *binding* (which action passes which `LIVE_MODE`) lives in workflow YAML the plan must actually author, and the plan's §12 ledger lists that wiring as "build-flow wiring" — which (per C1) is workflow YAML. Without pinning the action→LIVE_MODE binding in the workflow and unit-testing *that file*, the guarantee is a string-comparison test over a config the running workflow may not honor.

**Fix:** Specify the exact `terraform-test.yml` mapping: `action=apply-and-verify ⇒ LIVE_MODE=mutating`; any read-only verify action (add one if needed) ⇒ `LIVE_MODE=readonly`. The §4.4 `phase=test` unit suite should assert this against the *workflow file*, not only against the orchestrator's internal default, mirroring AGENTS §6.16 (`run.sh` ↔ `unit-tests.yml` sync) which the plan already leans on.

---

## MINOR

- **Minor-1 — policy count.** Plan says "All 12 repo policies are Audit" (§7); there are 11 ClusterPolicies under `policies/audit/` (the 12th file is a README). Claim direction (all Audit) is correct; fix the number so a reader doesn't hunt a phantom policy.
- **Minor-2 — `xdatabase` base set.** Plan (§4.5, §17.14) says xdatabase has only `rds…/Instance` (no SubnetGroup). Verified — the composition base is a single `Instance`. Correct; keep. (Flagging only because a real RDS in a custom VPC usually needs a DBSubnetGroup; if one is expected to exist it's created elsewhere/by Terraform — worth a one-line note so the AFTER-THE-FACT RDS check doesn't assume a composed subnet group that isn't there.)
- **Minor-3 — exclude-list defends against pollution that the verified command already excludes.** The §4.5 named exclude-list (`ClusterProviderConfig`, `ClusterSecretStore`, `Input`, `Resources`, `Composition`) is belt-and-suspenders: the `select(.base)` + `.input.resources[]` path structurally cannot emit any of them (verified — clean output, no pollution). Fine to keep as defense, but the plan should say it's redundant-by-construction so an implementer doesn't think the bare command is unsafe without it.
- **Minor-4 — `external-secrets.io/ExternalSecret` is keyed group/kind into a "non-AWS lane."** Correct (it's an ESO CR, no IAM action). But note ExternalSecret *Ready* depends on the `ClusterSecretStore` + the underlying ASM secret + the provider IRSA — so the "no IAM action to simulate" routing is right for the *coverage/ceiling* lane but the *behavioral* check on ExternalSecret still transitively exercises IRSA. One line to avoid an implementer treating the non-AWS lane as "no IRSA involvement."

---

## What must NOT be lost (carry forward verbatim)
1. The **`source: IRSA` exact-string identity gate + no-static-cred + provider-Healthy** triad (§3.2), and the refusal of the unfailable "IRSA or InjectedIdentity" either-or. This is the falsifiable core; it is correct against the tree.
2. **Drive-the-real-controller as the only completeness oracle for unknown-missing-actions**; simulate is a floor (§3.3). The kind/admin-cred chainsaw masks the whole blocker class — do not let it creep back.
3. **claim-verify v2 port is a hard prerequisite** (§9.1) and **the v2 composed-ref enumeration is the #1 spike risk** (§14.1) — keep both; M3 only sharpens the enumeration path.
4. **all-skip ⇒ RED, expect-full-from-git (not self-report), reserved exit 3** (§4.3/§4.4) — the anti-silent-green spine.
5. **No new AssumeRole principal / no probe pod / no trust widening** (§3.1 NON-GOAL).

## Net assessment
The K8s/Crossplane *mechanism* layer is now correct where it matters most (IRSA identity, v2/no-claim, Pipeline-mode extraction, hardcoded-authnMode-is-a-lint, claim-verify-is-broken-on-v2). The two things that will actually bite an implementer are **C1** (the build-vs-CI framing has no referent; it's a renamed dispatch, and the plan must stop claiming otherwise) and **C2** (the deriver's own gate can't go green as written, so the deriver never gates). **M1** is a free win — the spoke API is public, so the highest-value blockers aren't as stranded as the plan fears. Fix C1/C2, apply M1–M4, and the plan is mechanically sound.
