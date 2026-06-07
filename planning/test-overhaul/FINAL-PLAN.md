# FINAL Test-Overhaul Plan — k8s-platform

> **Status: PLAN ONLY.** This document creates and edits no code, tests,
> fixtures, or workflows. It is the authoritative finalization of a multi-round
> process: 3 source plans → 9 round-1 reviews → `synthesis/SYNTHESIZED-PLAN.md`
> → 5 round-2 adversarial reviews (`reviews-round2/r2-{sre,security,devx,k8s-expert,qa-guru}.md`)
> → two constraint corrections (`CONSTRAINT-CORRECTION.md` = workflows are editable;
> `CONSTRAINT-CORRECTION-2.md` = the verification trigger is the BUILD, not CI, and
> cluster tests are `workflow_dispatch`-only). It folds every round-2 CRITICAL and
> both constraint corrections into one spec. Where reviewers disagreed, this document
> picks and justifies.
>
> Every load-bearing repo claim here was re-verified against the tree this
> session (file:fact cited inline). Author: lead test architect.

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
(`source: IRSA`), with create-and-verify **coupled to the change** — meaning
coupled to the **build/bring-up that applies the change**, not to a PR/commit check
— **on by default** (the bring-up procedure itself invokes the suite), where
**all-skipped ⇒ RED**. Cost split: **after-the-fact** read-only
checks for the expensive standing things (EKS ~20 min, RDS), **instantiate-and-
verify** for the cheap hermetic things. A hard **security NON-GOAL**: no new
AssumeRole principal, no trust-policy widening, no provider-SA token mount, no
probe pod. Reuse existing assets: `crossplane-claim-verify` (after a mandatory
v2 port), `scripts/wait-for-claim.sh`, `scripts/irsa_trust_validator.py`,
chainsaw per-run-ID prefix + cleanup.

**What round-2 corrected (the ten things that change the plan).**

1. **Identity is `source: IRSA`, NOT `InjectedIdentity`.** The synthesized plan
   was factually wrong. `crossplane/providerconfig/00-clusterproviderconfig.yaml:41`
   is `source: IRSA` on a `ClusterProviderConfig` of group `aws.m.upbound.io`.
   `InjectedIdentity` belongs to a *different* provider (provider-kubernetes, the
   spoke-Secret write path), not AWS. The falsifiable identity gate is now:
   `source: IRSA` **AND** no static-cred AWS ProviderConfig **AND** no
   `AWS_ACCESS_KEY_ID` in the provider pod env. The caller-ARN==expected check is
   **infeasible in-band** and is demoted to an optional out-of-band audit.
2. **Workflows CAN be edited here** (via jentic Contents-PUT / `ext-github`), so the
   "can't edit workflows" premise is removed. **But CI is NOT the trigger
   (correction #2).** GitHub Actions runs at PR/commit time, which is DECOUPLED from
   the actual build/bring-up — so verification is coupled to the **build**: the
   bring-up procedure (`apply-and-verify` / cluster-creation flow, and the spoke
   reconciliation path) **invokes `tests/live/run.sh` as its final phase**. That is
   the real "every bring-up" guarantee. Three execution contexts, kept strictly
   separate: **push/PR CI = static no-cluster checks only**; **build-time = the full
   live suite, on by default, all-skipped ⇒ RED**; **`workflow_dispatch` = kind
   render/admit + ad-hoc live runs, never auto-triggered**. Anything needing a
   cluster (even kind) is `workflow_dispatch`-only (matches chainsaw.yml /
   terraform-test.yml; AGENTS §6.7). **The on-every-bring-up trigger IS deliverable**
   as a build-flow invocation. Requirement #1 is no longer at risk.
3. **The coverage deriver must parse Pipeline-mode compositions** (MR kinds at
   `spec.pipeline[].input.resources[].base.kind`, keyed on group+kind) — verified
   working below. It ships **with a fixture-test and WARN-ONLY first**. IAM
   per-component attribution is dropped (irsa.tf is one flat policy).
4. **`simulate-principal-policy` is a FLOOR only,** not the completeness oracle —
   the policy is already `Resource:"*"` so simulate is circular. The real
   completeness signal is **drive-the-controller**. The ceiling must **narrow**
   `eks:*`/`rds:*` to derived verb lists with capped, expiring justifications and
   a **non-deferred fail-on-unexercised-grant tier**.
5. **`crossplane-claim-verify` is v1-claim-shaped** (`spec.resourceRefs`, claim
   kind) but the repo is v2 namespaced-XR with no claim. **Porting it to v2 is a
   prerequisite** before it can be mandatory; otherwise it verifies zero MRs.
6. **The reaper is friendly-fire** on the shared ephemeral account → needs an
   **account-mutex** + age-floor ≥ slowest build (≥45 min) + a structural
   *deny-list* account guard (not an allow-match that bricks on rotation).
7. **The spoke trigger is GitOps-native** — key off the spoke XR reaching Ready
   on the **hub** + git-desired-state, not an imperative apply GitOps would
   revert.
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
ships the visibility/enforcement scaffold, then deepens after-the-fact coverage,
then isolation/reaper, then the bring-up behavioral catch, then negatives + the
spoke trigger, then hardening.

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
| **BRING-UP** | **real cluster, invoked BY the build** — on by default as the final phase of `apply-and-verify` / cluster-creation, cheap (sec–min); NEVER push/PR-triggered | drive the real controller **under `source: IRSA`**; instantiate-and-verify cheap **hermetic** kinds; guard-fired negatives | mutating — needs hard isolation (§8) |
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
The BRING-UP behavioral suite is **not** in CI at all: it is invoked by the build.

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

### 3.4 The verifier/reaper identity is itself a least-privilege deliverable (security C2.2, the merge's systemic flaw)
The overhaul hardens Crossplane's identity but the test/verifier identity silently
needs `iam:SimulatePrincipalPolicy`, `cloudtrail:LookupEvents`, `accessanalyzer:*`,
`servicequotas:Get*`, `resourcegroupstaggingapi:GetResources`, and cross-service
deletes for the reaper. The plan ships an **explicit allowlist of the verifier/
reaper identity's read+delete actions as a first-class artifact**, the ceiling lint
(§3.3) covers *that* role too, and the reaper identity is **scoped tightly** (it is
new blast radius). Otherwise the net effect is to move the over-privileged
principal from Crossplane to the CI key on the account that also hosts the mgmt
cluster.

## 4. Build-coupled trigger + disable switch + anti-silent-regression (resolves round-2 #2, #5; constraint corrections #1 & #2)

### 4.1 The trigger is the BUILD, not CI — three execution contexts (corrections #1 & #2; resolves sre C3, qa-guru C1)
Workflow files **can** be created/edited here via **jentic Contents-PUT
(`ext-github`, `op_12ee1daaad73b14b`)** — correction #1 (the git-push OAuth token
and GitHub MCP write tools lack `workflow` scope; jentic does not). **But CI is the
wrong place to run verification (correction #2):** GitHub Actions fires at PR/commit
time, which is DECOUPLED from when the cluster is actually brought up, and standing
up a cluster (even kind) in push/PR CI is forbidden. So the trigger **moves out of
CI and into the build**, and the layers are re-keyed into **three strictly-separate
execution contexts**:

- **Push/PR CI (automatic) — STATIC, NO CLUSTER.** Only no-cluster checks run here:
  lints, kubeconform/schema, helm-template render asserts, the derived-coverage-
  manifest **PARSE** (static, §4.5), the no-wildcard IAM ceiling lint (§3.3),
  `irsa_trust_validator.py` static sweeps (§7), AND a **static invariant check that
  the live suite is wired into the bring-up and on-by-default** (§4.2). These live in
  `tests/unit/run.sh` (already push-gated by the light push workflow `unit-tests.yml`)
  and need no `workflow` scope. **No cluster is ever stood up on push/PR.**
- **Build-time (coupled, on by default) — THE FULL LIVE SUITE.** The bring-up
  procedure itself — the operator/agent's `apply-and-verify` / cluster-creation flow,
  and the spoke reconciliation path (§10) — **invokes `tests/live/run.sh` as its
  final phase**. This is requirement #1's real "every bring-up" guarantee: it is the
  build running the suite, not a CI check waiting for a commit. **`all-skipped ⇒ RED`
  and the `expect-full` floor apply HERE.** A jentic-landed `apply-and-verify` /
  bring-up flow wires this invocation in (the committable half is `tests/live/run.sh`
  + its self-test; the build-flow wiring is the landable other half, §12).
- **Manual dispatch (`workflow_dispatch`) — kind + ad-hoc.** Kind-based render/admit
  and any ad-hoc live runs are `workflow_dispatch`-only, **never push- or
  PR-triggered**, matching `chainsaw.yml` / `terraform-test.yml` (AGENTS §6.7). These
  are landed via jentic but stay manual.

**The push/PR check NEVER relies on a cluster run.** It at most verifies *static
evidence* — that a recorded green build-suite result exists for the deployed
SHA/cluster (§4.3) — but the PRIMARY anti-regression guarantee is the **build
coupling**, not the PR check. Correctness is never gated on PR-time cluster work.

The new `tests/unit/test_*.sh` static-gate files must be added to **both**
`tests/unit/run.sh` and `unit-tests.yml` in the same PR; `unit-tests.yml` is a light
**no-cluster** push workflow editable via normal push, and the §-sync catch-all step
is kept as backstop. `tests/live/run.sh` learns the action via an explicit
`LIVE_MODE=mutating|readonly` arg (passed by the **build flow**, not a PR check):
`verify` ⇒ `readonly` (after-the-fact only), `apply-and-verify` ⇒ `mutating`
(BRING-UP allowed). A unit test asserts `verify ⇒ readonly` so an agent's frequent
`verify` calls never provision NLBs/IAM/secrets (sre C3 second half; qa-guru m1).
The mutating instantiate-path of `crossplane-claim-verify` runs only under
`mutating`.

### 4.2 Default-ON (at build-time), and the default is a *tested invariant*
Default = ON, where "on" means the **bring-up invokes the live suite** (§4.1), not
that a CI check is enabled. Disable only via `LIVE_VERIFY=0` / per-check
`LIVE_SKIP=...`. Two tested invariants, both checkable **statically on push** (no
cluster):
- The on-by-default value (in the orchestrator's **own committed config** — the
  single source the test reads; any `workflow_dispatch` default is advisory,
  k8s-expert m4) is literally `enabled`, so flipping it is a red diff.
- **The live suite is wired into the bring-up.** A static lint asserts the committed
  `apply-and-verify` / bring-up flow invokes `tests/live/run.sh` as its final phase
  (grep the flow definition for the invocation) — so silently un-coupling the suite
  from the build is a red push diff. This is the static half that protects the
  build-coupling guarantee without needing a cluster at push time.

The master kill-switch is guarded: `LIVE_VERIFY=0` makes the banner **RED and exits
non-zero** unless a top-level `disable_all` register entry (reason/owner/expires)
exists. **All-skipped is RED by construction** — enforced at build-time when the
suite runs. (Must-not-weaken, every reviewer.)

A note on the `live-verify` artifact name: where this plan says "`live-verify`
workflow," it means a **`workflow_dispatch`-only** GitHub Actions workflow for
**manual/ad-hoc** live runs (context 3) — NOT a push/PR-triggered job and NOT the
thing that delivers the every-bring-up guarantee. The every-bring-up trigger is the
**build invoking `tests/live/run.sh`** (context 2), wired into the committed
bring-up flow, never an Actions trigger. Cluster-requiring workflows are landed via
jentic but stay `workflow_dispatch`-only (correction #2).

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
  classification at all is treated as `expect-full` (loud, not silent-green). The
  PRIMARY anti-regression guarantee is the **build coupling** (the bring-up invokes
  the suite — §4.1/§4.2), not a PR check. As a **secondary static backstop** only,
  a push/PR check may verify *static evidence* that a recorded green build-suite
  result exists for the deployed SHA/cluster (a committed live-evidence marker per
  HEAD SHA); a missing marker is a push WARN/FAIL on **that static evidence**, never
  a PR-time cluster run. This keeps "coupled to the change" anchored to the build —
  not reduced to "coupled to whoever remembers to dispatch" — while never gating
  correctness on PR-time cluster work (correction #2).

### 4.4 The executed-test FLOOR / skip-promotion (the load-bearing part)
Three skip states (not two): **not-applicable** (no kube-API at all — informational,
allowed); **phase-not-applied** (the git desired-state does not declare this kind
for this cluster — counted SKIP, allowed); **precondition-absent-but-expected-
present** (git declares it, the phase applied, it's missing — **FAIL**; literally
blocker #5's shape). Under `expect-full`, any SKIP of an expected resource is
promoted to FAIL; `run.sh` exits non-zero if executed checks for the present phase
fall below a declared floor or if *every* check skipped. **Floor = zero tolerated
skips for any `expect-full` resource — non-negotiable** (only the register cap N
and grace window are tunable; qa-guru m6). The conditional-resource rule (DevX C1):
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

- **Exact extraction path** (verified working this session against all four comps):
  ```
  yq '.spec.pipeline[]?.input.resources[]? | select(.base) | .base.apiVersion + "/" + .base.kind'
  ```
  This produced exactly the MR set and **no pollution** — `ClusterProviderConfig`
  (the `providerConfigRef.kind`), the function `Input`/`Resources` wrapper kinds,
  and the `Composition` doc kind are all excluded because they are not under
  `.input.resources[].base`. A named, tested **exclude-list** (`ClusterProviderConfig`,
  `ClusterSecretStore`, `Input`, `Resources`, `Composition`) is kept as defense.
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
- **Ship with a fixture-test of the deriver itself** (feed it the four committed
  comps, assert the exact group/kind set above) and **WARN-ONLY (print, exit 0)
  until that fixture-test is green** — a mis-firing gate that reds every PR is
  *worse* than the hand manifest (DevX C1, must-not-weaken). The mapping test
  requires a **real referenced check** whose `--dry-run` fixture **names the
  registered group/kind in its apply payload** (DevX C2 — a mechanical floor under
  the "any green test counts" goodwill), not merely a tier declaration.
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
is the only durable disable: each entry needs reason/owner/expires; a unit test
fails if any field is missing, any `expires` is past, or any runtime skip is
unregistered. **Cap the register at N** (set N=12 with headroom; the cap message
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
  round-2 #9; k8s-expert M1).** All 12 repo policies are Audit today (verified). An
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
- Phase 3: walk the v2 composed-resource ref path — **verify the actual field on
  the running cluster at spike time** (v2 surfaces refs under
  `spec.crossplane.resourceRefs` / `status` depending on version; do NOT assume
  `spec.resourceRefs`). Assert every composed MR `Synced=True` + `Ready=True`.
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

- **Hub-side watch, not imperative apply:** the spoke trigger is part of the
  **bring-up/reconciliation path, not a CI job** (correction #2). The spoke
  reconciliation flow watches `XPlatformCluster` / `XSpokeAccess` on the **hub** (a
  hub object — observable from the hub kube-API) for `Ready=True` transitions and,
  on transition, **invokes `tests/live/run.sh`** for the spoke AFTER-THE-FACT + (if
  reachable) the e2e — the same build-coupled invocation as §4.1 context 2, not a
  push/PR Actions trigger. The committable half is the hub-side watch/invoke script
  + self-test; an ad-hoc rerun is available via the `workflow_dispatch`-only lane.
- **`expect-full` for the spoke derives from git desired-state** (§4.3): a spoke XR
  committed under `clusters/` makes the spoke's resources `expect-full` even when
  ArgoCD (not a human `apply-and-verify`) synced them — so an ArgoCD-synced spoke
  that silently never provisions is a **FAIL**, not auto-skip-green. This closes
  the GitOps hole the synthesized plan's "imperative apply sets expect-full" model
  left open (k8s-expert M3, sre M1).
- **The hub→spoke curl e2e is CONDITIONAL on the spoke-API-from-CI operator
  dependency (§14).** Always-available substitute (the committed default): hub-side
  XR-Ready + AccessEntry present + ArgoCD `connectionState: Successful` + (proxy)
  the app-controller AssumeRole success in CloudTrail. The curl e2e (sync an app
  using a cluster-scoped IngressClass → external-dns writes the Route53 record →
  `curl https://hello.platform.<domain>` returns 200 → Keycloak Ready against RDS)
  ships **when** the CI-spoke-API path is confirmed; run from CI/in-cluster, never
  the sandbox (strict-MITM egress 503s a private-CA endpoint — read the 503 body to
  distinguish gateway from app). The `InjectedIdentity` provider-kubernetes `hub`
  ProviderConfig (crossplane-phase3.tf) is the spoke-Secret write path relevant
  here — distinct from the AWS IRSA discussion in §3.

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

| Change | Committable half | Other half | Now deliverable? |
|---|---|---|---|
| `apply-and-verify` → `tests/live/run.sh` trigger (build-coupled, NOT CI) | `tests/live/run.sh` + its self-test | the bring-up/build-flow wiring that invokes it (committed build flow; jentic for any helper workflow) | **YES — via build-flow wiring + jentic** (corrections #1 & #2) |
| Spoke reconcile-completion hook | the hub-side watch/invoke script + self-test | wiring the script into the reconciliation/bring-up path | **YES — build-flow wiring** |
| `workflow_dispatch`-only ad-hoc live + kind render/admit lane | the gate/check logic | the `workflow_dispatch`-only workflow (never push/PR-triggered) | **YES — via jentic** |
| Push/PR static gate (lints + coverage parse + ceiling + wired-and-on-by-default invariant + HEAD-SHA static-evidence backstop) | the `test_*.sh` static checks | the per-step add in the no-cluster push workflow | **YES — normal push** |
| Spoke kube-API read from CI (the curl e2e / behavioral #1/#6) | the check logic | CI reaching the **private-CA spoke API** | **UNCONFIRMED — operator dependency** (§14) |
| `unit-tests.yml` step list for new gate files | the `test_*.sh` + `run.sh` wiring | the per-step add | **YES — normal push** (light workflow) |

The only genuine residual operator dependency is the **spoke-API-from-CI** path
(behavioral #1/#6 / curl e2e). Everything the synthesized plan stranded on "can't
edit workflows" is now landable via jentic.

## 13. Corrected blocker → layer coverage matrix (all 8 + the subnet-tag blocker)

This matrix is the **acceptance criterion**, mirrored into `ai/TESTING-PLAN.md`
with a unit test that every row names a test file that **exists AND carries the
tag the row's Push/bring-up column implies** (qa-guru m5 — existence alone allows a
row to point at a lint). Rows a layer cannot physically observe are corrected.

| # | auto-012 blocker | Caught by — assertion / environment | Push or bring-up |
|---|---|---|---|
| 1 | EKS `authenticationMode=CONFIG_MAP` | AFTER-THE-FACT: `describe-cluster` mode includes `API` **+ behavioral** hub app-controller authenticates to spoke (*conditional on §14 spoke-API*; fallback = CloudTrail AssumeRole success); PRE-FLIGHT: **composition-text lint** that base is `API`/`API_AND_CONFIG_MAP` (NOT an admission negative — hardcoded, k8s-expert M2) | both |
| 2 | crossplane IRSA missing `iam:TagOpenIDConnectProvider` | PRE-FLIGHT: simulate **floor** (allowed for the action) + narrowing ceiling; BRING-UP: real spoke-access XR provisions the OIDC-tagging path under `source: IRSA`, no `AccessDenied` — **the real completeness signal** (simulate cannot see unknown-missing) | both |
| 3 | missing `iam:UpdateAssumeRolePolicy` | same as #2 (simulate floor + real-controller positive) | both |
| 4 | missing `iam:GetRolePolicy` | same as #2 | both |
| 5 | missing all `rds:*` → RDS never provisioned | PRE-FLIGHT: simulate **floor** for the rds set (slow → no instantiate); AFTER-THE-FACT: `describe-db-instances` + `XDatabase` Ready (`expect-full` from git ⇒ absent = FAIL) | both |
| 6 | ArgoCD app-controller SA missing IRSA | AFTER-THE-FACT **behavioral**: controller `AssumeRoleWithWebIdentity` succeeds / spoke registration works (annotation-presence is a lint; *conditional on §14*); PRE-FLIGHT: `test_argocd_controller_irsa.sh` (exists) on **both** SAs; AppProject/RBAC deny-by-default for tenant scope (NOT a blanket Kyverno-Enforce mandate) | both |
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
2. **Spoke-API-from-CI (the one real operator dependency).** Behavioral #1/#6 and
   the curl e2e depend on CI reaching the private-CA spoke API. If only
   `kube-diagnose.yml`-style read paths exist, those assertions fall back to
   CloudTrail-proxy + hub-side config — marked conditional in §13. **Owner: can CI
   reach the spoke kube-API?**
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
   periods; acceptable, but confirm the owner prefers it to an external store.

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
- [ ] The **bring-up/build flow** (not a push/PR CI job) invokes `tests/live/run.sh`
  on `apply-and-verify` (build-coupled, on by default); push/PR runs static-only; any
  cluster/kind/ad-hoc lane is `workflow_dispatch`-only; a static push lint asserts the
  suite is wired into the bring-up and on-by-default; `verify ⇒ readonly`; the
  HEAD-SHA live-evidence marker is a static push backstop, never a PR-time cluster run.
- [ ] Verifier/reaper identity has an explicit ceiling-linted allowlist.
- [ ] False-fail SLO measured into committed `FLAKE_LOG`; breach auto-quarantines;
  per-check red ≠ bundle red; wall-clock **budget** gate distinct from the ceiling.

## 16. Phased rollout — front-load the P0 spike

Stacked, independently-mergeable PRs; each ships tests red-first (or the one-time
grant-removal demonstration for already-fixed blockers, §7) and passes adversarial-
subagent review. **The riskiest mechanism is proven END-TO-END before anything is
built on it.**

- **P0 — Spike (gates everything).** On the live hub: a real v2 XR reconciles
  under `source: IRSA`; the **v2-ported** skill descends composed MRs; the in-band
  identity gate fires; simulate returns the right allow/deny with correct
  `--resource-arns`. Includes the v2 claim-verify port (§9.1). If P0 fails, the
  plan changes shape.
- **P1 — Visibility + both-layer enforcement (cheap/static).** Pipeline-mode
  coverage deriver + fixture-test (**WARN-ONLY**); two-sided IAM floor/ceiling with
  narrowing + capped annotations; simulate floor; `tests/live/run.sh` skeleton
  (inverted skip, executed-floor, `expect-full`-from-git, default-as-tested-
  invariant, master-switch guard, exit-code contract, `LIVE_MODE`); SKIP_REGISTER +
  set-based gate; the push-time **static** gate in `tests/unit/run.sh` (incl. the
  wired-into-bring-up + on-by-default invariant lints and the HEAD-SHA static-evidence
  backstop); the **build-flow wiring** that makes the bring-up invoke
  `tests/live/run.sh` (build-coupled, not CI); and the `workflow_dispatch`-only
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
3. **"Can't edit workflows" premise removed.** Enforcement is now layered (the
   push-time static `run.sh` gate + a `workflow_dispatch`-only `live-verify`
   ad-hoc/kind lane landed via jentic); the on-by-default trigger is deliverable as
   **build-flow wiring** (not CI — see §18, correction #2); requirement #1
   de-stranded. (constraint corrections #1 & #2; sre C3, qa-guru C1)
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

## 18. Changes from the finalizer draft (correction #2)

The earlier finalizer draft relied on GitHub Actions (push/PR + a `live-verify`
workflow) as the verification trigger. Correction #2 decouples this: GitHub Actions
fires at PR/commit time, which is independent of the actual build/bring-up, and
standing up any cluster (even kind) in push/PR CI is forbidden. **Only the
trigger/where-it-runs changed; every round-2 resolution and every other property is
intact.** What moved:

1. **Trigger moved from CI to the BUILD.** The every-bring-up guarantee is now the
   bring-up procedure (`apply-and-verify` / cluster-creation flow + the spoke
   reconciliation path) **invoking `tests/live/run.sh` as its final phase** — not a
   push/PR check waiting on a commit. "Coupled to the change" = coupled to the build
   that applies it. (§4.1, §4.2, §10)
2. **Three strictly-separate execution contexts made explicit** (§2, §4.1):
   *push/PR CI = static, no-cluster only*; *build-time = the full live behavioral +
   negative + precondition suite, on by default, where `all-skipped ⇒ RED` and the
   `expect-full` floor live*; *`workflow_dispatch` = kind render/admit + ad-hoc live
   runs, never auto-triggered*.
3. **Static-only push set named** (§4.1): lints, kubeconform/schema, helm-template
   render asserts, coverage-manifest PARSE, no-wildcard IAM ceiling lint,
   `irsa_trust_validator.py` static sweeps, AND a static invariant that the live
   suite is wired into the bring-up and on-by-default.
4. **Kind render/admit reclassified to `workflow_dispatch`-only** (§2) — no-cluster
   `helm template`/`kubeconform` render asserts stay on push as lints; anything that
   stands up a kind cluster is manual-dispatch only (matches chainsaw.yml /
   terraform-test.yml; AGENTS §6.7).
5. **Anti-silent-regression de-coupled from PR-time cluster work** (§4.3): the
   primary guarantee is the build coupling; the push check at most verifies *static
   evidence* of a recorded green build-suite result for the deployed SHA/cluster.
6. **Artifact-name disambiguation** (§4.2 note, §12 ledger, §15, §16): "`live-verify`
   workflow" now denotes the `workflow_dispatch`-only ad-hoc lane; the trigger half
   in the ledger is build-flow wiring, not an Actions trigger.

**The four invariants re-confirmed under the build-coupled model:** *on by default*
(the bring-up invokes the suite by default; a static push lint asserts the wiring +
the on-by-default config value), *disable-able but not disabled* (only via
`LIVE_VERIFY=0` / `LIVE_SKIP` / SKIP_REGISTER with reason/owner/expires; master
kill-switch is RED-and-non-zero unless registered), *all-skipped ⇒ RED* (enforced
at build-time when the suite runs), and *coupled-to-the-change* (coupled to the
build that applies the change). No security/correctness property was weakened; no
probe pod or new AssumeRole principal was introduced.

---

*End of FINAL plan. PLAN-ONLY — no code, tests, fixtures, or workflows were
created or modified except this file. Every repo fact cited here was re-verified
against the tree this session.*
