# Synthesized Test-Overhaul Plan — k8s-platform

> **Status: PLAN ONLY.** This document creates and edits no code, tests,
> fixtures, or workflows. It synthesizes PLAN-A, PLAN-B, PLAN-C and the nine
> round-1 adversarial reviews into one coherent, concrete plan, and resolves
> every CRITICAL finding the panel converged on.
>
> Author: lead test architect. Inputs: `plans/PLAN-{A,B,C}-*.md`,
> `reviews-round1/{sre-reliability,security-negative,devx-maintainability}-on-PLAN-{A,B,C}.md`.

---

## 0. Diagnosis (the part all three plans and all nine reviews agree on — preserved)

The suite conflates **lints** with **tests**. `tests/unit/*.sh` are
`yq`/`grep`/`helm template` assertions over committed YAML/TF — they prove a
manifest *says* X, never that X *works*. `tests/chainsaw/**` runs on **kind**
with a fake cloud and, when it does touch real AWS, uses the **account-admin
GitHub-Actions keys** wired into a static-cred `ClusterProviderConfig`
(`tests/chainsaw/run.sh` ~231-293) — strictly *more* privilege than production.
So the entire class "we told the platform to build X, it never actually built /
doesn't work under the restricted Crossplane identity" is invisible until a
downstream dependent trips over it live. auto-012 paid for this with **8 live
blockers found one-at-a-time** (OI-2026-06-07-6).

The empty cell is **real cloud × restricted identity**. The fix is **behavioral
verification on the real cluster, with Crossplane reconciling under its own
restricted IRSA role, on by default, coupled to the change** — augmented with
**negative/precondition** tests, a **least-privilege ceiling**, and an
**anti-silent-regression** mechanism. This center is non-negotiable and survives
verbatim into the synthesis.

---

## 1. Test taxonomy — three operational buckets (not six tiers)

DevX reviews (all three) flagged that a 5–6 tier vocabulary with sub-modes
(L2a/L2b, T0–T5, two axes) is more ontology than the team sustains and that the
source plans themselves placed the same contract in 2–3 tiers inconsistently.
We collapse to **three buckets keyed on *where the test runs*** (the thing that
actually constrains an author), and carry the richer "fails-for-the-right-reason"
reasoning as guidance, not as names.

| Bucket | Runs where / when | Was (A / B / C) | What it proves | Honest limit |
|---|---|---|---|---|
| **PRE-FLIGHT** | local sandbox + kind, every push, seconds | A:L0,L1 · B:L0,L1,L2 · C:T0,T1,T2 | manifest schema-valid; composition renders; admission *shape*; IAM policy *text*; the **no-wildcard ceiling lint** and **simulate-principal-policy** static checks | fake/no cloud; admin or no identity; **never** evidence the thing built |
| **BRING-UP** | real cluster, **on by default at every apply-and-verify**, cheap (sec–min) | A:L2b,L3,L4 · B:L3,L4 · C:T4 | drive the **real controller under its own IRSA**; instantiate-and-verify cheap resources; live negatives/preconditions; guard-fired assertions | mutating — needs hard isolation (§7) |
| **AFTER-THE-FACT** | real cloud, post-apply, read-only `Describe*` | A:L2a · B:L5 · C:T3 | the slow/standing things the bring-up already built (EKS ~20min, RDS) exist *and behave* | read-only; cannot exercise the create-path permission (so see §5 EKS create-path note) |

Two cross-cutting properties, expressed as **tags** on a test, not as new tiers
(DevX-A M1, DevX-B M4):
- `real-irsa` — the assertion depends on the restricted identity (§4).
- `expect-full` — set by a bring-up that *claims* to have built the resource;
  turns a SKIP of that resource into a FAIL (§3, the anti-silent-regression core).

Honesty rename: relabel `tests/unit/` conceptually as **lints** (a README + a
`lint`/`test` tag), **not** a physical directory move. DevX-A M2 showed a
`tests/unit/`→`tests/lint/` rename touches `run.sh`, `unit-tests.yml` (§6.16
sync), pre-commit hooks, SPEC-S6, ~60 files and their `lib/`/`fixtures/` — high
blast-radius for a conceptual win. The value is naming, achievable without the
move; if a physical move is ever wanted it is its own isolated PR with the
run.sh↔workflow sync check, never bundled.

---

## 2. The drive-the-real-controller-under-IRSA mechanism (resolves CRITICAL #1 and #2)

**The single most important mechanism, and the one the panel most sharply
corrected.** All three security reviews and two DevX reviews proved against
`terraform/management/irsa.tf:174` that the provider role's trust policy permits
exactly one subject: `crossplane-system:upbound-provider-family-aws`
(`InjectedIdentity`). Therefore:

### 2.1 "Under the restricted IRSA role" = drive the REAL controller. No probe SA.
A probe pod/SA **cannot** `AssumeRoleWithWebIdentity` into that role — its OIDC
`sub` won't match. A probe would get a **false `AccessDenied` that mimics the
real blockers** (indistinguishable from blocker #8), and the only way to make it
pass — widening the trust policy to admit a probe subject — *is itself the
privilege bloat this overhaul exists to catch* (security-B C1, sre-B M2). So:

- The **only** sanctioned mechanism is: apply a **real, throwaway, run-id-prefixed
  XR** (Crossplane v2 — XR/composite, **not** a v1 "claim"; DevX-C m6) and let the
  **provider controller reconcile it under its own injected identity**, then assert
  `Synced`/`Ready` + the real cloud resource via the existing
  `crossplane-claim-verify` skill (+ `scripts/wait-for-claim.sh`). This is
  faithful, adds **zero** new trust surface, and is exactly what the underused
  skill already does — made mandatory and automatic.
- **NON-GOAL (explicit, per security-B C1):** *this overhaul does not create any
  new AssumeRole principal, does not widen any role's trust policy to admit a test
  subject, and does not mount/copy the provider SA's projected token into a probe
  pod.* PR work that tries any of these is out of scope and must be rejected in
  review.

### 2.2 Identity assertions — make "under IRSA" falsifiable (resolves security-A C1)
"Run under real IRSA" is unfalsifiable unless asserted, and the low-friction wrong
path (reuse `run.sh`'s admin-cred ProviderConfig against a real cluster) would go
green while proving nothing. Every BRING-UP `real-irsa` test must, before
trusting a result, assert all of:
1. The **active ProviderConfig is `InjectedIdentity`/IRSA** — there is **no
   static-credential ProviderConfig** layered over it and **no `AWS_ACCESS_KEY_ID`
   in the provider pod's environment**. (Plus a PRE-FLIGHT lint that fails if any
   live-cluster test path sets `AWS_ACCESS_KEY_ID` for the provider.)
2. The **caller identity Crossplane actually used == the expected IRSA role ARN** —
   captured from the provisioned resource's CloudTrail `userIdentity.arn`, or from
   `aws sts get-caller-identity` run by a pod using the provider SA. Not the admin
   principal.

### 2.3 The IRSA *negative* without a crippled twin or live role-mutation
The blockers' missing actions (`iam:Tag*`, `iam:UpdateAssumeRolePolicy`,
`iam:GetRolePolicy`, all `rds:*`) are **already granted** (verified in
`irsa.tf:80-104`). You cannot produce a live `AccessDenied` for them without
either revoking a grant from the live shared role mid-test (dangerous, races
Terraform drift-correction) or maintaining a deliberately-crippled twin role
(a second principal to keep in sync = audit noise + attack surface). The panel's
resolution (security-B C2, devx-A C4, sre-A M1):

- **Completeness lives at `aws iam simulate-principal-policy`** against the *real*
  Crossplane role ARN, asserting `allowed` for the exact action set each
  Composition needs (derived per §6). Static, free, deterministic, orphan-free,
  and — critically — **works for the expensive kinds (EKS/RDS) without
  instantiating them**. This is what would have caught the `rds:*` and `iam:Tag*`
  gaps at push time.
- The **behavioral fail-closed proof** is a single positive end-to-end (the real
  XR provisions); when a real `AccessDenied` *does* occur, the negative assertion
  keys on the **verbatim `AccessDenied` substring naming the action** in the MR's
  `status.conditions[].message`, never on bare `Synced=False` (which is also the
  steady state for a not-yet-reconciled or unrelated-dependency-failed MR —
  security-B C2, sre-A M2).

---

## 3. On-every-bring-up + explicit-disable + anti-silent-regression (resolves CRITICAL #4, #5, #6)

This is the mechanism for user requirements 1, 2, 6. The panel found the source
plans' versions **unmet**: `skip()` = `exit 0` and `tests/integration/run.sh`
exits 0 whenever `FAIL==0` (verified — see grounding), so on a rotated/empty
account env-absent skips are the *steady state* and 6/8 spoke blockers auto-skip
on hub-only bring-ups, all reading green.

### 3.1 One entrypoint, three properties
A single orchestrator **`tests/live/run.sh`** (modeled on, but with **inverted
skip semantics** vs, `tests/integration/run.sh`) runs the BRING-UP + AFTER-THE-FACT
buckets against whatever cluster the kubeconfig/AWS creds point at. Invoked:
- automatically at the **end of every `apply-and-verify`** (and every spoke
  bring-up — §8), and
- by `crossplane-claim-verify` as the per-XR unit, and
- by developers via the §9 fast loop for test *logic*.

### 3.2 Default-ON, and the default is a *tested invariant*
- Default = ON. Disable only via a single explicit switch (`LIVE_VERIFY=0` /
  per-check `LIVE_SKIP=...`), **not set now**.
- **The default value itself is a push-time tested invariant** (DevX-C C3): a unit
  test asserts the on-by-default value (in the committed config the orchestrator
  reads, and in any `workflow_dispatch` input default) is literally `enabled`.
  Flipping the default is then a red diff, not a one-character silent kill.
- **Master kill-switch is guarded** (sre-B C3): `LIVE_VERIFY=0` makes the summary
  banner **RED and exits non-zero** unless a top-level `disable_all` register
  entry (reason/owner/expires) exists. "All-skipped" is red *by construction*.

### 3.3 The executed-test FLOOR / skip-promotion (the load-bearing part)
Three skip states, not two (DevX-B C3, security-A M1, sre-A M4):
- **not-applicable** — no cluster/kube-API at all (e.g. sandbox, private-CA
  §6.26): informational, allowed.
- **phase-not-applied** — the phase that builds this resource was legitimately not
  applied this run: counted SKIP, allowed.
- **precondition-absent-but-expected-present** — the bring-up applied the phase
  that *should* have built this resource, but it's missing: **this is a FAIL**, not
  a skip. It is literally blocker #5's "silent never-provisioned" shape.

The distinction is driven off **what the bring-up intended** (the
`apply-and-verify` knows which phase it applied → sets `expect-full` for that
phase's resources), **not** off "is the resource there" (the thing under test).
Concretely: under `expect-full`, any SKIP of an expected resource is promoted to
FAIL, and `run.sh` exits non-zero if the count of *executed* checks for the
present phase is below a declared floor, or if *every* check skipped. A unit test
(`phase=test` style) asserts the orchestrator's tabulation: `all-skip ⇒ non-zero`,
`precondition-abort ⇒ non-zero`, `expect-full + expected-resource-skipped ⇒ FAIL`.

### 3.4 Enforcement routed through `tests/unit/run.sh` — NOT a new workflow
The panel flagged the source plans' enforcement as **stranded**: it depended on a
`live-verify` *verifier workflow*, but this environment **cannot create/edit
`.github/workflows/*`** (OI-2026-06-05-6, confirmed). So (sre-B C2, DevX-B C2):
- The skip-count/coverage **GATE lives inside `tests/unit/run.sh`** (already
  push-gated by the existing `unit-tests.yml`) + committable scripts. It computes
  skip-count-on-HEAD vs a committed `tests/live/SKIP_BASELINE` and fails if it rose
  without a matching `SKIP_REGISTER.yaml` diff. No workflow-scope dependency.
- The disable register (`tests/live/SKIP_REGISTER.yaml`) is the only sanctioned
  durable disable; each entry needs `reason/owner/expires`; a push-time unit test
  fails if any field is missing, any `expires` is past, or any runtime skip is not
  in the register. **Cap the register** (fail if > N active entries) and require an
  `OI-` cross-link for any disabled *security* check (IRSA/RBAC/Kyverno-enforce)
  (security-B M4). `expires` escalates warn→fail after a grace window so a pure
  calendar event doesn't red unrelated PRs (DevX-B M1).
- Keep `tests/unit/run.sh` ↔ `unit-tests.yml` in sync via the §6.16 catch-all
  pattern from day one (DevX-B m5).

### 3.5 The coverage manifest is DERIVED, not hand-maintained (resolves CRITICAL #6)
Hand-edited manifests get edited to go green (cf. §6.16's 17/39 drift; security-C
C4; DevX-C C2). The expected-coverage set is **generated**, the human maintains
only the *registry* of which test defends which kind:
- Derive the provisioned-thing set from **`crossplane/**`** (XRD/Composition
  `resources[].base.kind` = the MR kinds) **+ `terraform/management/irsa.tf`** (the
  action set per component). Extend the **existing `test_iam_required_actions.sh`**
  pattern (which already diffs irsa.tf actions against component fixtures — DevX-A
  C1) rather than inventing a parallel file.
- `test_live_coverage.sh` (PRE-FLIGHT, every push) fails red if **any** derived
  MR-kind/action lacks a referenced live test. Side-effect resources that don't
  appear in `resources[]` (the untagged subnet tag, a controller-created LB) go in
  a small **explicitly-justified `extra:` allowlist with a required `reason:`**,
  itself reviewed (sre-C M3). This makes *absence of coverage* CI-red at authoring
  time — the only form of "coupling" the §0 philosophy respects. The mapping test
  must require a **real** referenced check, not merely a tier declaration (DevX-B
  M5): `cheap`→a BRING-UP check keyed to the kind; `slow`→an AFTER-THE-FACT check.

---

## 4. The no-wildcard CEILING + simulate-principal-policy (resolves CRITICAL #2's second half)

Every security review independently raised the **permission-bloat ratchet**: a
completeness probe that "adds a grant on AccessDenied" rewards breadth, and the
policy is *already* `eks:*` + account-wide `Resource:"*"` on IAM/RDS/EC2. A suite
tuned only to catch *under*-permissioning will systematically *over*-correct and
stamp `iam:*` "verified least-privilege." The counterweight (security-A C2,
security-B C2, security-C C1):

1. **No-wildcard CEILING lint** (PRE-FLIGHT): fails on broad wildcards in the
   Crossplane IRSA policy (`Action:"*"`, `service:*` for high-risk `iam:*`/`rds:*`,
   `*:Delete*` without resource scoping). Convert `test_iam_required_actions.sh`
   into a **two-sided contract**: required actions present (floor) AND no action
   outside a reviewed set (ceiling). Each wildcard requires an inline
   `# lpe-justified:` annotation the test parses — widening is never silent. (Note:
   the test today *accepts* `route53:*` wildcards in its header — that exemption
   must itself become an annotated, reviewed justification.)
2. **A tier that FAILS on UN-exercised grants**: enumerate the actions the BRING-UP
   positive tests actually exercised (CloudTrail for the role's session, or
   access-analyzer "generate policy from CloudTrail") and fail when the granted
   policy contains actions never exercised, beyond the annotated allowlist. Each
   wildcard must *cost* something.
3. **`aws iam simulate-principal-policy`** against the real role for completeness
   (§2.3) — static, no per-test EKS, the honest tool for "is this action effective
   for this principal" (an explicit Deny / SCP / permissions-boundary elsewhere can
   negate a present `Allow`, which a grep cannot see).
4. **Explicit deny tests**: assert the role **cannot** do out-of-scope things
   (create a role outside the platform naming/path scope; `rds:DeleteDBInstance` on
   an out-of-scope ARN). Least privilege is proven by what *fails*. The source
   plans had zero "the role is correctly denied X" tests.

---

## 5. Slow-vs-cheap handling (user requirements 3 & 4)

The cost split is unanimous and preserved: **never recreate the 20-min EKS or the
multi-minute RDS in a test.**

- **Slow / expensive (EKS ~20min; RDS ~5-10min): AFTER-THE-FACT only.** Verify the
  one the bring-up already built. EKS: `describe-cluster` ACTIVE, nodegroup
  healthy, `accessConfig.authenticationMode` includes `API`, AccessEntry for the
  hub app-controller role exists, OIDC provider tagged, shared-VPC subnets carry
  the spoke's `kubernetes.io/cluster/<name>` + `elb`/`internal-elb` tags, spoke
  registered in ArgoCD (`connectionState: Successful`). RDS: `describe-db-instances`
  available + `XDatabase` Ready.
  - **Verify the EFFECT, not just the config** (sre-B M6): blocker #1's real damage
    was the hub couldn't manage the spoke — so also assert the hub app-controller
    identity can actually authenticate to the spoke API (run from CI, kube-API is
    private-CA §6.26). "AccessEntry row exists" ≠ "access works" — that gap is the
    very manifest-says-X vs X-works disease.
  - **Convergence, not a single stale read** (sre-A M5): assertions on mutable
    fields verify `observed == desired AND the XR's last-reconcile is newer than the
    change`, with a bounded wait — not one read that can catch the old value.
  - **EKS create-path permission is still exercised once** (security-A M4): the
    expensive kinds' IRSA create perms are covered by **simulate-principal-policy**
    (§4.3), not by a throwaway cluster — so the most expensive blocker class is not
    untested-by-design while costing zero EKS builds.
  - **Disambiguate upstream-apply-failed from resource-unhealthy** (sre-C M7):
    AFTER-THE-FACT short-circuits with a distinct `UPSTREAM-APPLY-FAILED` status
    when the apply didn't complete, vs `RESOURCE-UNHEALTHY` when it did but is wrong.

- **Cheap (IAM role, OIDC, S3, ASM secret, ESO ExternalSecret, ConfigMap, ArgoCD
  registration, Route53 record, ACM cert, IngressClass): BOTH** — AFTER-THE-FACT
  for the standing instance **AND** BRING-UP instantiate-and-verify under real
  IRSA, with teardown (§7). Generalize the existing `11_platform_secret_e2e.sh`
  shape (XR→wait→cloud exists→behaves→delete→assert torn down) to each XRD.

- **`verify` action stays read-only** (sre-C M2): the mutating BRING-UP bucket runs
  only on `apply-and-verify`; `verify` runs AFTER-THE-FACT + preconditions +
  coverage cross-check only. Agents call `verify` frequently; it must not provision
  NLBs/IAM/secrets each time.

- **No flag-off-by-default RDS** (sre-A m5): RDS is plainly in the AFTER-THE-FACT
  bucket (it's slow), not "opt-in L2b behind a flag nobody flips." When the
  `XDatabase` Composition itself changes, a **path-trigger** requires the live
  evidence (§3.5 / DevX-A m3, c3), not a default-off flag.

---

## 6. Guard-fired negative & precondition tests (user requirement 5; resolves CRITICAL #3)

Every security review and most others found the source negatives risk proving
**"the resource is absent"** instead of **"the GUARD fired."** The rule for every
negative/precondition test:

- **Assert the specific cause/reason, plus a positive control in the same fixture.**
  Apply a *valid* input → it succeeds (proves the harness can detect success at
  all); then the *invalid* input → it is rejected/denied **with the named reason**.
  This makes "rejected" un-fakeable by a broken-everything environment.

Concrete contracts:
- **XRD bad-param.** Schema-shape negatives (missing-required, enum/pattern
  violations) stay **hermetic in chainsaw** (cheap; chainsaw already has
  `must-fail-at-admission` cases — security-C M1: don't re-prove these live).
  BRING-UP negatives are reserved for what *requires* the live cloud/identity to
  falsify: a name that's valid RFC-1123 but violates the IRSA-principal contract
  (#4), an instance type outside the account whitelist. Split **synchronous-reject**
  (assert `kubectl apply` exit≠0 with the field+constraint substring) from
  **async-fail** (assert the XR reaches a *terminal* `Synced=False`/`Ready=False`
  with a specific reason within bounded time and **no** cloud resource was created)
  — Crossplane v2 often ACCEPTS and fails async (sre-A M2; AGENTS §6.8).
- **Keycloak-without-DB precondition.** "Stays NotReady" is insufficient — a pod is
  NotReady for a dozen unrelated reasons (security-A/B/C all flagged this). Require:
  (1) positive control — with the DB present the workload reaches Ready in budget;
  (2) gate-fired — name the **specific** gate (the `wait-for-db` init-container in
  `Waiting`/non-zero exit referencing the DB host, or a named admission rejection)
  **and** assert the service serves a fails-closed response, not 200.
  - **Primary gate = a scoped Kyverno admit-gate** (deterministic, fast, names its
    own reason, the repo idiom — DevX-B M6, DevX-C M5). It MUST be label/namespace
    scoped and carry its own negative proving it does **not** block healthy real
    workloads (a mis-scoped cluster-wide gate is a self-inflicted outage on a DB
    blip — sre-C M4). The **live withhold-DB** test is a *corroborating, isolated,
    on-demand* check (its own throwaway namespace + throwaway DB), **not** part of
    the every-bring-up budget and **never** degrades shared infra.
- **external-dns.** Demote "writes no records" (unfalsifiable / could just be
  un-requested); the real assertion is the **named auth error** on a subject/aud
  mismatch (security-A M2). The positive twin (a record actually appears) is the
  BRING-UP catch for blocker #8.
- **Kyverno is NOT the catcher for AWS-side facts** (security-B M3, panel #3):
  Kyverno audits *Kubernetes* objects; it cannot see EKS `authenticationMode` or
  VPC subnet tags (AWS control-plane/resource attributes). Any matrix row crediting
  Kyverno for those is dropped. Kyverno *can* enforce hub k8s invariants (IRSA SA
  carries role-arn #6) — and for those, **assert enforce mode is actually active**:
  `validationFailureAction: Enforce` + webhook `failurePolicy: Fail` (policies today
  are **Audit** mode — verified — so an Audit policy "guard" blocks nothing).
- **Added negative classes the panel wants** (security-B M2, security-C M2):
  AppProject `sourceRepos`/`destinations`/`clusterResourceWhitelist` deny-by-default
  (not just the IngressClass cell); IRSA confused-deputy family (wrong-`sub`,
  wrong-`aud`, wrong-issuer all denied); tenant-isolation (a spoke-tenant namespace
  **cannot** instantiate an XRD outside its allowed set, blocked by an *Enforce*
  policy); v2 connection-secret rejection (AGENTS §6.8); EKS `CONFIG_MAP`-only
  config rejected at author time so blocker #1 can't silently reappear.
- **Meta-test (red-first):** each negative must FAIL if you grant the permission /
  remove the guard (AGENTS §6.2 applied to negatives) — or it's a test that passes
  against the bug.

---

## 7. Isolation, cleanup, reaper, throttle (resolves CRITICAL #8, #9, #11)

BRING-UP tests mutate the **shared live hub** developers depend on. The panel
(every sre review C1; security C3; DevX M4) demands a real blast-radius contract,
not just a name prefix.

### 7.1 Hard isolation (blast radius — CRITICAL #8)
- **Invariant:** *the default live bundle never mutates a resource a running
  controller treats as a singleton.* Singleton-mutating tests (ingress-nginx
  controller, external-dns, admission webhooks) do **not** run against the shared
  hub in the default bundle — they run against a spoke the bring-up created, or
  behind explicit opt-in. (ingress-nginx admission-webhook deadlock and pod-IP/ENI
  exhaustion are documented hub failure modes — AGENTS §6.24/§6.26.)
- All BRING-UP mutations confined to a dedicated, labeled, **ArgoCD-excluded**
  throwaway namespace `live-verify-<run-id>` (AppProject deny / sync-options
  exclusion) so self-heal/prune never races the test. `kubectl delete ns` is the
  reliable k8s-side bulk GC even if per-resource deletes fail.
- **Concurrency interlock** (sre-B C4, sre-C M5): a cluster-level mutex (a hub
  lease/ConfigMap of active run-ids, or a GH Actions `concurrency:` group keyed on
  the cluster) so only one mutating bundle touches a given hub at a time. Expected
  concurrency: serialized per hub.
- **Throttle / rate-limit** is **in scope** (sre-B C4, sre-A M3): bounded
  concurrency + jittered backoff on `ThrottlingException`/`Rate exceeded`, with a
  hard classifier distinguishing `Throttling` (retry) from `AccessDenied` (real
  signal, fail red) so a self-inflicted throttle never masquerades as an IRSA gap.
- **Quota fail-closed** (sre-C C4): prefer T4 designs that create **zero new
  instances** (IAM/secret/DNS/cert need none); forbid instance-backed BRING-UP tests
  on the shared account by default; if any, compute `headroom = 9 - (mgmt+spoke+in-
  flight)` and cap concurrency to `min(N, headroom)`, failing with a distinct
  `QUOTA` tag (not `AccessDenied`). The quota check itself fails closed if
  `servicequotas:Get*` errors (security-C m3).

### 7.2 Cleanup that survives SIGKILL/eviction/suspend + a reaper that runs FIRST (CRITICAL #9)
`trap EXIT` is insufficient — it does **not** fire on job-cancel/SIGKILL/OOM/
sandbox-suspend (AGENTS §6.20), which are common during iterative red-CI loops.
- A **tag-based orphan reaper runs FIRST**, as step 1 of every bundle (not just
  opportunistically, not deferred to a late phase): deletes resources matching the
  pinned label **+ run-id prefix + age floor** (all three required — a single-tag
  delete is a foot-gun on the account that also hosts the mgmt cluster; dry-run +
  emit the to-delete set first; refuse to run unless `sts get-caller-identity` is
  the expected ephemeral account — security-C M4).
- **Cleanup remediates, not just reports** (security-B C3, sre-B M3): a non-empty
  leak set **fails the run** (RED), it does not print a footnote.
- **Enumerate by the tag the controller actually applies** (sre-B M3): the chainsaw
  ASM sweep was already wrong once because the Composition tags secrets
  `k8-platform/<XR-uid>`, never the test's `ASM_RUN_PREFIX` (OI-2026-05-28-1,
  confirmed in `tests/chainsaw/run.sh` ~76-78). The primary teardown check keys off
  the **run-id prefix on the XR/claim name** (which the test controls) and verifies
  deprovisioning **down the tree**; label-sweep is defense-in-depth, not the primary
  check. Pin the **exact** label string (the repo mixes `k8-platform`/`k8s-platform`
  — a prefix typo silently matches nothing = a leak that reads green) and a unit
  test asserts every BRING-UP test sets it (security-C m3).
- **Global-name namespacing**: IAM role / OIDC provider names are account-global and
  collide across parallel runs; embed run-id. ASM secrets have a 7-30 day recovery
  window — use `force-delete-without-recovery` for test secrets so a re-run with the
  same name doesn't hit `ScheduledForDeletion` (sre-A C3).

### 7.3 Secret redaction (CRITICAL #11)
`crossplane-claim-verify`'s documented recipe base64-decodes secret `data` and
`wait-for-claim.sh` auto-dumps on failure — both can spill plaintext into CI logs
and the PR summary, which the team routinely downloads (security-A C3, B C3, C M2).
Rules, mandatory before any secret-path test runs on every bring-up:
- **Synthetic non-secret values only** for all secret-path tests; assert on a
  **digest/length/known canary**, never the plaintext.
- A **redaction filter** on every failure dump strips `data:`/`stringData:`/
  `SecretString`/`Authorization` before stdout, run-log, or PR comment. The PR
  summary is the most-public artifact — it is redacted-only and is the *last* place
  any credential could appear.
- BRING-UP IAM/OIDC fixtures must be least-privilege; the test **rejects** a probe
  role whose trust policy lacks both `sub` and `aud` `StringEquals` conditions or
  uses `Principal:"*"` (don't mint a confused-deputy to test with).

### 7.4 Account-rotation, mid-run (sre-B M5, sre-A; security m1)
The preamble runs `whereami.sh` + `aws sts get-caller-identity` and fails fast
(<5s) with a distinct rotation message. But creds can rotate **mid-run**; a shared
helper classifies mid-run STS/credential errors centrally as
`ENVIRONMENTAL-ROTATION` → stop with the §8.2 message, distinct from
`AccessDenied-on-restricted-role` → the real signal. The negative-test logic
*depends* on telling these apart.

---

## 8. The SPOKE trigger + promoting hub→spoke e2e (resolves CRITICAL #7)

The spoke is where **6 of 8 blockers** lived, yet it has **no on-bring-up hook**:
it comes up via Crossplane reconciliation of an XR, not a terraform job — there is
no `terraform/spoke` to hang an "end-of-bring-up" step on (sre-A C1, DevX-B C3,
sre-B M4). Resolution:

- **Named spoke trigger:** the live bundle is **phase-aware**, and a spoke's
  AFTER-THE-FACT + the hub→spoke e2e run **automatically at the end of any spoke
  `apply-and-verify`/reconcile-completion**, coupled to the spoke build that *is*
  the change — **not** a manual dispatch and **not** a nightly. Mechanism: key the
  spoke verification off the spoke EKS XR reaching Ready (the bring-up that applied
  the spoke XR sets `expect-full` for the spoke's resources, so a missing
  AccessEntry/NLB/registration is a **FAIL**, not an auto-skip-green — §3.3). A
  hub-only bring-up that *did not* apply a spoke phase legitimately skips spoke
  checks (phase-not-applied); a bring-up that *did* and finds them absent fails.
- **Promote hub→spoke e2e out of the last phase** (sre-A m2, DevX-B C3): spoke
  registered → sync an Application using a cluster-scoped `IngressClass` → external-
  dns writes the Route53 record → `curl https://hello.platform.<domain>` returns 200
  (run **from CI/in-cluster**, never the sandbox — strict-MITM egress 503s a private-
  CA endpoint at the gateway; read the 503 body to distinguish gateway from app —
  security-B m3) → Keycloak Ready against RDS. This single flow is the backstop for
  the spoke-resident blockers and rides earlier in the rollout (§10).

---

## 9. Fast local inner loop (resolves CRITICAL #10)

The kube-API is sandbox-unreachable (private CA, §6.26/§6.27), so the naive inner
loop is push→20min-CI→read-log — which drives people to disable (DevX-A C2, DevX-B
M2). Mandated:
- Every BRING-UP test's **logic** (jsonpath/selectors, AWS-call parsing, teardown,
  isolation) must be runnable **sandbox-local in <60s** against **kind + a fake
  cloud** (moto/localstack) — or via a `run.sh` **`--dry-run`** mode that validates
  the check's shape against recorded fixtures without a cluster. docker/kubectl are
  installable in the sandbox (AGENTS §6.12).
- The **real-IRSA behavioral assertion is the CI-only delta** layered on top — the
  expensive part is *only* the real-cloud confirmation, not the whole loop. This
  separates "my test has a bug" (fast, local) from "the platform has a bug" (CI).

---

## 10. Blocker → bucket coverage matrix (all 8 + the subnet-tag blocker)

Each row names the **specific assertion**, its **environment**, whether it's a
**push-time** or **bring-up-time** catch, and a paired negative/positive. Rows that
the panel showed a layer *cannot physically observe* are corrected. This matrix is
the **acceptance criterion**; it is mirrored into `ai/TESTING-PLAN.md` (the
canonical bug→test traceability home, §6.4) with a unit test that every row names a
test file that exists (DevX-A M6) — so it cannot rot into a comforting lie.

| # | auto-012 blocker | Caught by — assertion / environment | Push or bring-up |
|---|---|---|---|
| 1 | EKS `authenticationMode=CONFIG_MAP` → AccessEntries impossible | AFTER-THE-FACT: `describe-cluster` mode includes `API` **+ behavioral** hub app-controller can `kubectl get ns` on spoke; PRE-FLIGHT: lint TF/XRD sets `API_AND_CONFIG_MAP` + negative that `CONFIG_MAP`-only is rejected | both |
| 2 | crossplane IRSA missing `iam:TagOpenIDConnectProvider` | PRE-FLIGHT: `simulate-principal-policy allowed` for the action + ceiling lint; BRING-UP: real XR provisions the OIDC-tagging path, no `AccessDenied` in events | both |
| 3 | missing `iam:UpdateAssumeRolePolicy` | same as #2 (simulate + real-controller positive) | both |
| 4 | missing `iam:GetRolePolicy` | same as #2 | both |
| 5 | missing **all `rds:*`** → RDS never provisioned | PRE-FLIGHT: `simulate-principal-policy` for the rds action set (RDS is slow → no instantiate); AFTER-THE-FACT: `describe-db-instances` + `XDatabase` Ready (`expect-full` ⇒ absent = FAIL, not skip) | both |
| 6 | ArgoCD application-controller SA missing IRSA | AFTER-THE-FACT **behavioral**: the controller pod actually `AssumeRoleWithWebIdentity` succeeds / spoke registration works (annotation-presence is a lint, not the proof — security-A M3); PRE-FLIGHT: `test_argocd_controller_irsa.sh` (exists) on **both** SAs + Kyverno **Enforce** "IRSA SA carries role-arn" | both |
| 7 | platform-spoke AppProject missing IngressClass permit | BRING-UP: sync an Application using a cluster-scoped IngressClass → must sync (positive) + forbidden kind/repo/destination rejected (negative); PRE-FLIGHT: `test_platform_spoke_appproject.sh` extended to the full deny contract | both |
| 8 | external-dns SA-name ≠ IRSA trust subject → AssumeRole denied, 0 records | BRING-UP positive: create Ingress → Route53 record appears; negative: **named auth error** on wrong-`sub`/`aud`/issuer; PRE-FLIGHT: `irsa_trust_validator.py --all == 0 MISMATCH` hard gate | both |
| 9 | shared-VPC subnets untagged → NLB never provisioned | AFTER-THE-FACT: subnet-tag assertion in spoke verify **+ behavioral** NLB actually provisions (tag read-back alone is a lint — security-A M3); PRE-FLIGHT: lint on the tag-injection composition. **Not Kyverno** (AWS-side, can't see — security-B M3) | both |

**Throughline:** every IRSA-permission blocker (2–5,8) is faithfully caught only
by `simulate-principal-policy` (push) + drive-the-real-controller-under-IRSA
(bring-up). kind/admin-cred chainsaw *masks* this whole class.

---

## 11. False-fail SLO — track the real reason people disable (resolves CRITICAL #12)

Flakiness, not principle, is what gets a live suite switched off (sre-C C2, DevX-C
M2). On-by-default is tied to a **measured** target, not aspiration:
- A **false-fail SLO** (e.g. live-bundle false-fail rate < 2%) computed from a
  stable per-test ID + outcome appended to a small log; the PR summary publishes
  per-tier pass/fail/skip, wall-clock vs budget, the switch state + reason, and the
  coverage delta (redacted-only).
- **Mechanical quarantine** (not goodwill): a push-time check flags any test that
  FAILed in N of the last M runs and **auto-opens/updates** its `docs/open-issues.md`
  entry; quarantine = a non-gating lane **with an expiry** (a quarantine older than X
  with no owner update fails the push check) — "quarantine" must not become "delete
  with extra steps."
- **No blind retries**; eventual-consistency gets a **bounded poll-until-true with a
  per-check `consistency_budget`** justified against the AWS-documented propagation
  SLA, stored next to the check, asserted-present by the mapping test. One shared
  bounded-poll helper per AWS service class (DNS/IAM/STS) so budgets are tuned in one
  place, not per-test (DevX-B M3). "Passed on retry N" surfaces as a flake signal,
  not a clean pass (sre-C M6). Budget breach → `OI-` entry, never an auto-retry-away.
- **Wall-clock ceiling**: a hard per-bundle ceiling fails the bundle so a hung
  `describe` can't hold a bring-up hostage; per-tier targets published as measured
  actuals from day one (sre-C M1, DevX-A m4).

---

## 12. Phased rollout — front-load highest-value / lowest-cost

Stacked, independently-mergeable PRs; each ships its tests red-first against the
pre-fix state (§6.2) and passes the §6.4 adversarial-subagent review. **The
load-bearing feasibility spike (drive-the-real-controller-under-IRSA + identity
assertions) is proven END-TO-END before the stack is built** (one real positive +
one real negative under the real identity — §6.25), because the source plans'
sequencing put the central, riskiest mechanism third, behind scaffolding (all
three reviews' sequencing notes).

- **Spike (gate everything):** prove the §2 mechanism end-to-end on the live hub —
  a real XR reconciles under the provider IRSA, identity == expected ARN,
  `simulate-principal-policy` returns the right allow/deny. If this fails, the whole
  plan changes shape; do it first.
- **P1 — make the gap visible + enforcement vehicle, all cheap/static, no behavior
  risk.** Derived coverage manifest + `test_live_coverage.sh`; two-sided IAM
  ceiling/floor lint; `simulate-principal-policy` checks; the `tests/live/run.sh`
  skeleton with **inverted skip semantics + executed-floor + default-as-tested-
  invariant + master-switch guard**; SKIP_REGISTER + its push-test; the
  skip-count/coverage GATE inside `tests/unit/run.sh` (§3.4). Ships requirements
  1/2/6's *mechanism* before any live check exists. Enforcement lands **with** the
  scaffold, not last (DevX-B C2/m3).
- **P2 — deepen AFTER-THE-FACT (highest ROI, no new resource cost).** Behavioral
  EKS/RDS/IAM/cert/DNS verifiers (effect not just config); promote the existing
  integration probes into `tests/live/`; make `crossplane-claim-verify` mandatory;
  wire `run.sh` into `apply-and-verify`. Catches #1,#5,#6,#7,#9.
- **P3 — orphan reaper + isolation + secret redaction.** Reaper-runs-first,
  remediate-not-report, ArgoCD-excluded throwaway ns, concurrency mutex, throttle
  classifier, synthetic-secret/redaction rules. (Promoted early — leak/blast-radius
  protection must precede default-on mutating tests, not trail it — sre-C C3.)
- **P4 — BRING-UP instantiate-and-verify under real IRSA** (the central behavioral
  catch, on the proven spike). Cheap MR kinds; positive controller-action; the
  named `AccessDenied` negatives. Catches #2–#4,#8.
- **P5 — negative/precondition + spoke trigger + hub→spoke e2e.** XRD/AppProject/
  RBAC/confused-deputy/tenant-isolation negatives; the Kyverno DB admit-gate
  (Enforce, scoped, with its own no-false-block negative); the spoke auto-trigger
  and the promoted e2e flow.
- **P6 — hardening.** False-fail SLO dashboard, mechanical quarantine, idempotency
  per-test (+ a rare manual double-run), fast-loop docs, triage playbook.

---

## 13. Deliberately rejected (and why)

- **A probe SA/pod assuming the restricted Crossplane role** (PLAN-A §4, PLAN-B
  §4.1/§5.2, PLAN-C §9 in-cluster-job-as-primary). *Rejected:* the trust policy
  trusts only the provider SA; a probe gets a false `AccessDenied` mimicking the
  real blockers, and widening trust is the privilege bloat we test against. Replaced
  by drive-the-real-controller + the §2 NON-GOAL.
- **A live IRSA permission *denial* test (claim → AccessDenied) as a standing
  check** (PLAN-B §5.2, PLAN-C §8). *Rejected:* the actions are already granted;
  producing a denial needs live role-mutation or a crippled-twin role (both bloat).
  Replaced by `simulate-principal-policy` for completeness + the verbatim-message
  assertion only when a real denial naturally occurs.
- **A completeness probe that exercises each MR kind's full lifecycle live** (PLAN-A
  §4). *Rejected:* for EKS that's the 20-min resource §5 forbids per-test; it
  rewards adding grants. Replaced by simulate (cheap kinds get one real
  create-verify-delete; expensive kinds get simulate only).
- **The `tests/unit/`→`tests/lint/` physical rename in "P1 cheap"** (PLAN-A §8).
  *Rejected as bundled/cheap:* high blast-radius (run.sh↔workflow sync, ~60 files).
  Kept the *honesty concept* via README + tag.
- **A six-tier taxonomy with sub-modes / a 5-tier × 2-axis grid** (PLAN-A L0-L4 +
  L2a/b, PLAN-B L0-L5, PLAN-C T0-T4). *Rejected:* onboarding tax; the plans
  themselves mis-filed contracts across tiers. Collapsed to three buckets + two
  tags.
- **T2 (restricted creds against the chainsaw stub)** (PLAN-C §2/§9). *Rejected
  unless a one-time fidelity calibration proves the stub actually denies a known
  out-of-policy action* — a green that means nothing is worse than no test
  (security-C M3, DevX-C M3). Default: not shipped.
- **A hand-maintained coverage manifest / `COST_TIERS.yaml` as a separate file**
  (PLAN-B §4.3, PLAN-C §3.2). *Rejected:* second-copy-of-truth that drifts/gets
  edited green. Replaced by derivation from `crossplane/**` + `irsa.tf` and a tier
  *annotation on the resource* (DevX-B M1).
- **Re-pointing chainsaw / introducing kuttl at a real cluster as the live harness**
  (PLAN-A §6). *Rejected:* fights the §6.7 heavy-CI contract and the fragile rotated-
  account provider auth; chainsaw stays kind-only PRE-FLIGHT. The existing
  `tests/integration/` harness (cluster auth, RUN_ID, cleanup) is the real-cluster
  base.
- **A new `live-verify` enforcement workflow / reliance on extending
  `kube-diagnose.yml`** (PLAN-B §8.4, PLAN-C §11). *Rejected:* OI-2026-06-05-6 — this
  environment can't create/edit workflows; enforcement routed through
  `tests/unit/run.sh` instead.
- **`aws ce` cost guard** (PLAN-B §6, PLAN-C). *Rejected:* Cost Explorer lags 24h+;
  useless for a per-run gate. Replaced by a synchronous run-id tag-scan leak count.
- **Parallel fan-out + a runtime EC2-quota calculator up front** (PLAN-C §5.2).
  *Deferred:* keep the orchestrator serial initially (debuggable; non-instance
  BRING-UP set is seconds-to-min); add fan-out only on a *measured* budget breach
  (DevX-C m1).
- **Terratest for the TF layer** (PLAN-B §10). *Deferred:* TF is thin and
  `terraform-test.yml` already does apply-and-verify.

---

## 14. Residual risks & open questions

1. **The spike may fail.** If, on the live hub, a real XR cannot be made to
   reconcile-and-verify under the provider IRSA in a way the bundle can observe (e.g.
   CloudTrail latency makes the identity assertion slow/flaky), the §2 identity proof
   weakens to "Synced + cloud-exists" without the ARN assertion. Decide a fallback at
   spike time; do not build P4 on an unproven mechanism.
2. **Behavioral spoke-API check from CI** depends on CI reaching the spoke kube-API
   (private CA). If only `kube-diagnose.yml`-style read paths exist and they can't be
   extended (OI-2026-06-05-6), the #1/#6 *behavioral* (not just config) assertions
   may be blocked — flag as an operator dependency, not an assumption.
3. **Derivation completeness for the coverage manifest.** Side-effect resources (the
   untagged subnet, controller-created LBs) are exactly the ones absent from
   `resources[]`; the `extra:` allowlist mitigates but is itself a reviewed surface
   that can lag. Reconcile against a live `resourcegroupstaggingapi` view periodically.
4. **`expect-full` correctness.** The whole anti-silent-regression floor depends on
   the bring-up correctly declaring which phase it applied. A bug there
   re-introduces silent-skip-green. The `phase=test` orchestrator unit tests must
   cover this mapping.
5. **CloudTrail/access-analyzer latency** for the un-exercised-grant tier (§4.2):
   may need an async/after-the-fact lane rather than an in-bundle gate.
6. **Quarantine + SLO require persistent state** (the append-only outcome log)
   across runs on ephemeral accounts — where does it live (committed file vs
   artifact)? Resolve before P6.
7. **Register cap (N) and grace-window** values (§3.4) are policy knobs; set them in
   the plan-to-implementation handoff, with the floor = *zero* tolerated skips for
   any `expect-full` resource.
8. **Read-path CI key blast radius** (security-C m1): AFTER-THE-FACT `Describe*`
   uses the admin CI key; prefer a narrowest-possible read-only verifier role.

---

*End of synthesized plan. PLAN-ONLY — no code, tests, fixtures, or workflows were
created or modified except this file.*
