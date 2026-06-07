# FINAL Test-Overhaul Plan — k8s-platform

> **Status: PLAN ONLY.** This document creates and edits no code, tests,
> fixtures, or workflows. It is the authoritative finalization of a multi-round
> process: 3 source plans → 9 round-1 reviews → `synthesis/SYNTHESIZED-PLAN.md`
> → 5 round-2 adversarial reviews → two constraint corrections
> (`CONSTRAINT-CORRECTION.md` = workflows are editable;
> `CONSTRAINT-CORRECTION-2.md` = cluster work is `workflow_dispatch`-only, never
> push/PR) → 5 round-3 adversarial reviews
> (`reviews-round3/r3-{sre,security,devx,k8s-expert,qa-guru}.md` — authoritative).
> It folds every round-3 CRITICAL into one spec. Where reviewers disagreed, this
> document picks and justifies.
>
> **Round-3 reframed the execution model and it is now correct against the tree.**
> All five round-3 reviewers independently grounded the same decisive fact: there
> is **no build executor separate from CI.** The bring-up IS
> `terraform-test.yml action=apply-and-verify` — a `workflow_dispatch` (manual)
> GitHub Actions run that reaches the kube-API via `aws eks update-kubeconfig` on
> the runner (terraform-test.yml:90,329) under the admin AWS keys (:41-43). The
> earlier "build ≠ CI" framing (correction #2 as prose) **had no referent and is
> deleted.** The two — and only two — real Actions surfaces are: **(a) push/PR
> (automatic) = STATIC, no-cluster checks only; (b) `workflow_dispatch` (manual) =
> the apply-and-verify job + ad-hoc runs, where the full live suite runs as a STEP
> added to the apply-and-verify job in `terraform-test.yml`.** This still satisfies
> correction #2 (cluster work is `workflow_dispatch`-only, never push/PR). Because
> the live surface is therefore a *manual* dispatch, "on by default" cannot rest on
> a UI dropdown default; it is made mechanical by a **fail-closed live-evidence
> gate** on push/PR (below) — the round-3 spine fix.
>
> Every load-bearing repo claim here was re-verified against the tree this
> session (file:fact cited inline; note `compute-gates.sh` lives at
> `.github/scripts/compute-gates.sh`). Author: lead test architect.

---

# PART I — EXECUTIVE SUMMARY (for the repo owner)

**The disease.** The current suite proves manifests *say* X, never that X
*works*. `tests/unit/*.sh` are `yq`/`grep`/`helm template` lints over committed
YAML/TF. `tests/chainsaw/**` runs on kind with a fake cloud or, worse, with the
GitHub-Actions **admin** keys — *more* privilege than production. The one empty
cell is **real cloud × the restricted Crossplane identity**, and that is exactly
where auto-012 paid for **8 live blockers, found one at a time** (OI-2026-06-07-6).
Compounding it: `skip()`=`exit 0` and `tests/integration/run.sh` exits 0 whenever
`FAIL==0` (verified, run.sh:40-45) — so on a rotated/empty account *everything
skips and reads green*.

**The spine (non-negotiable, survives verbatim).** Behavioral verification by
**driving the REAL Crossplane provider controller under its real IRSA identity**
(`source: IRSA`), with create-and-verify **coupled to the change**, **on by
default**, where **all-skipped ⇒ RED**. "On by default" and "coupled to the
change" are now made **MECHANICAL by a fail-closed live-evidence gate** (see
below), not by a UI dropdown default. **"On by default" is an anti-forgetting
DEVELOPMENT safety net** (correction #3): while a component is under active
development we must not be able to forget to verify what we built — so the
default is the `full` PROFILE. **"Disable" is a PROFILE selector, not a binary
switch** (`full` / `verify-only` / `off`, §4.2): a proven, working component can
be moved to `verify-only` to keep its routine bring-up cheap (the cheap
after-the-fact checks only), without forfeiting on-by-default — `full` re-arms
automatically when the component changes. Cost split: **after-the-fact** read-only
checks for the expensive standing things (EKS ~20 min, RDS), **instantiate-and-
verify** for the cheap hermetic things. A hard **security NON-GOAL**: no new
AssumeRole principal, no trust-policy widening, no provider-SA token mount, no
probe pod. Reuse existing assets: `crossplane-claim-verify` (after a mandatory
v2 port), `scripts/wait-for-claim.sh` (top-level readiness wait **only** — it
descends nothing; the v2-ported claim-verify Phase 3 is the sole composed-MR
enumerator), `scripts/irsa_trust_validator.py`, chainsaw per-run-ID prefix +
cleanup.

**The "on by default" spine, made mechanical — the FAIL-closed live-evidence gate
(the round-3 centerpiece).** Because the only live surface is a *manual*
`workflow_dispatch` of `terraform-test.yml action=apply-and-verify`, a UI dropdown
default cannot guarantee "every bring-up." The enforcement that makes "on by
default" and "coupled to the change" mechanical is **a push/PR static gate that
FAILS (not WARN) unless an unforgeable, fresh live-evidence record exists** for the
`(deployed-config-SHA × account-id × cluster-name)` triple. This single mechanism
resolves three round-3 criticals together — (i) "build≠CI is empty," (ii) "on by
default = a UI default with no teeth," and (iii) **config-only GitOps changes get
ArgoCD-synced to the live cluster with no apply-and-verify and thus no
verification.** Round-2→round-3 wrongly demoted this gate to WARN; it is **restored
to FAIL** (and §18 is corrected: that demotion *did* weaken on-by-default). Four
interlocking parts:
1. **The gate (push/PR, FAIL-closed).** Evidence is a GitHub Actions **run-ID
   cross-check**: the push gate calls the Actions API (the repo's existing
   `.github/workflows/chainsaw-verify.yml` pattern) to confirm an `apply-and-verify`
   run for the deployed-config SHA **exists**, has `conclusion=success`, ran against
   **this account-id and cluster-name**, and is **newer than the account's
   bootstrap**. It is **not** a self-attested committed marker an engineer can
   hand-write. No fresh green run for the `(SHA × account × cluster)` triple ⇒ the
   push gate is **RED**. This is the *only* place "the suite never ran" can be turned
   red — it lives **outside** the suite, so a non-invoked suite (a `verify`-only or
   bare-`apply` dispatch, a crash before the final phase, a config-only ArgoCD sync)
   is caught.
2. **Config-only GitOps changes are first-class, not a footnote.** A PR that edits
   `crossplane/**` / `policies/**` (the exact auto-012 change shape — a
   Composition/IAM/tag edit ArgoCD will sync to the live hub with **no**
   apply-and-verify dispatch) FAILS the same gate unless fresh green live-evidence
   exists for the resulting config-SHA. This closes the hole where a config-only
   change reconciles onto the live cluster verified by nothing. The first apply for
   a fresh/rotated account has no prior marker by construction: that is treated as
   `expect-full`-from-git (RED, "run the build"), never green-by-absence.
3. **On-by-default teeth inside the job:** the live-verify step is gated on
   `mgmt_apply` (not only `mgmt_verify`), so **any management apply triggers verify**
   — a bare `action=apply` can no longer bring up the cluster with zero verification.
   The build's success is gated on the suite's **exit code** (a static lint forbids
   `tests/live/run.sh || true`, backgrounding, or an `if:` that can silently exclude
   the step — AGENTS §6.19). A `verify`-only (readonly) dispatch still applies the
   `expect-full` floor, so it cannot read green having verified nothing.
4. **The marker's integrity contract (so the gate is not itself self-attested):**
   the run-ID is machine-emitted by the apply-and-verify step **only on the §4.4
   clean-pass exit code** (never on `exit 2` skip / `exit 3` expect-full violation /
   all-skip), keyed on `(SHA × account-id × cluster-name)`, and validated by the
   push gate against the live Actions API — provenance, not free text.

**What round-3 corrected (the spine fixes that change the plan).** These
supersede the round-2 framing where they conflict.

- **R3-A. "Build ≠ CI" is deleted; the execution model is two real Actions
  surfaces.** The bring-up IS `terraform-test.yml action=apply-and-verify`, a
  `workflow_dispatch` run (verified: terraform-test.yml:24; reaches the cluster via
  `aws eks update-kubeconfig` on the runner :329). There is no non-CI build
  executor (`grep` finds no `apply-and-verify.sh`/`bring-up.sh`/`verify-platform.sh`
  in `scripts/`). The live suite is a **STEP added to the apply-and-verify job**.
  The two surfaces: **push/PR (automatic) = static, no-cluster**; **workflow_dispatch
  (manual) = apply-and-verify + ad-hoc, the full live suite.** (§4.1)
- **R3-B. "On by default" is made mechanical by the FAIL-closed live-evidence gate**
  (§4.3) + the `mgmt_apply`-gated step + the GitOps-config trigger + the readonly-path
  expect-full floor (exec summary above). This is the spine fix and the centerpiece;
  the round-2→round-3 WARN demotion is reverted to FAIL.
- **R3-C. The build runs under the admin CI key — split the identity.**
  `terraform apply` keeps admin (unavoidable for bootstrap); `tests/live/run.sh` runs
  under a **scoped, zero-wildcard, tag-conditioned** verifier/reaper role committed as
  an IAM policy file; a static lint asserts the live phase **cannot inherit the admin
  env block** (`secrets.AWS_ACCESS_KEY_ID`); `LIVE_MODE` defaults **fail-closed to
  `readonly`**. The NON-GOAL is preserved and distinguished: this scoped role is for
  the verifier/reaper *harness*, **not** a new AssumeRole principal impersonating the
  Crossplane controller — driving the real controller under `source: IRSA` is still
  the only identity oracle. (§3.4, §4.1)
- **R3-D. The spoke is PUBLIC** (`endpointPublicAccess: true`, platform-cluster.yaml:329);
  CI reaches it via `aws eks update-kubeconfig` exactly as it reaches mgmt today (the
  integration suite already does, integration-tests.yml:74). The "private-CA spoke API"
  residual was **mis-diagnosed and is removed**; the real precondition is the
  public-endpoint CIDR allowlist + the EKS AccessEntry for the CI identity (a config
  check, verified at spike time). This **un-strands the 6 spoke blockers.** Spoke
  verification is a **post-reconcile STEP in the dispatch job** (watch the spoke XR
  reach `Ready` on the hub, then verify) — **not** a standing controller/daemon the
  plan never builds. (§10, §14)

**What round-2 corrected (carried forward, still load-bearing).**

1. **Identity is `source: IRSA`, NOT `InjectedIdentity`.** The synthesized plan
   was factually wrong. `crossplane/providerconfig/00-clusterproviderconfig.yaml:41`
   is `source: IRSA` on a `ClusterProviderConfig` of group `aws.m.upbound.io`.
   `InjectedIdentity` belongs to a *different* provider (provider-kubernetes, the
   spoke-Secret write path), not AWS. The falsifiable identity gate is now:
   `source: IRSA` **AND** no static-cred AWS ProviderConfig **AND** no
   `AWS_ACCESS_KEY_ID` in the provider pod env. The caller-ARN==expected check is
   **infeasible in-band** and is demoted to an optional out-of-band audit.
2. **Workflows CAN be edited here** (via jentic Contents-PUT / `ext-github`), so the
   "can't edit workflows" premise is removed. **The live suite is a STEP added to the
   apply-and-verify job of `terraform-test.yml`** (a `workflow_dispatch` workflow),
   landed via jentic — this IS a workflow edit, not a non-CI executor. Two — and only
   two — real execution surfaces (round-3 R3-A): **push/PR CI (automatic) = static
   no-cluster checks only**; **`workflow_dispatch` (manual) = the apply-and-verify job
   (full live suite, on by default, all-skipped ⇒ RED) AND ad-hoc/kind runs** — the
   same Actions surface, two action choices. Cluster work (even kind) is
   `workflow_dispatch`-only (matches chainsaw.yml / terraform-test.yml; AGENTS §6.7) —
   satisfying correction #2. "On by default" is enforced **mechanically** by the
   FAIL-closed live-evidence gate, the `mgmt_apply`-gated step, the readonly-path
   expect-full floor, and the GitOps-config trigger (§4) — **never** by the dispatch
   UI default (which is advisory only). Requirement #1 ships as a mechanism, not a
   convention.
3. **The coverage deriver must parse Pipeline-mode compositions** (MR kinds at
   `spec.pipeline[].input.resources[].base.kind`, keyed on **group+kind with the
   apiVersion VERSION stripped**, deduped) — verified working below. The extractor
   and the committed fixture oracle must be **byte-identical** (round-3 k8s-expert C2:
   the raw `apiVersion + "/" + .base.kind` emits `…/v1beta1/Role` but the oracle was
   written as `…/Role`, so the WARN-ONLY gate could never flip green). It ships
   WARN-ONLY first, with an **explicit, mechanical WARN→enforce flip condition** (not
   warn-only forever). IAM per-component attribution is dropped (irsa.tf is one flat
   policy).
4. **`simulate-principal-policy` is a FLOOR only,** not the completeness oracle —
   the policy is already `Resource:"*"` so simulate is circular. The real
   completeness signal is **drive-the-controller**. The ceiling must **narrow**
   `eks:*`/`rds:*` to derived verb lists with capped, expiring justifications and
   a **non-deferred fail-on-unexercised-grant tier**.
5. **`crossplane-claim-verify` is v1-claim-shaped** (`spec.resourceRefs`, claim
   kind) but the repo is v2 namespaced-XR with no claim. **Porting it to v2 is a
   prerequisite** before it can be mandatory; otherwise it verifies zero MRs. The v2
   composed-MR enumeration is via **`spec.crossplane.resourceRefs`** (the v2
   relocation of the old top-level `spec.resourceRefs`; `status` carries conditions,
   not the ref list) — pinned at spike time against the live cluster. `wait-for-claim.sh`
   waits **top-level Ready only and descends nothing** (verified: it polls one named
   object, exits 0 on top-level Ready); composed-MR enumeration is solely the v2-ported
   claim-verify Phase 3's job — it is load-bearing new code, not a reused asset.
6. **The reaper is friendly-fire** on the shared ephemeral account → needs an
   **account-mutex** + age-floor ≥ slowest build (≥45 min) + a structural
   *deny-list* account guard (not an allow-match that bricks on rotation).
7. **The spoke trigger is a post-reconcile STEP in the dispatch job** — key off the
   spoke XR reaching `Ready` on the **hub** + git-desired-state, then verify; not an
   imperative apply GitOps would revert, and **not** a standing watcher daemon (the
   plan builds no controller/CronJob). The spoke kube-API is PUBLIC
   (`endpointPublicAccess: true`), reached from the runner via `aws eks
   update-kubeconfig` like mgmt — so behavioral spoke checks are not stranded.
8. **Requirement-4 "both" collides with the singleton rule** — partition cheap
   resources into *hermetic* (both, always) vs *singleton-coupled* (after-the-fact
   on the hub; instantiate only in an isolated spoke/namespace).
9. **`expect-full` must derive from git desired-state, not the system under test**
   (a self-attested oracle recreates blocker #5 one level up).
10. **Negatives prove the guard FIRED**; do **not** blanket-mandate Kyverno
    Enforce + `failurePolicy:Fail` (cluster-admission-freeze risk); prefer
    app-level/AppProject enforcement; redact secrets; define the false-fail SLO
    concretely or drop it.

**The recommended rollout** front-loads a **P0 spike** that proves the real
v2/Pipeline/IRSA mechanism end-to-end *before* anything is built on it, then
ships the visibility/enforcement scaffold (incl. the fail-closed live-evidence
gate and the scoped verifier identity), then deepens after-the-fact coverage,
then isolation/reaper, then the bring-up behavioral catch, then negatives + the
spoke post-reconcile step, then hardening.

**The one thing not to lose:** the spine above. Every operational pressure point
below tempts a "just stand up a probe pod" or a "skip is green if unsure" climb-
down. Reject both.

---

# PART II — THE FULL PLAN

## 1. Diagnosis (preserved — all plans and reviews converge here)

The suite conflates **lints** with **tests**. The empty cell is real cloud ×
restricted identity. Verified grounding (this session):

- `tests/integration/run.sh:26-45` — rc=2 is a counted SKIP; the orchestrator
  `exit 0` whenever `FAIL==0`. All-skipped reads green. **Real.**
- `terraform/management/irsa.tf:171-175` — the Crossplane provider role trust
  permits exactly one subject: `crossplane-system:upbound-provider-family-aws`.
  A probe SA cannot assume it. **Real.**
- The auto-012 missing actions are **already granted**: `iam:UpdateAssumeRolePolicy`,
  `iam:GetRolePolicy` (irsa.tf:73), `iam:TagOpenIDConnectProvider` (irsa.tf:82),
  the full `rds:*` set (irsa.tf:98-104). You cannot produce a live `AccessDenied`
  for them without revoking a grant or a crippled-twin role. **Real.**
- Every high-value statement is `Resource = "*"`: EKS (irsa.tf:43-44), IAM
  (:86), RDS (:106), ACM (:134), Route53Read (:159), EC2 (:57). SecretsManager
  is scoped to `secret:k8-platform/*` (:117); Route53Validation to
  `hostedzone/<zone_id>` (:148). **Real — this is what makes simulate a floor.**
- `crossplane-claim-verify/SKILL.md` is v1-claim-shaped: `<claim-kind>`,
  `spec.resourceRef.name` (line 57), descends `spec.resourceRefs[*]` (line 81),
  and `reference/cloud-verification.md:45-51` base64-decodes secret `.data` and
  dumps `SecretString`. **Real — both the v2 break and the secret-spill.**
- All XRDs are `apiextensions.crossplane.io/v2`, `scope: Namespaced`, **no
  claimNames** (verified all four under `crossplane/xrds/`). **v2, no claim.**

## 2. Taxonomy — three buckets keyed on *where the test runs*, two tags

Collapsed from the source plans' 5-6 tiers (DevX consensus). Buckets constrain
the author; the "fails-for-the-right-reason" reasoning is guidance, not names.

| Bucket | Runs where / when | Proves | Honest limit |
|---|---|---|---|
| **PRE-FLIGHT** (lints) | **static, no cluster** — local + push/PR CI, seconds | manifest schema-valid; kubeconform/schema; helm-template render asserts; the two-sided IAM floor/ceiling; `simulate-principal-policy` floor; coverage-manifest **parse**; `irsa_trust_validator.py` static sweep; the "live-suite is wired into the bring-up and on-by-default" invariant | fake/no cloud; admin or no identity; never evidence the thing built |
| **BRING-UP** | **real cluster, a STEP in the apply-and-verify job** of `terraform-test.yml` (a `workflow_dispatch` run); on by default within that dispatch (gated on `mgmt_apply`), cheap (sec–min); NEVER push/PR-triggered | drive the real controller **under `source: IRSA`**; instantiate-and-verify cheap **hermetic** kinds; guard-fired negatives | mutating — needs hard isolation (§8); runs under the **scoped verifier role**, not admin (§3.4) |
| **AFTER-THE-FACT** | real cloud, post-apply, read-only `Describe*` + convergence | the slow/standing things the bring-up already built (EKS, RDS) exist *and behave* | read-only; cannot exercise the create-path permission |

Two **tags**, not tiers: `real-irsa` (the assertion depends on the restricted
identity, §5) and `expect-full` (set when a phase claims to have built a resource;
turns a SKIP into a FAIL, §4 — sourced from **git**, not self-report).

**Kind render/admit moves to manual dispatch (correction #2).** `helm template`
and pure-`yq`/`kubeconform` render asserts need no cluster and stay on push as
PRE-FLIGHT lints; but anything that **stands up a kind cluster** to render/admit
(chainsaw-style composition-render and admission-*shape* checks) requires a cluster
and is therefore **`workflow_dispatch`-only**, never push/PR-triggered — matching
the repo's existing `chainsaw.yml` / `terraform-test.yml` pattern (AGENTS §6.7).
The BRING-UP behavioral suite IS a `workflow_dispatch` CI run — specifically a STEP
added to the apply-and-verify job of `terraform-test.yml` — not a separate non-CI
executor (no such executor exists in the repo). Its on-by-default guarantee is
enforced by the push/PR FAIL-closed live-evidence gate (§4.3), not by the dispatch.

**Honesty rename, no move:** relabel `tests/unit/` conceptually as **lints** via
a README + a `lint` tag. A physical `tests/unit/`→`tests/lint/` move is rejected
as bundled (high blast radius: run.sh, the workflow step list, ~60 files); if ever
wanted it is its own isolated PR. A one-line lint asserts new `tests/unit/test_*.sh`
carry the `lint` tag so the conceptual claim stays true (DevX-r2 m2).

`tests/live/run.sh` vs `tests/integration/`: `tests/integration/` is **the
real-cluster base and is not deleted**; its probes are *promoted by reference*
into `tests/live/` (new orchestrator, inverted skip semantics). To avoid two
runners drifting (DevX-r2 m4): `tests/live/run.sh` **sources the same
`tests/integration/lib/`**; the inversion lives only in the orchestrator's
tabulation, not in a forked lib. Exit-code contract is pinned (§4.4) so a child's
`exit 2` (skip) is never silently swallowed as a passed `expect-full`.

## 3. IRSA mechanism — drive the real controller (resolves round-2 #1, #4, #10)

### 3.1 "Under IRSA" = drive the REAL controller. No probe SA. (the spine)
A probe pod cannot `AssumeRoleWithWebIdentity` into the Crossplane role (its OIDC
`sub` won't match irsa.tf:174). Widening trust to admit a probe *is* the privilege
bloat this overhaul exists to catch. So the **only** sanctioned mechanism is:
apply a **real, throwaway, run-id-prefixed v2 XR** (namespaced, no claim) and let
the **provider controller reconcile it under `source: IRSA`**, then assert
`Synced`/`Ready` + the real cloud resource via the **v2-ported**
`crossplane-claim-verify` (§9) + `scripts/wait-for-claim.sh`.

**NON-GOAL (spine, do not weaken):** this overhaul creates no new AssumeRole
principal, widens no trust policy, and does not mount/copy the provider SA's
projected token into a probe pod. PR work attempting any of these is out of scope
and must be rejected in review.

### 3.2 The corrected, falsifiable identity gate (resolves round-2 #1)
The synthesized plan keyed on `InjectedIdentity`. **That is wrong for AWS.** The
AWS family provider uses **`source: IRSA`** on `ClusterProviderConfig/default`
(group `aws.m.upbound.io`, verified providerconfig:31-41); the SA
`crossplane-system:upbound-provider-family-aws` is annotated
`eks.amazonaws.com/role-arn=<cluster>-crossplane` (DeploymentRuntimeConfig in
`helm.tf`) and assumes the role via its projected token. `InjectedIdentity` is the
**provider-kubernetes** `hub` ProviderConfig (the spoke-Secret write path, §10) —
unrelated to AWS IRSA.

Every `real-irsa` BRING-UP test, before trusting a result, asserts — **in-band,
sub-second, the primary and load-bearing check** (reconciling security-A "make it
falsifiable" with k8s-expert C1/C4 and qa-guru m4):

1. `kubectl get clusterproviderconfig.aws.m.upbound.io/default -o jsonpath='{.spec.credentials.source}'`
   == **`IRSA`** (exact string; not "IRSA or InjectedIdentity" — that either-or
   makes the assertion unfailable). A PRE-FLIGHT lint asserts the committed
   ProviderConfig is `IRSA`.
2. There is **no** AWS-group (`aws.m.upbound.io`) `ProviderConfig`/`ClusterProviderConfig`
   with `source: Secret` layered over it, **and** no `AWS_ACCESS_KEY_ID`/
   `AWS_SECRET_ACCESS_KEY` in the `upbound-provider-family-aws` pod env. This
   directly closes the low-friction wrong path (reuse an admin-cred ProviderConfig
   and go green proving nothing).
3. The provider is **Healthy under that config** (the package's `Healthy`
   condition + the MR reconciling), so "IRSA" is not merely declared but live.

**The caller-ARN==expected-role-ARN check is INFEASIBLE in-band** and is
explicitly NOT a per-bring-up gate (resolving the contradiction k8s-expert C4 /
sre M3 / qa-guru m4 exposed): CloudTrail latency is ~15 min, and the only
synchronous alternative — a pod using the provider SA — **is the rejected probe
pod**. It is offered as a **slow, optional, out-of-band audit lane** (CloudTrail
`userIdentity.arn` or IAM Access Analyzer), run once at spike time and
periodically, never blocking a bring-up. **The identity claim never becomes
unfalsifiable:** the in-band gate (1+2+3) is the falsifiable floor; the ARN audit
is corroboration. The synthesized plan's §14.1 fallback ("degrade silently to
Synced+exists, drop the ARN") is **forbidden** — the in-band gate replaces it and
must stay.

### 3.3 The two completeness oracles, reconciled (resolves round-2 #4; qa-guru C3)
The synthesized plan shipped two oracles that collide on EKS/RDS. The corrected,
single contract with explicit precedence:

- **`simulate-principal-policy` is a FLOOR, not the proof.** On a `Resource:"*"`
  policy, `eks:*` returns `allowed` for every action whether or not a Composition
  needs it — it cannot see the *unknown-missing-action* gap that bit auto-012
  (sre C1). It is demoted to "the enumerated required set is grantable for this
  principal." It must be invoked **per-action with the correct `--resource-arns`**
  drawn from the matching irsa.tf statement scope (k8-platform/* for ASM, the
  hosted-zone ARN for Route53Validation, `*` where the policy is `*`) or it lies
  in both directions (k8s-expert M4); a unit test asserts the simulate inputs'
  ARNs match irsa.tf scopes. The SCP/boundary claim is softened: simulate reflects
  account-attached explicit Denies/boundaries only; **org SCPs are a residual**.
- **The real completeness signal is DRIVE-THE-CONTROLLER:** a missing action
  surfaces as a real `AccessDenied` during a live provision (the cheap hermetic
  kinds, §5) — the only thing that catches the unknown-missing-action. For the
  expensive kinds (EKS/RDS) we **accept weaker coverage by design**: one real
  build's behavior + the simulate floor; we do **not** paper this with a tool that
  can't see the gap (sre C1, must-not-weaken).
- **The narrowing CEILING with teeth (resolves round-2 #4, security C1).** The
  policy starts at `eks:*`/`rds:*`/`Resource:"*"`, so an "add-grant-on-AccessDenied"
  loop rewards bloat. The ceiling therefore requires **narrowing `eks:*`/`rds:*`
  to the derived verb list** (from the MR `forProvider`/`managementPolicies`
  usage, §4) — *narrow the wildcard, do not annotate it green*. Where a wildcard
  truly must remain, an inline `# lpe-justified:` annotation must carry an `OI-`/
  ADR cross-link **and an expiry**, and the lint **caps** annotated wildcards (fail
  if > K) so "annotate everything" is mechanically impossible.
- **Precedence (the tie-break the merge lacked):** the **fail-on-unexercised-grant
  tier is NON-deferred** and operates **only on the delta** `granted − (exercised-
  at-runtime ∪ required-by-an-uninstantiated-expensive-kind-in-the-derived-set ∪
  annotated)`. Expensive-kind actions are accounted by the **derivation** (they are
  required-by-a-known-kind), not dumped in a free-text allowlist — so the tier
  still polices the cheap kinds and the *narrowing* requirement (not the tier)
  governs EKS/RDS. The exercised set comes from CloudTrail/access-analyzer; because
  that is latent, this tier runs in an **async/after-the-fact lane**, and the §13
  matrix credits it as async, never as an in-bundle push gate.
- **Deny tests must ship WITH the scoping they assume (sre C1.2).** "The role
  cannot create a role outside the platform path" fails against the *current*
  `Resource:"*"` policy. So each deny test is bundled in the **same PR** as the
  resource-scoping tightening it asserts (path-condition on `iam:CreateRole`,
  ARN-scope on RDS) or it is dropped. A deny test that reds the current intended
  state is a TODO, not a test. **Decision for the owner:** the plan *recommends*
  tightening `Resource:"*"` on IAM/RDS to platform-path/ARN scope (real work, real
  blast radius on the live provider role) and ships the deny tests with it in P4;
  if the owner declines the tightening, the deny tests are dropped and that gap is
  documented, not faked.

### 3.4 The verifier/reaper identity is itself a least-privilege deliverable — and the build-coupled trigger concentrated the privilege (round-3 security C1; round-2 C2.2)
**The genuine new hole correction #2 opened.** `apply-and-verify` runs inside
`terraform-test.yml`, which injects the **admin** AWS keys (`:41-43`). Appending
`tests/live/run.sh` as a step there means the verifier, reaper, simulate, RGT-diff,
and the reaper's cross-service **deletes** would all run as **the most-privileged
principal on the account that also hosts the mgmt cluster** — a *worse* blast radius
than the one the overhaul retires from Crossplane. The plan must re-reckon this, not
just name it. Required:

- **Split the build flow's identity.** `terraform apply` keeps admin (unavoidable for
  bootstrap). The `tests/live/run.sh` phase **MUST NOT inherit the admin env block**;
  it re-scopes — via an explicit `sts assume-role` to a dedicated least-privilege role
  (or a separate job/identity) — so the suite never holds `terraform apply`-grade
  power.
- **A static push lint asserts the live phase cannot run as admin:** the
  `terraform-test.yml` step that invokes `tests/live/run.sh` does **not** reference
  `secrets.AWS_ACCESS_KEY_ID` directly. This is the "runs-under-the-scoped-identity"
  static invariant, alongside §4.2's "wired-and-on-by-default" one.
- **The allowlist is a committed IAM policy file** (`.tf`/JSON artifact, not prose),
  with **zero wildcards** — `accessanalyzer:*` is enumerated to the two or three read
  verbs actually used; `servicequotas:Get*` likewise; the mutex backing store is
  **pinned** (SSM `ssm:GetParameter`/`PutParameter` **or** DynamoDB
  `GetItem`/`PutItem`/`DeleteItem` — pick one so the policy can be written). The §3.3
  ceiling lint covers this file with `K=0` (no wildcard tolerated here at all).
- **The reaper's deletes are enumerated per service AND tag/path-conditioned in the
  policy itself** (`eks:DeleteCluster`/`DeleteNodegroup`, `rds:DeleteDBInstance`/
  `DeleteDBSubnetGroup`, `iam:DeleteRole`/`DeleteOpenIDConnectProvider`/
  `DeleteRolePolicy`, `secretsmanager:DeleteSecret`, `route53:ChangeResourceRecordSets`),
  with an IAM `Condition` that the resource carries the `live-verify` run-id tag —
  defense-in-depth, since the runtime three-predicate AND is the very thing under test
  and a bug in it under admin deletes real infrastructure.
- **NON-GOAL boundary (explicit, so this does not violate the spine):** this scoped
  role is the verifier/reaper **harness** identity. It is **NOT** a new AssumeRole
  principal that impersonates the Crossplane controller, **NOT** a trust-policy
  widening on the provider role, and **NOT** a probe-SA path. The controller's
  create-path permission is still proven only by driving the real controller under
  `source: IRSA` (§3.1/§3.2). The harness role observes/reaps *around* that test; it
  never stands in for the controller's identity.

## 4. Build-coupled trigger + profile selector + anti-silent-regression (resolves round-2 #2, #5; constraint corrections #1, #2 & #3)

### 4.1 The execution model — TWO real Actions surfaces, made on-by-default by a push gate (corrections #1 & #2; resolves round-3 sre/security/devx/k8s-expert/qa-guru C1)
**The "build ≠ CI" framing is deleted — it had no referent.** Grounded against the
tree: `apply-and-verify` is a `workflow_dispatch` **input value** of
`.github/workflows/terraform-test.yml` (`:24`); the cluster comes up **on a GitHub
Actions runner** via `aws eks update-kubeconfig` (`:90,:329`); there is **no**
`scripts/apply-and-verify.sh` / `bring-up.sh` / non-CI executor (`ls scripts/` is
diag/status/verify helpers only). So "the bring-up" IS a dispatched CI run. Workflow
files **can** be edited here via **jentic Contents-PUT (`ext-github`,
`op_12ee1daaad73b14b`)** — correction #1 (the git-push OAuth token and GitHub MCP
write tools lack `workflow` scope; jentic does not). The honest topology is **two —
and only two — execution surfaces:**

- **Surface A — push/PR (automatic): STATIC, NO CLUSTER.** Only no-cluster checks:
  lints, kubeconform/schema, helm-template render asserts, the derived-coverage-
  manifest **PARSE** (static, §4.5), the no-wildcard IAM ceiling lint (§3.3),
  `irsa_trust_validator.py` static sweeps (§7), the static invariants that the live
  suite is **wired into the apply-and-verify job, on-by-default, exit-code-gated, and
  scoped-identity** (§4.2/§3.4), AND **the FAIL-closed live-evidence gate** (§4.3).
  These live in `tests/unit/run.sh` (already push-gated by the light push workflow
  `unit-tests.yml`) and need no `workflow` scope. **No cluster is ever stood up on
  push/PR.**
- **Surface B — `workflow_dispatch` (manual): the only live surface.** A dispatched
  run of `terraform-test.yml`. Two action choices on the *same* surface:
  - `action=apply-and-verify` (and any management `apply`, per §4.2) ⇒ **the full
    live suite runs as a STEP added to the apply-and-verify job**, `LIVE_MODE=mutating`,
    with `all-skipped ⇒ RED` and the `expect-full` floor. This is requirement #1's
    "every bring-up" guarantee — **but a manual dispatch cannot self-enforce "every,"
    so the teeth live on Surface A** (the live-evidence gate, §4.3).
  - `action=verify` ⇒ the readonly after-the-fact subset, `LIVE_MODE=readonly`. **The
    git-sourced `expect-full` floor still applies on this readonly path** (§4.3/§4.4),
    so a `verify` on a cluster where git declares a kind that is absent (blocker #5's
    shape) FAILs — it cannot read green having verified nothing.
  - Kind-based render/admit and ad-hoc live runs are also Surface B (dispatch-only,
    never push/PR), matching `chainsaw.yml` / `terraform-test.yml` (AGENTS §6.7).
    Landed via jentic; stay manual.

**The push/PR gate NEVER stands up a cluster.** It enforces on-by-default by checking
**static evidence of a fresh green live run** for the deployed `(SHA × account ×
cluster)` (§4.3) — the FAIL-closed mechanism that turns the absence of a live run
RED. The live suite is wired as a step **in `terraform-test.yml`** (the only build
flow; this IS a workflow edit, landed via jentic — §12). The committable half is
`tests/live/run.sh` + its self-test; the step add is the landable other half.

**The `mgmt_apply ⇒ verify` coupling (round-3 sre C2).** `compute-gates.sh` makes a
bare `action=apply` first-class (`mgmt_apply=true, mgmt_verify=false`) — so today a
plain `apply` brings up the cluster with **zero** verification. Fix: gate the
live-verify step on **`mgmt_apply` as well as `mgmt_verify`** so **any management
apply triggers the live suite**, and add a push-time unit test asserting
`compute-gates.sh management apply` yields a true live-verify gate. "You cannot apply
the management cluster without the live suite running" becomes mechanically true, and
"apply without verify" is a red diff.

The new `tests/unit/test_*.sh` static-gate files must be added to **both**
`tests/unit/run.sh` and `unit-tests.yml` in the same PR; `unit-tests.yml` is a light
**no-cluster** push workflow editable via normal push, and the §6.16-sync catch-all
step is the source-of-truth backstop. `tests/live/run.sh` learns the action via an
explicit `LIVE_MODE=mutating|readonly` arg (passed by the workflow step, not a PR
check): `verify` ⇒ `readonly`, `apply-and-verify` ⇒ `mutating`. **`LIVE_MODE` unset
defaults fail-closed to `readonly`** (round-3 security M2, devx m2) — an
under-specified invocation degrades to safe, never to provisioning. Unit tests assert
both `verify ⇒ readonly` and `unset ⇒ readonly`, and that `mutating` appears only on
the `apply-and-verify` branch in the workflow file (so an agent's frequent `verify`
calls never provision NLBs/IAM/secrets). The §4.4 `phase=test` suite asserts this
**against the `terraform-test.yml` file** (mirroring AGENTS §6.16), not only the
orchestrator's internal default. The mutating instantiate-path of
`crossplane-claim-verify` runs only under `mutating`.

### 4.2 The PROFILE selector — `full` (default) / `verify-only` / `off`, and the default is a *tested invariant* (round-3 security C2, devx m5, qa-guru R3-C1; constraint correction #3)
**"Disable" is a PROFILE selector, not a binary on/off** (correction #3). The owner's
intent: **on-by-default is an anti-forgetting DEVELOPMENT safety net** — while we are
actively implementing, we must not be able to forget to verify what we built; the
FAIL-closed live-evidence gate (§4.3) gives that teeth. *When* a component is proven
working, the operator must be able to "turn off everything but the verification
steps" so a routine bring-up does not take ~3 hours — which is a **reduction in
TIERS, not an off switch.** The selector (env `LIVE_PROFILE`, default `full`):

| Profile | Tiers run | When | Cost |
|---|---|---|---|
| **`full` (DEFAULT, development)** | AFTER-THE-FACT (read-only verify) **+** BRING-UP instantiate-on-purpose **+** negative/precondition [+ e2e] | a component (or cluster) **under active development** — nothing forgotten | full (the ~3-hr work) |
| **`verify-only` (mature/working)** | **ONLY** the fast AFTER-THE-FACT verification of what THIS bring-up actually created + its health | a **proven** component on a routine bring-up | cheap (read-only `Describe*`/health) |
| **`off`** | nothing (guarded, audited) | **NOT used now** | — |

**The cost the operator is removing is the instantiate-on-purpose + negative tiers**
(they create throwaway resources and exercise failure paths — the slow part). The
expensive EKS/RDS resources were **already after-the-fact** (§5) and therefore
**remain in `verify-only`**; `verify-only` does not skip them. **Tier → profile map**
(this is the §2-taxonomy ↔ profile binding):
- **AFTER-THE-FACT (read-only existence/convergence/health)** runs in **BOTH `full`
  and `verify-only`** (never in `off`).
- **BRING-UP instantiate-on-purpose** (the cheap-hermetic create-and-verify, §5) and
  **negative/precondition** (§7) run in **`full` only**.
- **PRE-FLIGHT lints** are push-time and profile-independent (always run on Surface A;
  they stand up no cluster).

**`LIVE_PROFILE` is distinct from `LIVE_MODE`.** The PROFILE chooses **WHICH TIERS
run**; `LIVE_MODE` (§4.1) chooses **read-only vs mutating WITHIN the live tiers that
do run**. They compose: `verify-only` runs only read-only tiers, so **`verify-only`
implies `LIVE_MODE=readonly`** (it has no instantiate tier to mutate); `full` uses
`LIVE_MODE=mutating` on the `apply-and-verify` path and `readonly` on the `verify`
path. A unit test asserts `verify-only ⇒ readonly` and rejects `verify-only` paired
with `mutating` (an instantiate request under a profile that drops instantiate).

Default = `full`, and **the default profile is a tested invariant** (the existing
"default value is a tested invariant" rule now asserts **the default profile ==
`full`**). Any `workflow_dispatch` UI default is **advisory only** (k8s-expert m4) and
never the guarantee. Static invariants, all checkable **on push, no cluster**,
asserted against the **actual dispatched workflow** (`terraform-test.yml`, the file
AGENTS §5 / testing-guidelines §6 name — not "a flow definition" the lint could be
pointed anywhere):
- The default-profile value (in the orchestrator's **own committed config** — the
  single source the test reads) is literally `full`, so changing it is a red diff.
- **The live suite is wired AND gating, not merely invoked** (security C2 — "wired ≠
  gating"). The static lint asserts the apply-and-verify path of `terraform-test.yml`
  invokes `tests/live/run.sh` AND that the build's success is a function of the
  suite's exit code: it **forbids `tests/live/run.sh || true`, backgrounding (`&`),
  and an `if:` that can silently exclude the step** (commented-out / `if: false`),
  per AGENTS §6.19 (PR #129's exact failure class) and §6.24. The §4.4 reserved
  `exit 3` (expect-full violation) must fail the build, not just the script. A
  meta-test feeds a stub `tests/live/run.sh` returning `exit 3` and asserts a **failed**
  build (or, if the real flow can't run statically, asserts the wiring pattern
  lexically — invocation present, no `|| true`, no `&`, exit code consumed).
- **The live suite runs under the scoped identity, not admin** (§3.4): the step does
  not reference `secrets.AWS_ACCESS_KEY_ID`.

**Per-profile anti-silent-regression (correction #3).** The `all-skipped ⇒ RED`
invariant holds **PER PROFILE**, applied to the tier set that profile runs: in
`verify-only` the AFTER-THE-FACT set **must still actually run**, and `all-skipped ⇒
RED` applies to **THAT** set — so `verify-only` cannot read green having verified
nothing. **Selecting `verify-only` is an explicit, recorded reduction** — the dropped
instantiate + negative tiers are a **deliberate, audited choice, never a silent
skip**; the chosen profile is written to a register entry (reason/owner/expires, like
SKIP_REGISTER) so "we ran cheap" is always attributable.

`off` is guarded: selecting `LIVE_PROFILE=off` makes the banner **RED and exits
non-zero** unless a top-level `disable_all` register entry (reason/owner/expires)
exists. To collapse the parallel "off" doors (round-3 devx M2), `off` / `disable_all`
is a thin alias that **writes a SKIP_REGISTER-shaped entry** — one durable disable
path, not two with different teeth. **All-skipped is RED inside the suite per profile
when it runs; and "the suite never ran" (or "ran a weaker profile than the change
requires") is RED outside the suite via the §4.3 live-evidence gate** — both halves,
every reviewer (must-not-weaken).

A note on the `live-verify` artifact name: where this plan says "`live-verify`
workflow," it means a **`workflow_dispatch`-only** GitHub Actions workflow for
**manual/ad-hoc** live runs (Surface B's ad-hoc lane) — NOT a push/PR-triggered job.
The every-bring-up guarantee is the FAIL-closed live-evidence gate on Surface A
(§4.3) plus the `mgmt_apply`-gated step inside the apply-and-verify job of
`terraform-test.yml` on Surface B — both are landed via jentic; cluster-requiring
workflows stay `workflow_dispatch`-only (correction #2).

### 4.3 `expect-full` is derived from GIT, not the system under test (resolves round-2 #5; qa-guru C2; sre M1)
The synthesized plan set `expect-full` off "what the bring-up *declared* it
applied" — a self-attested oracle: a crash-before-declare or an ArgoCD-synced
spoke produces no declaration → everything downgrades to phase-not-applied → green.
That is **blocker #5 one level up**. The fix:

- **Derive the expected resource set from committed desired-state** — `crossplane/**`
  (the v2 XRs and Compositions) + the ArgoCD apps + the git-declared cluster set
  (e.g. is a spoke XR committed under `clusters/`?). `expect-full` for a kind is
  on **iff that kind's declaration is present in git for the cluster under test**,
  diffed against runtime. It is **never** derived from the live status of the
  bring-up under test (circular).
- **Fail-closed on a missing oracle:** a BRING-UP test that emits *no* phase/skip
  classification at all is treated as `expect-full` (loud, not silent-green).

**The FAIL-closed live-evidence gate (the centerpiece — round-3 spine fix).** Because
Surface B is a *manual* dispatch, "the apply-and-verify job invokes the suite" cannot
by itself guarantee "every bring-up": a dispatcher can pick `verify`/`plan`, a
config-only change reconciles via ArgoCD with no dispatch at all, or the suite can
crash before its final phase. The round-2→round-3 draft demoted the anti-regression
check to a "secondary WARN backstop" — **that demotion weakened on-by-default and is
reverted.** The push/PR gate is the **PRIMARY mechanical default-on**, FAIL-closed:

- **It FAILs (never WARNs)** unless a fresh green live run is recorded for the
  deployed `(config-SHA × account-id × cluster-name)` triple. "No fresh green run for
  this triple" is the precise state of "the suite never ran" — and because the gate
  lives **outside** the suite, it catches the non-invocation cases the inside-suite
  `all-skip ⇒ RED` cannot (a `verify`/`apply`/`plan` dispatch, a config-only ArgoCD
  sync, a crash before the final phase). all-skip⇒RED (inside-suite) + no-evidence⇒RED
  (outside-suite, push gate) together cover both halves.
- **The evidence is unforgeable, not a hand-writable marker** (round-3 security m1,
  devx M1, qa-guru M3). The push gate calls the **GitHub Actions API** (the repo's
  `.github/workflows/chainsaw-verify.yml` pattern) to confirm an `apply-and-verify`
  run for this SHA **exists**, has `conclusion=success`, ran against **this
  account-id and cluster-name**, **records WHICH `LIVE_PROFILE` produced it**, and is
  **newer than the account's bootstrap**. If a machine-emitted committed marker is
  used at all, its integrity contract is: written **only** on the §4.4 clean-pass exit
  code (never on `exit 2`/`exit 3`/all-skip), keyed on the full **(SHA × account-id ×
  cluster-name × profile)** so a rotated account (§8.1) invalidates it and **a
  `verify-only` result cannot masquerade as a `full` result**, by the same step whose
  exit code it records — and the push lint validates that provenance against the API,
  not free text. A committed free-text "green" marker is **forbidden** (it re-creates
  the self-attested oracle this section exists to kill, one level up).
- **The gate requires the profile the change demands** (correction #3, tie to
  coupled-to-the-change). A component still under development — or **any component
  whose config-SHA changed** in the PR (`crossplane/**`/`policies/**` for that
  component) — **requires `full` evidence**; a `verify-only` record for it is
  **insufficient ⇒ RED** ("re-run `full`"). This is how "we don't forget during
  implementation" stays enforced even though mature components run cheaper: **a change
  to a component re-arms `full` for it.** Only a proven, unchanged component is
  satisfiable by `verify-only` evidence.
- **Config-only GitOps changes are a first-class trigger context** (round-3 qa-guru
  R3-C2, the exact auto-012 change shape). A PR editing `crossplane/**` / `policies/**`
  — a Composition/IAM/tag edit ArgoCD will sync to the **live hub with no
  apply-and-verify dispatch** — FAILs the gate unless fresh green live-evidence
  exists for the resulting config-SHA, forcing a dispatch-before-merge (the §6.7/§6.8
  pattern the repo already uses for chainsaw on v2 CRD changes). This closes the hole
  where a Composition edit that re-introduces blocker #9 (drops a subnet tag) or #1
  (flips authnMode) merges green and is verified by nothing.
- **Bootstrap case:** the first apply for a fresh/rotated account has no prior marker
  by construction; that is `expect-full`-from-git (RED, "run the build"), **never**
  green-by-absence.
- This keeps "coupled to the change" anchored mechanically — not reduced to "coupled
  to whoever remembers to dispatch" — while never standing up a cluster at PR time
  (correction #2): the gate only *reads* the Actions API.

### 4.4 The executed-test FLOOR / skip-promotion (the load-bearing part)
Three skip states (not two): **not-applicable** (no kube-API at all — informational,
allowed); **phase-not-applied** (the git desired-state does not declare this kind
for this cluster — counted SKIP, allowed); **precondition-absent-but-expected-
present** (git declares it, it's missing — **FAIL**; literally blocker #5's shape).
**The FAIL discriminator keys on git desired-state alone, NOT on "the phase applied"**
(round-3 qa-guru M5): for a GitOps/ArgoCD-synced resource there is no discrete
"phase applied" event, and an ArgoCD app can report `Synced` while a composed MR
underneath is stuck (the §9.1 v2 "XR Ready, child MR stuck" mode). So the rule is:
**git declares kind K for this cluster ⇒ K is `expect-full` ⇒ the real cloud resource
(verified via the v2-ported claim-verify descending to the MR + cloud Describe, §9.1)
must exist; absent ⇒ FAIL, regardless of any ArgoCD/XR `Synced` status.** ArgoCD-Synced
is never permitted to downgrade an `expect-full` kind to an allowed skip — otherwise
the GitOps path (6 of 8 blockers) keeps an "app says Synced ⇒ skip-green" escape.
**The floor is evaluated on BOTH the `verify` (readonly) and `apply-and-verify`
(mutating) paths** (round-3 qa-guru M2): only the *instantiate-and-verify* create-path
checks are gated on `LIVE_MODE=mutating`; the after-the-fact existence/convergence
floor is mode-independent, so the cheapest and most-run action (`verify`) is not the
blind spot for the slowest blockers (#5/#1). Under `expect-full`, any SKIP of an
expected resource is promoted to FAIL; `run.sh` exits non-zero if executed checks for
the present phase fall below a declared floor or if *every* check skipped. **Floor =
zero tolerated skips for any `expect-full` resource — non-negotiable** (only the
register cap N and grace window are tunable; qa-guru m6). The conditional-resource rule (DevX C1):
a conditional MR (e.g. patched-out in `xspokeaccess`) is `expect-full` only when
its gating param is set in the applied XR; the registry entry carries the
condition. A `phase=test` unit suite asserts the tabulation: `all-skip ⇒ non-zero`,
`precondition-abort ⇒ non-zero`, `expect-full + expected-skipped ⇒ FAIL`, and a
per-registry-kind meta-test asserts exactly one skip-state classifier is wired
(DevX C3) — an unclassified new kind reds at push.

**Exit-code contract (k8s-expert m6):** child `exit 0`=pass, `exit 2`=allowed
skip, a **distinct reserved code (e.g. `exit 3`)=`expect-full` violation** so an
orchestrator never swallows a promoted FAIL as a skip.

### 4.5 The DERIVED coverage manifest — Pipeline-mode, group/kind-keyed, fixture-tested, WARN-ONLY first (resolves round-2 #2; DevX C1; k8s-expert C2)
Hand manifests get edited green. The expected-coverage set is **generated**; the
human maintains only the **registry of which test defends which kind**. The
synthesized plan's derivation rule (`spec.resources[].base.kind` + per-component
irsa.tf actions) **does not exist in these compositions** and is replaced:

- **Exact extraction path — VERSION-STRIPPED, deduped** (round-3 k8s-expert C2,
  devx M4/m1). The naive `.base.apiVersion + "/" + .base.kind` emits
  **group/version/kind** (`iam.aws.m.upbound.io/v1beta1/Role`), but the registry keys
  on **group/kind** — so the command must strip the version, and a future
  `v1beta1`→`v1beta2` provider bump must NOT change the key (else a silent coverage
  miss exactly when a provider upgrade is riskiest). `platform-cluster.yaml` also
  emits `Role`/`RolePolicyAttachment` multiple times, so the output must be deduped.
  Use:
  ```
  yq '.spec.pipeline[]?.input.resources[]? | select(.base) | (.base.apiVersion | sub("/.*";"")) + "/" + .base.kind' | sort -u
  ```
  This yields the group/kind set with no version segment and no duplicates, and **no
  pollution** — `ClusterProviderConfig` (the `providerConfigRef.kind`), the function
  `Input`/`Resources` wrapper kinds, and the `Composition` doc kind are all excluded
  because they are not under `.input.resources[].base`. A named **exclude-list**
  (`ClusterProviderConfig`, `ClusterSecretStore`, `Input`, `Resources`, `Composition`)
  is kept as defense-in-depth — **redundant-by-construction** (the `select(.base)` +
  `.input.resources[]` path structurally cannot emit them; the bare command is safe
  without it — k8s-expert Minor-3), so an implementer need not fear the bare command.
- **Verified MR set the deriver must reproduce** (the fixture-test oracle):
  - `platform-cluster`: `iam.aws.m.upbound.io/Role`, `…/RolePolicyAttachment`,
    `eks.aws.m.upbound.io/Cluster`, `…/NodeGroup`, `acm.aws.m.upbound.io/Certificate`,
    `…/CertificateValidation`, `route53.aws.m.upbound.io/Record`
  - `platform-secret`: `secretsmanager.aws.m.upbound.io/Secret`,
    `external-secrets.io/ExternalSecret`
  - `xdatabase`: `rds.aws.m.upbound.io/Instance`
  - `xspokeaccess`: `iam.aws.m.upbound.io/OpenIDConnectProvider`, `…/Role`,
    `…/RolePolicy`, `eks.aws.m.upbound.io/AccessEntry`, `…/AccessPolicyAssociation`
- **Key on group/kind, never bare kind** (`Secret`, `Role`, `Record`, `Instance`
  are ambiguous; route `external-secrets.io`/`kubernetes.crossplane.io` kinds to a
  **non-AWS lane** with no IAM action to simulate).
- **Drop the per-component-IAM-from-irsa.tf claim.** irsa.tf is **one flat
  `aws_iam_policy`** with Sid-grouped statements and **no per-XRD attribution**
  (verified). The action→component mapping is **inherently hand-curated**; own it
  as the *only* hand-maintained thing, and derive the *kind list it must cover*
  from the compositions so an un-registered kind is CI-red. The two-sided
  floor/ceiling on irsa.tf stays useful for "no wildcard" and "required action
  present" but is **not** the per-kind coverage source.
- **Ship with a BYTE-IDENTICAL fixture-test of the deriver itself** (round-3
  k8s-expert C2): feed it the four committed comps and assert the extractor output is
  **byte-identical** to the committed group/kind oracle above — so the command the
  plan mandates as extractor and the oracle it mandates as gate cannot drift (the
  round-2 draft's oracle was written version-stripped while the command emitted
  versions, which would have stuck the gate WARN-ONLY forever). Add a
  **version-independence fixture**: the same comps with a bumped provider version must
  yield the **same** keys. It ships **WARN-ONLY (print, exit 0)** at first — a
  mis-firing gate that reds every PR is *worse* than the hand manifest (DevX C1,
  must-not-weaken) — but with an **explicit, mechanical WARN→enforce flip condition,
  not warn-only-forever** (round-3 devx M4): a push lint asserts that **once the
  byte-identical fixture-test file exists and passes, the deriver's mode flag is
  `enforce`** (so the same PR that lands a green fixture flips the gate; an
  accountable owner owns the flag, and a green fixture with the flag still `warn` is
  itself a red diff). The mapping test requires a **real referenced check** whose
  `--dry-run` fixture **names the registered group/kind in its apply payload** (DevX
  C2 — a mechanical floor under the "any green test counts" goodwill), not merely a
  tier declaration.
- **Side-effect resources** absent from `resources[]` (the untagged subnet, a
  controller-created NLB — blockers #9 and the LB) go in a small **`extra:`
  allowlist with a required `reason:`**, AND are covered by a **standing
  after-the-fact `resourcegroupstaggingapi` diff** (qa-guru M4): diff actually-
  tagged-created cloud resources for this run/cluster against (derived-kinds ∪
  `extra:`); a created resource in neither is a FAIL (uncovered side-effect); an
  `extra:` entry with no matching real resource for N runs is a FAIL (stale
  allowlist). The derived manifest is "the spine for declared kinds"; the RGT-diff
  is "the spine for side-effects."
- **Cost tier** is a curated registry field (group/kind → `hermetic`/`singleton-
  coupled`/`slow`), **not** an annotation on production `crossplane/**` manifests
  (k8s-expert N2 — the team should not carry test metadata in prod manifests). The
  "no separate file" purity is relaxed for this one curated registry.

### 4.6 The skip-baseline gate compares SETS, not a count (DevX M3)
"Fail if the skip *count* rose" is gameable (lower the integer) and noisy. The
gate derives the **expected skip set** from the registry+git-phase (§4.3/§4.5) and
fails if a runtime skip is **not in that set** — "you skipped something not
declared," not "the integer went up." The SKIP_REGISTER (`tests/live/SKIP_REGISTER.yaml`)
is the only durable disable, and is **also where a non-`full` profile choice is
recorded** (correction #3 — choosing `verify-only`/`off` writes a register entry, so
the tier reduction is attributable, never silent): each entry needs
reason/owner/expires; a unit test fails if any field is missing, any `expires` is
past, or any runtime skip is unregistered. **Cap the register at N** (set N=12 with headroom; the cap message
names which entries to retire), require an `OI-` cross-link for any disabled
*security* check, and escalate `expires` warn→fail after a grace window (set to 14
days) so a calendar event doesn't red unrelated PRs.

## 5. Slow-vs-cheap + the singleton partition (requirements 3 & 4; resolves round-2 #8; qa-guru C4)

Cost split preserved: **never recreate the 20-min EKS or the multi-minute RDS.**

- **Slow / expensive (EKS ~20 min; RDS): AFTER-THE-FACT only.** Verify the one the
  bring-up already built. EKS: `describe-cluster` ACTIVE, nodegroup healthy,
  `accessConfig.authenticationMode` includes `API`, hub AccessEntry exists, OIDC
  provider tagged, **the exact LB subnet tags** `kubernetes.io/role/elb` (public) /
  `kubernetes.io/role/internal-elb` (private) plus `kubernetes.io/cluster/<name>`
  (k8s-expert m3 — pin the keys or the assertion passes while the LB can't
  provision), spoke registered in ArgoCD (`connectionState: Successful`). RDS:
  `describe-db-instances` available + `XDatabase` Ready.
  - **Verify the EFFECT, not just config:** behaviorally assert the hub app-
    controller can authenticate to the spoke API ("AccessEntry row exists" ≠
    "access works"). **Conditional, marked in the matrix** on the spoke-API-from-CI
    operator dependency (§14); fallback = AccessEntry row + the app-controller
    AssumeRole **success in CloudTrail** as a weaker-but-real proxy (sre M7).
  - **Convergence, not a stale read:** `observed == desired AND the XR's last-
    reconcile is newer than the change`, bounded wait.
  - **EKS create-path permission:** simulate floor only (§3.3) — accepted weaker-
    by-design; not papered.
  - Distinct statuses: `UPSTREAM-APPLY-FAILED` vs `RESOURCE-UNHEALTHY` (sre-C M7).

- **Cheap — partitioned (resolves qa-guru C4, round-2 #8):**
  - **(a) Hermetically-instantiable (BOTH, every bring-up):** per-run-id IAM Role,
    OIDC provider, S3, ASM Secret, ESO ExternalSecret, ConfigMap, ACM cert. No
    shared-singleton coupling. Generalize the `11_platform_secret_e2e.sh` shape
    (XR→wait→cloud-exists→behaves→delete→assert torn down) via **one parametrized
    harness** (§ DevX M4): adding an XRD is a fixture+registry entry, not a new
    142-line script. **Synthetic test secrets MUST use the `k8-platform/` name
    prefix** or the positive test hits `AccessDenied` for an unrelated reason
    (ASM IAM scope is `secret:k8-platform/*`, irsa.tf:117 — k8s-expert m5).
  - **(b) Singleton-coupled (AFTER-THE-FACT on the shared hub; BRING-UP only in an
    isolated scope):** Route53 record (external-dns / shared zone), IngressClass
    (cluster-scoped, ingress-controller singleton), ArgoCD cluster registration.
    These are instantiated **only against a bring-up-created spoke or an opt-in
    isolated lane**, never mutating the shared hub singleton in the default bundle.
  - **Rule (state it):** req-4 "both" applies to set (a) **unconditionally** and to
    set (b) **on a spoke / isolated scope**; where truly un-isolatable, after-the-
    fact-only is a **documented carve-out** (not a silent requirement violation). A
    `singleton-coupled` registry tag drives this; it is a column in §5 and §13.

- **Idempotency is a standing per-test assertion, not P6 (qa-guru M2):** for set
  (a), "apply the same XR twice ⇒ exactly one cloud resource, no
  `ScheduledForDeletion`, no name collision." ASM uses `force-delete-without-
  recovery` (gated on the **run-id** substring, not just the platform prefix —
  sre m3, a force-delete with a prefix typo on a real secret is unrecoverable);
  global IAM/OIDC names embed the run-id.

- **`verify` stays read-only**; **RDS is plainly AFTER-THE-FACT** (not an opt-in
  flag); a path-trigger requires live evidence when the `XDatabase` Composition
  changes.

## 6. Quota, throttle, wall-clock (resolves sre M4, M5, m2; qa-guru M5)

- **Quota math fixed (sre M4):** the EC2-headroom-of-9 formula applies only to
  the *forbidden* instance-backed tests; the default hermetic set creates
  IAM/OIDC/ACM/ASM, which have their own limits. State **per-kind limits** (IAM
  roles ~1000, OIDC providers ~100, ACM per-region, ASM 7-30d recovery window) with
  `force-delete-without-recovery` for ASM and a **cert-reuse strategy** so rapid
  red-CI loops don't exhaust ACM. The quota check fails closed if
  `servicequotas:Get*` errors, with a distinct `QUOTA` tag (not `AccessDenied`).
- **Throttle classifier:** bounded concurrency + jittered backoff on
  `ThrottlingException`/`Rate exceeded`; a hard classifier separates `Throttling`
  (retry) from `AccessDenied` (real, fail red) so a self-inflicted throttle never
  masquerades as an IRSA gap.
- **Teardown leak-scan is a bounded poll (sre M5):** Crossplane teardown is async;
  the leak-scan polls-until-empty with a per-class teardown budget and distinguishes
  `DELETING`/`ScheduledForDeletion` (in-progress, wait) from `ACTIVE` orphan (real
  leak, RED) — only red after the budget expires. "Leak ⇒ RED" without this poll is
  a false-fail factory.
- **Wall-clock: a budget, not just a ceiling (qa-guru M5; sre m2):** publish a
  per-bundle **target total added wall-clock** (set **< 8 min over bare bring-up**)
  as a *budget gate distinct from the hard ceiling*; each new BRING-UP check
  declares an expected duration whose sum the mapping test holds under budget — the
  N+1th check that blows it is a red diff. Provide the worked floor: reaper (~30s) +
  hermetic create/verify (~2-3 min) + idempotency double-apply (~30s) + teardown
  poll (~2 min) must fit with margin; the identity gate (§3.2) is sub-second by
  construction (no CloudTrail in-band).

## 7. Negative & precondition tests — prove the GUARD fired (requirement 5; resolves round-2 #3, #9)

Rule for every negative/precondition: **assert the specific cause/reason + a
positive control in the same fixture** (a valid input succeeds first, proving the
harness can detect success at all; then the invalid input is rejected/denied with
the **named reason**). Concrete contracts:

- **XRD bad-param:** schema-shape negatives stay hermetic in chainsaw (cheap;
  don't re-prove live). Split **synchronous-reject** (`kubectl apply` exit≠0 with
  the field+constraint substring) from **async-fail** (v2 often ACCEPTS and fails
  async): assert the same `reason` **persists across two reads ≥ the reconcile
  interval apart AND no cloud resource exists** — "terminal `Synced=False`" is not
  a Crossplane concept; stability-over-time is the only honest terminal signal
  (qa-guru m3).
- **EKS `CONFIG_MAP`-only is a composition-text LINT, not an admission negative
  (k8s-expert M2):** `authenticationMode: API_AND_CONFIG_MAP` is **hardcoded** in
  the MR base (platform-cluster:320), not XR-driven — there is no field to set to
  CONFIG_MAP, so no admission/XRD-validation rejection exists. The negative is a
  `yq` lint on `.spec.pipeline[].input.resources[] | select(.base.kind=="Cluster")
  | .base.spec.forProvider.accessConfig.authenticationMode ∈ {API, API_AND_CONFIG_MAP}`.
  Home: `test_eks_module_defaults.sh` (exists). A true admission negative would
  require making it an XRD CEL-validated enum — flagged as a *design change*, not a
  test.
- **Keycloak-without-DB precondition — APP-LEVEL gate, not a cluster webhook
  (resolves round-2 #9; security C3):** the **primary** gate is the chart's
  `wait-for-db` init-container / DB-readiness probe (app-local, **cannot freeze the
  cluster**). Assert: (1) positive control — with the DB present, Ready in budget;
  (2) the named init-container is `Waiting`/non-zero referencing the DB host AND
  the service serves a fails-closed response, not 200. A Kyverno admission gate is
  **NOT** mandated here (a `failurePolicy:Fail` webhook on a DB-adjacent policy is
  a cluster-wide deploy-freeze on a Kyverno blip — security C3, k8s-expert M1).
- **Kyverno is NOT the catcher for AWS-side facts** (it cannot see EKS authnMode or
  VPC subnet tags). Any matrix row crediting Kyverno for those is dropped.
- **Do NOT blanket-mandate Kyverno Enforce + `failurePolicy:Fail` (resolves
  round-2 #9; k8s-expert M1).** All 11 repo ClusterPolicies are Audit today (verified;
  the 12th file under `policies/audit/` is a README — round-3 k8s-expert Minor-1). An
  Enforce promotion is **not** "P1 cheap/no-behavior-risk"; it is a cluster-wide
  admission change with an outage surface. Any Enforce promotion: (a) is
  namespace/label-scoped, never cluster-wide `match` with `Fail`; (b) ships its own
  positive control proving it does not block healthy real workloads; (c) is its own
  PR with a rollback note; (d) requires Kyverno HA (>1 replica) confirmed first.
- **Lead tenant-isolation / AppProject deny-by-default with RBAC, not Kyverno
  (security M1):** an AppProject's `clusterResourceWhitelist`/`namespaceResourceWhitelist`
  is **already deny-by-default by construction** — a tenant namespace genuinely
  cannot instantiate an out-of-scope XRD with no Enforce policy needed. Lead with
  the AppProject/RBAC proof; treat Enforce-Kyverno as redundant second layer. Rows
  not real until P6 are marked "not-yet-covered" in the matrix (no overclaim).
- **A cheap always-on Enforce *firing* test (qa-guru M3):** for whatever Enforce
  policy *is* promoted, the default bundle applies a deliberately-violating
  **throwaway** object in `live-verify-<run-id>` and asserts the webhook **denies
  it with the named reason** (proving the path is wired AND scoped to fire), paired
  with the "does not block a healthy throwaway workload" negative — so "Enforce
  mode" is never just a static lint.
- **external-dns #8 — `irsa_trust_validator.py` is PRIMARY (security M4):** it
  statically compares SA name vs trust subject (the exact blocker shape) with no
  live assume; `--all == 0 MISMATCH` is the hard gate. The live "record appears /
  named auth error in pod logs" is corroborating bring-up positive only (log-grep
  is brittle/version-dependent), not "the real assertion."
- **Added negatives:** IRSA confused-deputy family (wrong-`sub`/`aud`/issuer
  denied); v2 connection-secret rejection via a **throwaway XRD fixture** (not the
  live v2 XRDs, which already lack the field — k8s-expert m2); BRING-UP IAM/OIDC
  fixtures rejected if the trust policy lacks both `sub` and `aud` `StringEquals`
  or uses `Principal:"*"` — as a **static fixture lint** (security m2).
- **Meta-test is a GATE, not a guideline (security C3.2):** the coverage-mapping
  test requires every `negative`/`precondition` test to reference a **committed
  red-first evidence artifact** (the recorded failure against the guard-removed
  fixture) and fails the push if absent. For blockers already fixed in irsa.tf
  (`rds:*`, `iam:Tag*` are present now), red-first is a one-time "remove the grant
  locally, confirm simulate flips to deny, restore" demonstration, not a no-op
  revert (DevX m3) — stated per-blocker so an implementer doesn't burn a loop.

## 8. Isolation, cleanup, reaper-with-mutex (resolves round-2 #7; sre C2; security M2)

- **Singleton invariant:** the default bundle never mutates a resource a running
  controller treats as a singleton (ingress-nginx controller, external-dns,
  admission webhooks). All BRING-UP mutations live in a labeled, **ArgoCD-excluded**
  throwaway namespace `live-verify-<run-id>` (AppProject deny / sync-options
  exclusion) so self-heal/prune never races; `kubectl delete ns` is the bulk GC.
- **Account-mutex, not just hub-mutex (resolves round-2 #7; sre C2):** the synthesized
  plan's hub-lease does not gate AWS-side resources created by a parallel run on a
  *different* cluster against the *same* account. Add an **account-level lease**
  (SSM param / DynamoDB item keyed on the account ID) serializing live runs.
  Behavior on contention: **block-with-bounded-timeout then FAIL — never
  skip-green** (a contended skip re-opens requirement 2 — sre M6, qa-guru M2). Lease
  TTL < the reaper age-floor so a dead holder's lease self-expires; the lease is
  committable k8s/AWS state, not a workflow `concurrency:` group. A unit test
  asserts a held lease does not produce a green skip.
- **Reaper-runs-FIRST, but friendly-fire-proofed (resolves round-2 #7; sre C2;
  security M2):**
  - Deletes by **pinned label + run-id prefix + age floor (all three)**; dry-run +
    emit the to-delete set first.
  - **Age floor ≥ the slowest legitimate build: set to ≥ 45 min** (EKS ~20 min +
    margin), tied to the slowest resource, not a generic "age floor" — so a
    sibling run's in-flight resources are never reaped.
  - **The reaper MUST skip any run-id present in the active-run lease**, regardless
    of age (security M2, sre C2) — a resumed/suspended run is never reaped mid-flight.
  - **Account guard is a structural DENY-list, not an allow-match (resolves sre C2):**
    refuse to run if `sts get-caller-identity` is in a committed **deny-list of
    protected account IDs** (mgmt/production — durable), NOT "unless it equals the
    blessed ephemeral ID" (which is non-durable and bricks on rotation, §10).
    Frame: "fail-closed if pointed at a protected account."
  - **Remediate-and-RED, not report-and-pass** — but only after the bounded
    teardown poll (§6) and account-mutex.
  - **Primary teardown keys off the run-id on the XR name** (which the test
    controls) and verifies deprovisioning down the tree; label-sweep is defense-in-
    depth. **Pin the EXACT label string** — the repo mixes `k8-platform`/
    `k8s-platform`; a prefix typo silently matches nothing (a leak that reads
    green). Enumerate by the tag the **controller actually applies** (the
    Composition tags ASM secrets `k8-platform/<XR-uid>`, never the test's prefix —
    OI-2026-05-28-1, confirmed); a unit test asserts every BRING-UP test sets the
    pinned label (security m3, sre m2).
  - The reaper identity is the tightly-scoped verifier identity of §3.4.
- **Account-rotation mid-run:** a shared helper classifies mid-run STS/credential
  errors as `ENVIRONMENTAL-ROTATION` (stop with a distinct message), separate from
  `AccessDenied-on-restricted-role` (the real signal) — the negative-test logic
  depends on telling these apart.

## 9. v2 claim-verify prerequisite + secret redaction (resolves round-2 #3, #12)

### 9.1 Port `crossplane-claim-verify` to v2 BEFORE it is mandatory (resolves round-2 #3; k8s-expert C3)
The skill is v1-claim-shaped and the repo is v2 (verified: SKILL.md uses
`<claim-kind>` and `spec.resourceRef.name` line 57, descends `spec.resourceRefs[*]`
line 81; the XRDs are v2 namespaced, no claim). On a v2 XR `spec.resourceRefs`
returns empty → the skill walks **zero** MRs and reports the XR Ready while child
MRs may be stuck — the exact manifest-says-X disease, with a green light. **This
is a prerequisite task (in P0/P1), not optional:**
- Phase 1: locate the **XR** (`kubectl get <xr-kind> -A`), not a claim.
- Phase 3: walk the v2 composed-resource ref path. **Enumerate FIRST via
  `kubectl get <xr-kind>/<name> -n <ns> -o jsonpath='{.spec.crossplane.resourceRefs[*]}'`**
  — the v2 relocation of the old top-level `spec.resourceRefs` (`status` carries
  conditions, not the ref list; do NOT assume `spec.resourceRefs` or `status.resourceRefs`
  — those return empty and falsely read "no children," k8s-expert M3). Only if that is
  empty, fall back to probing `status`/`spec.resourceRefs`, and **record which field
  the live cluster actually uses as a pinned spike fact.** Assert every composed MR
  `Synced=True` + `Ready=True`, AND assert the enumerated refs **⊇ the deriver's
  group/kind set** (§4.5) so "XR Ready but children missing" reds.
  **`scripts/wait-for-claim.sh` cannot substitute for this** — it waits top-level
  Ready only and descends nothing (verified); the v2-ported Phase 3 is the **sole**
  composed-MR enumerator and is load-bearing new code.
- Prerequisites text: match the **family** provider `upbound-provider-family-aws`
  (+ children), not a naive `provider-aws` name.
- Phase 4 PlatformSecret recipe: digest/length/canary only, **never decode** (§9.2).
- `scripts/wait-for-claim.sh` is audited for the same v1/v2 and auto-dump issues.
- The P0 spike (§12) must explicitly assert the **v2-ported** skill descends into
  and verifies every composed MR — not just "the XR is Ready."

### 9.2 Secret redaction (resolves round-2 #12)
`crossplane-claim-verify`'s `reference/cloud-verification.md:45-51` base64-decodes
secret `.data` and dumps `SecretString` (verified). Mandatory before any secret-
path test runs:
- **Synthetic non-secret values only;** assert on a digest/length/known canary,
  never plaintext.
- A **redaction filter** on every failure dump strips `data:`/`stringData:`/
  `SecretString`/`Authorization` before stdout, run-log, or PR comment. The PR
  summary is the most-public artifact: redacted-only, the last place a credential
  could appear; also mask account-id/ARNs on the PR-summary path specifically
  (security m3 — ASM ARNs, OIDC issuer URLs, role ARNs are account-identifying
  recon aids).

## 10. The spoke trigger — GitOps-native (resolves round-2 #6; k8s-expert M3)

The spoke is where **6 of 8 blockers lived**, and it comes up via Crossplane/
ArgoCD reconciliation of an XR, **not** an imperative apply (an imperative step
would be reverted by GitOps; there is no `terraform/spoke` to hang an end-of-bring-
up hook on).

- **A post-reconcile STEP in the dispatch job, NOT a standing watcher daemon**
  (round-3 sre M1). The plan builds no in-cluster controller/CronJob and there is no
  long-running hub process to host a "watch-XR-then-invoke-tests" loop — so the
  earlier "hub-side watcher wired into the reconciliation path" framing implied a
  daemon the plan never delivers and is **dropped**. Instead, the spoke verification
  is a **step appended to the same `apply-and-verify` dispatch that provisions the
  spoke XR**: it blocks on `kubectl wait --for=condition=Ready` on the hub
  `XPlatformCluster`/`XSpokeAccess` object (bounded), then runs the spoke
  AFTER-THE-FACT + (if the runner reaches the spoke API) the e2e. This is the same
  Surface-B dispatch as §4.1, deliverable in CI via jentic.
- **`expect-full` for the spoke derives from git desired-state** (§4.3): a spoke XR
  committed under `clusters/` makes the spoke's resources `expect-full` even when
  ArgoCD (not a human `apply-and-verify`) synced them — so an ArgoCD-synced spoke
  that silently never provisions is a **FAIL**, not auto-skip-green. This closes
  the GitOps hole the synthesized plan's "imperative apply sets expect-full" model
  left open (k8s-expert M3, sre M1).
- **The spoke kube-API is PUBLIC — the curl e2e is NOT stranded** (round-3 k8s-expert
  M1). `platform-cluster.yaml:329` sets the spoke `vpcConfig.endpointPublicAccess: true`,
  so a **GitHub Actions runner reaches the spoke API via `aws eks update-kubeconfig`
  exactly as the integration suite reaches mgmt today** (integration-tests.yml:74;
  terraform-test.yml:90,329) — bypassing the sandbox's strict-MITM gateway entirely.
  The "private-CA spoke API" residual the prior draft listed as the lone operator
  dependency was a **mis-diagnosis and is removed**: the real precondition is (a) the
  runner egress IP is in the spoke's public-access **CIDR allowlist** and (b) an
  **EKS AccessEntry/AssumeRole** path for the CI identity — a config check verified at
  spike time, not an architectural blocker. The curl e2e (sync an app using a
  cluster-scoped IngressClass → external-dns writes the Route53 record →
  `curl https://hello.platform.<domain>` returns 200 → Keycloak Ready against RDS)
  ships once the CIDR/AccessEntry are confirmed; run from the runner, never the
  sandbox (the sandbox cannot verify any EKS CA — AGENTS §6.27). The hub-side fallback
  (XR-Ready + AccessEntry present + ArgoCD `connectionState: Successful` + CloudTrail
  AssumeRole-success proxy) remains the weaker-but-real default. The `InjectedIdentity`
  provider-kubernetes `hub` ProviderConfig (crossplane-phase3.tf) is the spoke-Secret
  write path relevant here — distinct from the AWS IRSA discussion in §3.

## 11. False-fail SLO — concrete, with teeth, with a data plane (resolves round-2 #11)

The synthesized plan's "< 2%" had no denominator, no consequence, and an unbuilt
data store. Corrected to a real control:

- **Metric (operational definition):** false-fail rate =
  `reds whose triage disposition ∈ {ENVIRONMENTAL-ROTATION, THROTTLE, QUOTA}` ÷
  `all reds`, computed from the §8 classifier categories (machine-computable). A
  red that is an `expect-full` miss or a real `AccessDenied` is **true**, never
  false.
- **Threshold:** **measured from day one, target ratcheted down from whatever P2
  exhibits** — not a pre-committed 2% on a suite that doesn't exist.
- **Where the data lives (resolves the synthesized plan's open question #6):** a
  **committed `tests/live/FLAKE_LOG`** (per-test stable ID + outcome), which
  survives account rotation, is a reviewable diff, and lets the gate detect "N of
  last M." Not an ephemeral CI artifact.
- **Consequence (the teeth):** an SLO breach **auto-demotes the offending check to
  a non-gating quarantine lane** (mechanical, not goodwill); quarantine carries an
  expiry (a quarantine older than X with no owner update fails the push check).
- **Auto-quarantine must NOT silently green a real recurring failure** (round-3
  qa-guru M4; AGENTS §6.24 automated). The single most load-bearing distinction in
  the overhaul — `AccessDenied` (real) vs `Throttling` (retry) — must not become the
  input to an automatic disable. Bounds: **auto-quarantine is permitted ONLY for the
  `ENVIRONMENTAL-ROTATION`/`THROTTLE`/`QUOTA`/`LEASE-CONTENTION` dispositions.** A
  check whose window contains **any `AccessDenied-on-restricted-role` or
  `expect-full`-miss** red (the exact auto-012 blocker classes) is **not
  auto-quarantinable** — it requires a human `OI-` entry. The classifier fail-safe is
  **asymmetric toward red: ambiguous/unclassifiable ⇒ treat as REAL (do not
  quarantine, bundle-red)**. The reserved `exit 3` (expect-full violation) is
  **ineligible for quarantine** by construction (§4.4/m-note). A classifier
  fixture-test over a corpus of real AWS error strings guards the classifier itself,
  with the default for an unmatched string being bundle-red.
- **Per-check red ≠ bundle red (sre M2):** one flaky DNS check must not red the
  whole bring-up; only an `expect-full` miss or a real `AccessDenied` reds the
  bundle. This separation is what stops the social disable ("I saw red on my
  unrelated change → `LIVE_VERIFY=0`").
- **No blind retries:** eventual-consistency gets a bounded poll-until-true with a
  per-check `consistency_budget` justified against the AWS propagation SLA, one
  shared bounded-poll helper per service class (DNS/IAM/STS). "Passed on retry N"
  surfaces as a flake signal, not a clean pass; budget breach → `OI-` entry.

## 12. Operator-dependency ledger (qa-guru C1)

Every change requiring an action the committable PR cannot itself perform, with
the committable half vs the operator/jentic half:

| Change | Committable half | Other half | Identity it runs under | Now deliverable? |
|---|---|---|---|---|
| Live-verify STEP in `terraform-test.yml` apply-and-verify job (gated on `mgmt_apply`) | `tests/live/run.sh` + its self-test | the step add to `terraform-test.yml` (this IS a workflow edit) + `compute-gates.sh` `mgmt_apply⇒verify` change | **scoped verifier role** (NOT admin, §3.4) | **YES — via jentic** (corrections #1 & #2) |
| Push/PR FAIL-closed live-evidence gate (Actions-API run-ID cross-check, §4.3) | the `test_*.sh` gate calling the Actions API (`chainsaw-verify.yml` pattern) | the per-step add in the no-cluster push workflow | n/a (read-only Actions API) | **YES — normal push** |
| Config-only GitOps trigger (`crossplane/**`/`policies/**` path-filtered FAIL) | the path-filtered gate logic | the per-step add | n/a | **YES — normal push** |
| Spoke post-reconcile verification STEP (not a daemon) | the wait-for-Ready + verify logic | the step appended to the spoke-provisioning `apply-and-verify` dispatch | scoped verifier role | **YES — via jentic** (no controller built) |
| `workflow_dispatch`-only ad-hoc live + kind render/admit lane | the gate/check logic | the `workflow_dispatch`-only workflow | scoped verifier role | **YES — via jentic** |
| Push/PR static gate (lints + coverage parse + ceiling + wired/gating/scoped/on-by-default invariants) | the `test_*.sh` static checks | the per-step add in the no-cluster push workflow | n/a | **YES — normal push** |
| Scoped verifier/reaper IAM policy (§3.4) | the committed zero-wildcard `.tf`/JSON policy + ceiling lint over it | applying it via the base/management Terraform | n/a | **YES — committable** |
| Spoke kube-API read from CI (curl e2e / behavioral #1/#6) | the check logic | runner egress IP in the spoke **public-access CIDR allowlist** + EKS AccessEntry | runner identity | **CONFIG CHECK** — spoke API is PUBLIC (§10, §14); verify at spike |
| `unit-tests.yml` step list for new gate files | the `test_*.sh` + `run.sh` wiring | the per-step add | n/a | **YES — normal push** (light workflow) |

Every "build-flow wiring" the prior draft described is concretely **a step in
`terraform-test.yml`** landed via jentic — there is no non-CI executor. The
spoke-API-from-CI dependency is **not** the architectural blocker the prior draft
painted: the spoke API is public-access-enabled, so it reduces to a CIDR-allowlist +
AccessEntry config check (round-3 k8s-expert M1). Everything stranded on "can't edit
workflows" is landable via jentic.

## 13. Corrected blocker → layer coverage matrix (all 8 + the subnet-tag blocker)

This matrix is the **acceptance criterion**, mirrored into `ai/TESTING-PLAN.md`
with a unit test that every row names a test file that **exists AND carries the
tag the row's Push/bring-up column implies** (qa-guru m5 — existence alone allows a
row to point at a lint). Rows a layer cannot physically observe are corrected.

| # | auto-012 blocker | Caught by — assertion / environment | Push or bring-up |
|---|---|---|---|
| 1 | EKS `authenticationMode=CONFIG_MAP` | AFTER-THE-FACT: `describe-cluster` mode **contains `API`** (assert membership of `API`, not just the allowed set — security m4) **+ behavioral** hub app-controller authenticates to spoke (spoke API is PUBLIC, reached via `update-kubeconfig`, §10 — fallback = CloudTrail AssumeRole success); PRE-FLIGHT: **composition-text lint** that base contains `API` (NOT an admission negative — hardcoded, k8s-expert M2) | both |
| 2 | crossplane IRSA missing `iam:TagOpenIDConnectProvider` | PRE-FLIGHT: simulate **floor** (allowed for the action) + narrowing ceiling; BRING-UP: real spoke-access XR provisions the OIDC-tagging path under `source: IRSA`, no `AccessDenied` — **the real completeness signal** (simulate cannot see unknown-missing) | both |
| 3 | missing `iam:UpdateAssumeRolePolicy` | same as #2 (simulate floor + real-controller positive) | both |
| 4 | missing `iam:GetRolePolicy` | same as #2 | both |
| 5 | missing all `rds:*` → RDS never provisioned | PRE-FLIGHT: simulate **floor** for the rds set (slow → no instantiate); AFTER-THE-FACT: `describe-db-instances` + `XDatabase` Ready (`expect-full` from git ⇒ absent = FAIL) | both |
| 6 | ArgoCD app-controller SA missing IRSA | PRE-FLIGHT **PRIMARY**: `irsa_trust_validator.py --all` over **both** `argocd:argocd-server` and `argocd:argocd-application-controller` (irsa.tf:21-29 trusts both, attaches no policy — so behavioral AssumeRole-*success* under-proves: it proves identity, not capability — security M4); AFTER-THE-FACT behavioral (spoke registration / `connectionState`) is corroborating. **Owner note (§14):** `role_policy_arns={}` on the controller role — if a spoke-registration policy is expected, the empty attachment is itself a finding | both |
| 7 | platform-spoke AppProject missing IngressClass permit | BRING-UP (**on a spoke / isolated scope** — singleton-coupled, §5): sync an app using a cluster-scoped IngressClass → must sync (positive) + forbidden kind/repo/destination rejected by the **AppProject** (negative); PRE-FLIGHT: `test_platform_spoke_appproject.sh` extended to the full deny contract | both |
| 8 | external-dns SA-name ≠ trust subject → 0 records | PRE-FLIGHT **PRIMARY**: `irsa_trust_validator.py --all == 0 MISMATCH` (static, exact blocker shape — security M4); BRING-UP positive (on a spoke): Ingress → Route53 record appears; negative: named auth error (corroborating, log-based) | both |
| 9 | shared-VPC subnets untagged → NLB never provisioned | AFTER-THE-FACT: **exact** subnet-tag assertion (`kubernetes.io/role/elb`/`internal-elb` + `cluster/<name>`) **+ behavioral** NLB actually provisions + the **RGT-diff** catches it as a side-effect (§4.5); PRE-FLIGHT: lint on the tag-injection composition. **NOT Kyverno** (AWS-side) | both |

**Throughline (corrected):** every IRSA-permission blocker (2-5,8) is **faithfully
caught only by drive-the-real-controller-under-IRSA (bring-up)**; simulate is a
push-time **floor** that cannot see the unknown-missing-action; kind/admin-cred
chainsaw masks the whole class. The matrix-completeness meta-test lands **last in
each PR's slice**, asserting only the rows that PR delivered, so P1 never ships red
(sre m1).

## 14. Residual risks & open questions for the owner

1. **The P0 spike may fail.** If, on the live hub, the v2-ported skill cannot be
   made to descend composed MRs and the in-band identity gate (`source: IRSA` +
   no-static-creds + Healthy) cannot be observed, the plan changes shape. Decide
   the fallback at spike time; do **not** build P4 on an unproven mechanism. (The
   in-band identity gate is sub-second and CloudTrail-free, so the main spike risk
   is the v2 composed-ref path, not identity latency.)
2. **Spoke-API-from-CI is a CONFIG check, not an architectural blocker** (round-3
   k8s-expert M1). The spoke API is **public-access-enabled**
   (`platform-cluster.yaml:329`); a runner reaches it via `aws eks update-kubeconfig`
   exactly as the integration suite reaches mgmt. The real precondition is (a) the
   runner egress IP is in the spoke's public-access **CIDR allowlist** and (b) an EKS
   **AccessEntry/AssumeRole** path for the CI identity. **Owner: confirm the CIDR
   allowlist admits the runner and an AccessEntry exists** — verified at spike time.
   If not, behavioral #1/#6 fall back to CloudTrail-proxy + hub-side config (§13).
   This un-strands the 6 spoke blockers.
3. **Tightening `Resource:"*"` on IAM/RDS (§3.3 deny tests).** Real work, real
   blast radius on the live provider role. **Owner decision:** tighten (and ship
   the deny tests with it) or decline (and drop the deny tests, documenting the
   gap). The plan recommends tightening.
4. **CloudTrail/access-analyzer latency** makes the un-exercised-grant tier (§3.3)
   and the optional ARN audit (§3.2) **async-only** lanes, never in-bundle gates —
   accepted, not deferred.
5. **Register cap N (=12), grace window (=14d), wall-clock budget (< 8 min over
   bare bring-up), reaper age-floor (≥ 45 min)** are policy knobs set here as
   defaults; tune in the handoff. The `expect-full` floor = **zero** is
   non-negotiable, not a knob.
6. **`FLAKE_LOG` as a committed file** (§11) trades reviewability for churn on busy
   periods; make it **append-only, one structured line per run keyed by run-id**
   (conflicts resolve by union; a lint rejects edits/deletions of existing lines), and
   **key the SLO window on (test-ID × account-epoch)** so cross-account history does
   not pollute a fresh environment's flake math (round-3 qa-guru M4a, devx m4).
   Confirm the owner prefers it to an external store.
7. **Verifier/reaper runs under a scoped role, not admin** (§3.4) — the genuine new
   hole correction #2 opened. The split (admin for `terraform apply`, scoped role for
   `tests/live/run.sh`) is required before P3/P4. **Owner: approve standing up the
   scoped verifier/reaper IAM role** (new, tightly-scoped blast radius).
8. **Mutex/age-floor bounds and sandbox-suspend** (round-3 sre m3, security m3): set
   **age-floor (≥45 min) > lease-TTL ≥ slowest-held-op (~EKS 20 min)** so a dead
   holder self-expires but a live mid-flight EKS build is never reaped. A run suspended
   > TTL (AGENTS §6.20) loses its lease; on resume it **re-acquires/renews its lease
   before trusting prior resources**, and the reaper keys the age-floor off
   creation+lease-renewal recency, not wall-age alone. Named as a residual interaction.
9. **Wall-clock budget envelope** (round-3 sre M3, qa-guru m3): the "< 8 min added"
   budget is measured **inside the apply-and-verify run, over the *existing* verify
   step** (which already burns up to ~3 min in an 18×10s pod-wait, terraform-test.yml:112)
   and **excludes account-mutex lease-wait**, which is bounded separately as a
   serial-by-design operational SLO. The hermetic set runs **concurrently within a
   run** (the mutex serializes *runs*, not kinds-within-a-run); idempotency
   double-apply is **sampled (one rotated kind/run) or `LIVE_IDEMPOTENCY=1` on the
   nightly lane**, not full-cost on every latency-sensitive bring-up.

## 15. "Done means" acceptance checklist (DevX M1)

Each line maps to the `phase=test` unit test that proves *the mechanism itself*:
- [ ] Identity gate asserts `source: IRSA` exactly + no static-cred AWS PC + no
  `AWS_ACCESS_KEY_ID` in provider pod (never accepts InjectedIdentity for AWS).
- [ ] v2-ported `crossplane-claim-verify` descends and verifies every composed MR
  on a v2 XR (spike-validated).
- [ ] Coverage deriver reproduces the exact §4.5 group/kind set from the four comps
  (fixture-tested); ships WARN-ONLY until that test is green.
- [ ] `all-skip ⇒ RED`; master-switch RED unless registered; `expect-full` (from
  git) skip→FAIL; floor=zero; reserved exit code for `expect-full` violation.
- [ ] simulate is a floor (correct per-action `--resource-arns`); narrowing ceiling
  caps annotated wildcards; un-exercised-grant tier non-deferred (async lane).
- [ ] Reaper: account-mutex, age-floor ≥ 45 min, skips active-lease run-ids,
  structural deny-list account guard, remediate-and-RED after bounded teardown poll.
- [ ] Cheap set partitioned hermetic vs singleton-coupled; idempotency standing
  per-test; synthetic-secret-only + redaction on the claim-verify decode path.
- [ ] Every `negative`/`precondition` test references a committed red-first
  artifact (gate, not guideline); Enforce promotions scoped + HA-gated + firing-
  tested, never blanket `failurePolicy:Fail`.
- [ ] The live suite is a STEP in the apply-and-verify job of `terraform-test.yml`
  (the only build flow; a `workflow_dispatch` CI run), gated on `mgmt_apply` so any
  management apply triggers it; push/PR runs static-only; kind/ad-hoc is dispatch-only.
  A static push lint (against `terraform-test.yml`) asserts the step is **wired AND
  exit-code-gated** (no `|| true`/`&`/`if:false`), on-by-default, and **runs under the
  scoped verifier role, not the admin env block**. `verify ⇒ readonly`, `unset ⇒
  readonly`; the readonly path still applies the expect-full floor.
- [ ] **The push/PR FAIL-closed live-evidence gate** (the mechanical default-on):
  RED unless a fresh green `apply-and-verify` run exists for `(SHA × account ×
  cluster)`, verified via the Actions-API run-ID cross-check; `crossplane/**`/`policies/**`
  edits FAIL without fresh evidence; the marker is machine-emitted on clean-pass only,
  never hand-writable. "Suite never ran" is RED from outside the suite.
- [ ] Verifier/reaper identity is a committed **zero-wildcard, tag-conditioned** IAM
  policy file; ceiling lint covers it at K=0; reaper deletes are per-service +
  run-id-tag-conditioned in the policy itself; auto-quarantine excludes
  `AccessDenied`/`expect-full`-miss classes.
- [ ] False-fail SLO measured into committed `FLAKE_LOG`; breach auto-quarantines;
  per-check red ≠ bundle red; wall-clock **budget** gate distinct from the ceiling.

## 16. Phased rollout — front-load the P0 spike

Stacked, independently-mergeable PRs; each ships tests red-first (or the one-time
grant-removal demonstration for already-fixed blockers, §7) and passes adversarial-
subagent review. **The riskiest mechanism is proven END-TO-END before anything is
built on it.**

- **P0 — Spike (gates everything).** On the live hub: a real v2 XR reconciles
  under `source: IRSA`; the **v2-ported** skill descends composed MRs **via
  `spec.crossplane.resourceRefs`** (pin which field the live cluster uses) and asserts
  refs ⊇ the derived kinds; the in-band identity gate fires; simulate returns the right
  allow/deny with correct `--resource-arns`; the spoke public-API CIDR/AccessEntry
  reachability is confirmed from a runner. Includes the v2 claim-verify port (§9.1)
  AND a **parametrized-harness proof-of-concept** (round-3 devx M3): two
  maximally-different kinds (ASM Secret with its force-delete window + a global IAM
  Role) through the single harness, proving the parametrization seams generalize
  before P4 bets on it. If P0 fails, the plan changes shape.
- **P1 — Visibility + enforcement (cheap/static).** Pipeline-mode coverage deriver +
  **byte-identical** fixture-test (**WARN-ONLY** with the mechanical WARN→enforce flip
  lint); two-sided IAM floor/ceiling with narrowing + capped annotations; simulate
  floor; `tests/live/run.sh` skeleton (inverted skip, executed-floor,
  `expect-full`-from-git **on both verify and apply-and-verify paths**,
  default-as-tested-invariant, master-switch guard, exit-code contract, `LIVE_MODE`
  fail-closed to readonly); SKIP_REGISTER + set-based gate; the push-time **static**
  gate in `tests/unit/run.sh` (lints + coverage parse + ceiling + the wired/gating/
  scoped/on-by-default invariants); **the FAIL-closed live-evidence gate** (Actions-API
  run-ID cross-check + config-only `crossplane/**`/`policies/**` trigger); the
  **step add to `terraform-test.yml`** (the only build flow — a workflow edit via
  jentic) that invokes `tests/live/run.sh` gated on `mgmt_apply`, plus the
  `compute-gates.sh` `mgmt_apply⇒verify` change with its unit test; the committed
  scoped verifier/reaper IAM policy (§3.4); the one-page **decision flowchart** +
  `tests/live/run.sh --explain` (round-3 devx M2); and the `workflow_dispatch`-only
  ad-hoc/kind lane landed via jentic.
- **P2 — Deepen AFTER-THE-FACT (high ROI, no new resource cost).** Behavioral
  EKS/RDS/IAM/cert/DNS verifiers (effect not just config); RGT-diff side-effect
  oracle; promote integration probes into `tests/live/` (shared lib); make the
  v2 skill mandatory. Catches #1,#5,#6,#7,#9 (config tiers).
- **P3 — Isolation + reaper + redaction (before any default-on mutation).**
  Account-mutex, reaper-runs-first friendly-fire-proofed, ArgoCD-excluded ns,
  throttle/quota classifiers, bounded teardown poll, synthetic-secret/redaction.
- **P4 — BRING-UP instantiate-and-verify under real IRSA** (the central behavioral
  catch, on the proven spike). Hermetic cheap kinds via the parametrized harness;
  idempotency standing assertions; the real-controller positives; (if owner
  approves §14.3) the `Resource:"*"` tightening + deny tests. Catches #2-#4,#8.
- **P5 — Negatives + spoke GitOps trigger + (conditional) hub→spoke e2e.** XRD/
  AppProject/RBAC/confused-deputy negatives with red-first gate; app-level Keycloak-
  DB gate; any scoped Enforce promotion with firing-test; the hub-side spoke watch;
  the curl e2e *if* §14.2 confirmed.
- **P6 — Hardening.** False-fail SLO into `FLAKE_LOG`, mechanical quarantine, fast-
  loop docs, triage playbook, the un-exercised-grant async tier.

## 17. Changes from the synthesized plan (what round-2 forced)

1. **Identity: `InjectedIdentity` → `source: IRSA`.** Every AWS-identity reference
   rewritten; the either-or "InjectedIdentity/IRSA" phrasing removed (it made the
   assertion unfailable). `InjectedIdentity` reserved for the provider-kubernetes
   spoke-Secret path. (round-2 #1; k8s-expert C1)
2. **Caller-ARN check demoted from in-band gate to optional out-of-band audit;**
   the synthesized plan's "degrade to Synced+exists, drop the ARN" fallback is
   forbidden — the sub-second in-band gate (`source: IRSA` + no-static-creds +
   Healthy) replaces it. (round-2 #1; k8s-expert C4, qa-guru m4)
3. **"Can't edit workflows" premise removed.** Enforcement is layered (the push-time
   static `run.sh` gate + the FAIL-closed live-evidence gate + a `workflow_dispatch`
   live suite landed via jentic); the on-by-default trigger is a **step in
   `terraform-test.yml`** (the only build flow — a workflow edit, NOT a non-CI
   executor; see §18); requirement #1 de-stranded. (constraint corrections #1 & #2;
   round-3 C1 across all five reviewers)
4. **simulate demoted to a FLOOR;** drive-the-controller is the real completeness
   signal; per-action `--resource-arns` mandated; ceiling **narrows** wildcards
   (caps annotations); un-exercised-grant tier **non-deferred** with explicit
   precedence reconciling the two oracles. (round-2 #4; sre C1, security C1,
   qa-guru C3)
5. **Coverage deriver rewritten for Pipeline-mode** (`spec.pipeline[].input.
   resources[].base`, group/kind-keyed, exclude-list, fixture-tested, **WARN-ONLY
   first**); the per-component-IAM-from-irsa.tf claim **dropped** (one flat policy).
   (round-2 #2; DevX C1, k8s-expert C2)
6. **`crossplane-claim-verify` v2 port made a prerequisite** (v1-claim-shaped today;
   walks zero MRs on a v2 XR). (round-2 #3; k8s-expert C3)
7. **`expect-full` re-sourced from git desired-state**, not the applier's self-
   report (self-attested oracle = blocker #5 one level up); fail-closed on missing
   declaration. (round-2 #5; qa-guru C2, sre M1)
8. **Reaper friendly-fire fixed:** account-mutex, age-floor ≥ 45 min, skip active-
   lease run-ids, structural deny-list account guard, bounded teardown poll before
   RED. (round-2 #7; sre C2, M5, security M2)
9. **Spoke trigger made GitOps-native** (hub-side XR-Ready watch + git desired-
   state), not an imperative apply. (round-2 #6; k8s-expert M3)
10. **Requirement-4 "both" partitioned** into hermetic (both, always) vs singleton-
    coupled (after-the-fact on hub; instantiate in isolation). (round-2 #8;
    qa-guru C4)
11. **Negatives:** blanket Kyverno-Enforce + `failurePolicy:Fail` mandate dropped
    (freeze risk); Keycloak-DB gate moved to app-level; tenant-isolation led with
    AppProject/RBAC; red-first meta-test made a **gate**; always-on Enforce *firing*
    test added. (round-2 #9; security C3, M1, k8s-expert M1, qa-guru M3)
12. **Verifier/reaper identity given an explicit ceiling-linted allowlist** (the
    merge's systemic flaw — over-privilege moved to the CI key). (security C2.2)
13. **False-fail SLO made concrete** (triage-ratio metric, committed `FLAKE_LOG`
    data plane, auto-quarantine teeth, per-check≠bundle red); **wall-clock budget**
    added distinct from the ceiling. (round-2 #11; sre M2, qa-guru M1, M5)
14. **Factual fixes:** the nonexistent "`route53:*` header exemption" sentence
    dropped (k8s-expert M5 — the real gap is the generic `service:*`/`verb*`
    leniency); EKS `authenticationMode` negative relabeled a composition-text lint
    (hardcoded, not admission — k8s-expert M2); exact LB subnet tag keys pinned
    (m3); ASM `k8-platform/` prefix requirement called out (m5); xdatabase has only
    `Instance` (no SubnetGroup) in the composition base set.

## 18. Changes from round-3 (the definitive corrections)

Round-3's five reviewers converged on one decisive fact: **the "build ≠ CI" framing
of the prior finalizer draft had no referent.** The bring-up IS
`terraform-test.yml action=apply-and-verify` — a `workflow_dispatch` CI run; there is
no non-CI build executor (`ls scripts/` confirms). The prior draft renamed a dispatch
and, in doing so, **demoted the anti-regression gate to a WARN, which weakened
on-by-default.** This section states that plainly (finding #9 — honesty) and lists the
fixes. These supersede §17's wording where they conflict.

1. **"Build ≠ CI" deleted; the model is TWO real Actions surfaces** (§2, §4.1):
   *push/PR (automatic) = static, no-cluster only*; *`workflow_dispatch` (manual) =
   the apply-and-verify job (full live suite as a STEP, on by default) + ad-hoc/kind
   runs* — the same surface, two action choices. (round-3 sre/security/devx/k8s-expert/
   qa-guru C1)
2. **"On by default" made MECHANICAL by the FAIL-closed live-evidence gate** (§4.3) —
   the round-3 centerpiece. A push/PR gate FAILs (not WARN) unless a fresh green
   `apply-and-verify` run for `(SHA × account × cluster)` is confirmed via an
   **unforgeable Actions-API run-ID cross-check**. This resolves three criticals at
   once: build≠CI is empty; on-by-default-as-UI-default has no teeth; and **config-only
   GitOps changes** (a Composition/IAM/tag edit ArgoCD syncs to the live hub with no
   apply-and-verify — the auto-012 shape) FAIL the gate unless fresh evidence exists.
   (round-3 qa-guru R3-C1/C2/C3/M1/M3)
3. **On-by-default teeth in the job:** the live-verify step is gated on `mgmt_apply`
   (any apply ⇒ verify; unit-tested against `compute-gates.sh`); the static lint
   asserts the build is gated on the suite's **exit code** (forbid `|| true`/`&`/`if:
   false`, AGENTS §6.19); a `verify`-only dispatch still applies the expect-full floor;
   all-skip⇒RED is paired with the outside-suite no-evidence⇒RED so "the suite never
   ran" is caught. (round-3 sre C2, security C2, qa-guru M1/M2)
4. **Build identity split** (§3.4): `terraform apply` keeps admin; `tests/live/run.sh`
   runs under a committed **zero-wildcard, tag-conditioned** verifier/reaper role; a
   static lint forbids the live phase inheriting the admin env block; `LIVE_MODE`
   defaults fail-closed to `readonly`. The NON-GOAL is preserved and distinguished:
   this is the harness identity, **not** a principal impersonating the controller.
   (round-3 security C1, M1, M2)
5. **Spoke is PUBLIC** (`endpointPublicAccess: true`, §10, §14): CI reaches it via
   `aws eks update-kubeconfig` like mgmt; the "private-CA spoke API" residual is
   removed; the real gate is the public-endpoint CIDR allowlist + AccessEntry; spoke
   verification is a **post-reconcile STEP** in the dispatch job, not a daemon. This
   un-strands the 6 spoke blockers. (round-3 k8s-expert M1, sre M1)
6. **Coverage deriver:** apiVersion VERSION stripped (key on group+kind), deduped,
   shipped with a **byte-identical** fixture-test and an explicit WARN→enforce flip
   condition. (round-3 k8s-expert C2, devx M4)
7. **v2 claim-verify:** enumerate composed MRs via **`spec.crossplane.resourceRefs`**
   (assert refs ⊇ derived kinds); `wait-for-claim.sh` cannot substitute (top-level
   only). (round-3 k8s-expert M2, M3)
8. **Auto-quarantine bounded** (§11): a recurring `AccessDenied`/`expect-full`-miss is
   **not** auto-quarantinable (only ROTATION/THROTTLE/QUOTA/LEASE-CONTENTION are);
   ambiguous ⇒ treat as REAL. (round-3 qa-guru M4)

**Honesty (finding #9 — §18 of the prior draft falsely claimed "no property was
weakened").** That was untrue: demoting the live-evidence gate to WARN **did weaken**
on-by-default and coupled-to-the-change at PR time. Restated truthfully now that FAIL
is restored: **PR-time enforcement was briefly traded for a renamed dispatch and is
now stronger than the round-2 design** — the FAIL-closed Actions-API live-evidence gate
is the mechanical default-on, and it covers cases the build coupling alone cannot
(verify-only/bare-apply dispatch, config-only ArgoCD sync, crash-before-final-phase).

**The four invariants, re-confirmed truthfully:** *on by default* = the FAIL-closed
live-evidence gate (Surface A) + the `mgmt_apply`-gated, exit-code-gated step
(Surface B); the dispatch UI default is advisory and is **not** the guarantee.
*disable-able but not disabled* = only via `LIVE_VERIFY=0` / `LIVE_SKIP` /
SKIP_REGISTER (reason/owner/expires; master kill-switch RED-and-non-zero unless
registered). *all-skipped ⇒ RED* = inside-suite, paired with outside-suite
no-evidence⇒RED so non-invocation is also red. *coupled-to-the-change* = the
config-SHA-keyed live-evidence gate, including config-only GitOps changes. **The
security NON-GOAL is intact** (no new AssumeRole principal impersonating the
controller, no trust widening, no probe pod, no provider-SA token mount); the new
scoped verifier/reaper role is the harness identity, explicitly outside the NON-GOAL.

---

*End of FINAL plan. PLAN-ONLY — no code, tests, fixtures, or workflows were
created or modified except this file. Every repo fact cited here was re-verified
against the tree this session.*
