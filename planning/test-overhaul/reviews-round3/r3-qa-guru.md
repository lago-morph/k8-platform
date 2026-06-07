# Round-3 Adversarial Review — FINAL-PLAN.md

**Reviewer:** QA / test-architecture expert for systems that depend on EXTERNAL
LIVE SYSTEMS. Round-1 author, round-2 adversary, now round-3 cold reader of the
finalized plan (both constraint corrections applied).
**Lens (per brief):** coherence + gap-freeness of the THREE execution contexts;
does "on by default" survive the trigger moving from CI to the build, and is the
build's invocation of the suite ITSELF tested; is the git-sourced expect-full
floor sound and unbypassable; resource lifecycle/cleanup/idempotency on the
ephemeral account; flake/false-fail SLO; gating model; negative/precondition
guard-fired rigor; coverage honesty; and any classic anti-pattern the
build-coupling recast introduced.
**Method:** read FINAL-PLAN.md fully and cold; re-read CONSTRAINT-CORRECTION-2,
the round-2 qa-guru review, AGENTS §6.7, and grounded the load-bearing claims
about the "build flow" against the actual tree.

---

## Grounding I confirmed this session (so the review stands on fact)

- **`crossplane/providerconfig/00-clusterproviderconfig.yaml`** — `kind:
  ClusterProviderConfig`, group `aws.m.upbound.io/v1beta1`, `spec.credentials.source:
  IRSA`. The §3.2 identity pivot to `source: IRSA` is **correct and grounded**, and
  the committed comment even enumerates the enum
  `[None, Secret, IRSA, WebIdentity, PodIdentity, Upbound]`. Good.
- **`tests/integration/run.sh:40-45`** — exits 0 whenever `FAIL==0`; rc=2 is a
  counted SKIP (`:28`). All-skip reads green. The central diagnosis is **true**.
- **`tests/live/` does NOT exist.** Confirmed. Everything in §4/§5/§16 about
  `tests/live/run.sh` is net-new.
- **THE DECISIVE FACT — `apply-and-verify` is a `workflow_dispatch` *input* of
  `.github/workflows/terraform-test.yml`, not a standalone build script.**
  Verified: `terraform-test.yml:3-4` is `on: workflow_dispatch:`; `:15-27` defines
  `action` with choices including `apply-and-verify`/`verify`; the e2e-verify steps
  (`:235`, `:315`) run *inside that dispatched workflow*. `grep apply-and-verify`
  across the tree finds it ONLY in `.github/workflows/terraform-test.yml`,
  `ai/handoff.md`, `ai/testing-guidelines.md`, and `ai/brainstorming/specs/`. There
  is **no `verify-platform.sh`, no `apply-and-verify.sh`, no build script** in
  `scripts/` (confirmed full listing). The bring-up procedure documented in
  `ai/testing-guidelines.md §3` IS "`workflow_dispatch (phase=N,
  action=apply-and-verify)`" — i.e. a manually dispatched GitHub Actions run.

That last fact is the spine of this review: **correction #2's "the build is
decoupled from CI; move the trigger into the build" rests on a build/CI
distinction that does not exist in this repository.** The build *is* a dispatched
CI workflow.

Verdict up front: FINAL-PLAN faithfully applies the round-2 resolutions — the
`source: IRSA` fix (C1), the git-sourced expect-full (C2), the reconciled oracle
precedence (C3), the hermetic/singleton partition (C4), the RGT-diff side-effect
oracle (M4), the wall-clock budget (M5), the concrete false-fail SLO (M1),
standing idempotency (M2) are all genuinely present and correct. The plan is the
right document. But **constraint correction #2 was applied as prose, and it
introduced a new Critical the plan does not see**: it relabels the existing
dispatched-CI bring-up as "the build, not CI" and asserts an on-by-default
guarantee that nothing in the repo can actually enforce. Ranked below.

---

## CRITICAL

### R3-C1. The "build, not CI" trigger is a distinction without a difference in THIS repo — the bring-up IS a `workflow_dispatch` CI run, so correction #2 did not move the trigger anywhere; it renamed it, and the on-by-default guarantee is now LESS enforceable than the round-2 design it replaced.

Correction #2 and §4.1/§18 repeatedly contrast "build-time (coupled, on by
default)" against "push/PR CI," and present the every-bring-up guarantee as "the
bring-up procedure itself invokes `tests/live/run.sh`, not a CI check." But in
this repo the bring-up procedure is literally `workflow_dispatch (phase=N,
action=apply-and-verify)` against `terraform-test.yml` — a GitHub Actions run.
There is no second, non-CI build executor to move the trigger into. So:

- The plan's recurring phrase "**build-flow wiring (not CI)**" (§4.1, §4.2 note,
  §12 ledger row 1, §15, §16 P1, §18.1) describes wiring `tests/live/run.sh` into
  `terraform-test.yml`'s `apply-and-verify` action path — which **is** editing a
  `.github/workflows/*` file. The plan correctly notes jentic can land that edit
  (correction #1). Fine. But then "the trigger is NOT in CI" is **false**: the
  trigger is a step in a CI workflow, fired by a manual dispatch. The plan has
  re-labeled the round-2 design, not changed its mechanism.
- This matters because round-2 R2-C1's actual fix — **a HEAD-SHA "live-evidence
  exists" check on push that FAILs the static gate if no green build-suite ran for
  the deployed SHA** — is in FINAL-PLAN demoted to a "secondary static backstop
  … WARN/FAIL" (§4.3, §12 ledger row 4, §15). The plan says the "PRIMARY
  anti-regression guarantee is the build coupling." But "the build coupling" is
  now "a step inside a manually-dispatched workflow that a human chooses to run."
  Nothing forces `action=apply-and-verify` to be the action chosen — `verify`,
  `apply`, `plan` are all valid and `verify ⇒ readonly` (the plan's own §4.1). So
  "every bring-up runs the suite" reduces to "every time someone dispatches the
  one action that includes it." That is **exactly the "coupled to whoever remembers
  to dispatch" goodwill** R2-C1 said must not be the guarantee — and correction #2,
  by de-prioritizing the HEAD-SHA static gate, made it *weaker* than the round-2
  draft, not stronger.

**Why this is Critical, not Major:** requirement #1 ("live verification runs
EVERY platform bring-up, on by default") is the user's #1 requirement, and the
plan's own §18 closing claim is "*on by default* … re-confirmed under the
build-coupled model." It is not re-confirmed; it is *assumed* on the back of a
build/CI distinction the repo doesn't have. An implementer reading §4.1 + §18
believes requirement #1 ships; what actually ships is "a new step in
terraform-test.yml's apply-and-verify path, plus a push-time WARN if no evidence
marker exists."

**Fix (finalization must do this, not defer):**
1. **Name the real executor.** State plainly: "the bring-up in this repo is
   `terraform-test.yml action=apply-and-verify`, a `workflow_dispatch` run; 'the
   build invokes the suite' = adding a non-skippable `tests/live/run.sh` step to
   that action's path (landed via jentic). This IS a workflow edit; it is not a
   non-CI executor." Delete the "(not CI)" framing — it is factually wrong here and
   it hides that the guarantee lives in a workflow file.
2. **Restore the HEAD-SHA live-evidence gate to PRIMARY teeth**, not "secondary
   backstop." On a manual-dispatch build model, the ONLY mechanical
   anti-goodwill guarantee available at push/PR time is "no green
   `tests/live/run.sh` result is recorded for HEAD ⇒ the push gate FAILs (not
   WARNs)." Without it, "coupled to the change" is unenforceable for any change that
   the dispatcher chooses `verify`/`apply` for. Make it FAIL, define what writes the
   marker (the apply-and-verify step, keyed on the deployed SHA), and account for
   the bootstrap (the very first apply for a fresh account has no prior marker —
   define that as expect-full-from-git, not green-by-absence, §4.3).
3. **Make "the apply-and-verify path invokes the suite" a tested invariant against
   the REAL file.** §4.2 says a static lint asserts "the committed `apply-and-verify`
   / bring-up flow invokes `tests/live/run.sh` as its final phase (grep the flow
   definition)." The flow definition is `terraform-test.yml`. State that the grep
   target is that workflow's `apply-and-verify` action path, and that the lint
   asserts the step is **not** guarded by an `if:` that can silently exclude it. A
   grep that matches a commented-out or `if: false` step is the §6.24 anti-pattern.

### R3-C2. Nothing runs the live suite on a config-only change that does not trigger a build — the classic anti-pattern the build-coupling recast introduced, and the plan's only answer (HEAD-SHA marker) is demoted to a WARN.

This is the anti-pattern the brief explicitly asked me to hunt: "nothing runs on
a config-only change that doesn't trigger a build." It is real and unaddressed.

In a GitOps repo, a change to `crossplane/**` (a Composition edit, a new XRD, an
IAM-policy tightening in a committed manifest, a subnet-tag fix) is **synced by
ArgoCD onto the *already-running* hub — no `apply-and-verify` is dispatched.** The
plan's §10 spoke trigger handles the spoke-XR-Ready case, but the general case —
"a PR edits a Composition that ArgoCD will sync onto the live hub" — triggers:

- Push/PR CI: static-only (correct, by design).
- Build: **nothing** — there is no `apply-and-verify` for a GitOps-synced
  Composition change; ArgoCD reconciles it with no test invocation.
- Manual dispatch: only if a human remembers.

So a Composition change that, say, re-introduces blocker #9 (drops a subnet tag)
or blocker #1 (flips authnMode) merges with green static checks, ArgoCD syncs it
to the live hub, and **no live verification ever fires** unless someone dispatches
a build. The auto-012 failure class lived precisely in
Composition/IAM/tag config; this is the exact change shape the overhaul exists to
catch, and the build-coupled model has no trigger for it.

The plan half-sees this — §4.3's HEAD-SHA static-evidence backstop is meant to
cover it — but (a) demotes it to WARN/secondary (R3-C1), and (b) a config-only
ArgoCD-synced change has **no build to produce a marker**, so "evidence exists for
HEAD" is structurally absent → under "fail-closed on missing oracle" (§4.3) it
should FAIL, but the plan calls the same condition a WARN. The two statements
collide.

**Fix:** state the GitOps config-change path as a **first-class trigger context**,
not a footnote. Options the plan must pick among: (a) a path-filtered
`workflow_dispatch`-reminder gate that FAILs the PR check when `crossplane/**` /
`policies/**` change without a recorded green `tests/live/run.sh` for HEAD (forces
the dispatch before merge — the §6.7/§6.8 pattern the repo already uses for
chainsaw on v2 CRD changes); (b) an ArgoCD post-sync hook on the hub that invokes
the relevant after-the-fact subset (committable as a hub Job; no workflow scope).
Pick one and make it FAIL-closed. Today the plan leaves the highest-frequency,
highest-risk change class (a Composition edit) with no live trigger and a WARN.

### R3-C3. The three execution contexts are coherent ONLY if "build-time" is a real fourth thing; because it is actually "manual dispatch of apply-and-verify," contexts 2 and 3 are the same GitHub Actions surface — so "on by default" and "never auto-triggered" are asserted of the same mechanism, and the matrix collapses.

The brief's first question: are the three contexts coherent and gap-free? Read
literally they are (push=static; build=full live; dispatch=kind+ad-hoc). But the
partition assumes context 2 ("build-time") and context 3 ("workflow_dispatch") are
*different execution surfaces*. In this repo they are the **same surface**: both
are `workflow_dispatch` runs of `terraform-test.yml` (or a sibling). Context 2 is
`action=apply-and-verify`; context 3 is "ad-hoc live / kind." The plan even admits
this in the §4.2 `live-verify` note ("a `workflow_dispatch`-only workflow for
manual/ad-hoc live runs") while insisting context 2 is "not an Actions trigger."

So the load-bearing claims attach to the same thing:
- "**on by default**" is asserted of context 2 (§4.2).
- "**never auto-triggered, manual-dispatch-only**" is asserted of context 3 (§4.1).

If both are dispatched runs of the same workflow family, then "on by default"
means "the default *action choice* when a human dispatches is apply-and-verify"
— a UI default, not an automatic behavior. The plan's §4.2 even hedges: "any
`workflow_dispatch` default is advisory." An advisory default is not "on by
default" in the sense requirement #2 demands ("disabled/all-skipped must never
read green"). A human who dispatches `action=verify` gets readonly, skips the
mutating suite, and — per the plan's own all-skip-RED-only-applies-at-build-time
carve-out — **the suite never ran, so all-skip-RED never fires**, and the result
reads green for a bring-up that verified nothing.

**Fix:** collapse the false 3-way and state the honest 2-way + a sub-mode:
- Context A — **push/PR static, automatic** (no cluster). Correct as-is.
- Context B — **dispatched `terraform-test.yml`**, the only live surface. Within
  it, `apply-and-verify` MUST invoke the full suite with all-skip⇒RED and
  expect-full floor; `verify` invokes the readonly after-the-fact subset, and
  **its all-readonly result still applies the expect-full floor** (a `verify` on a
  cluster where git declares RDS but RDS is absent must FAIL, not skip-green).
- Then the *real* "on by default + never green when skipped" enforcement is:
  **the push-time HEAD-SHA gate (R3-C1/C2) FAILs unless a green apply-and-verify
  suite ran for HEAD.** That is the mechanical default-on; the dispatch UI default
  is irrelevant. Without this re-statement, "on by default" is a UI dropdown
  default and requirement #2 is unmet.

---

## MAJOR

### R3-M1. all-skip⇒RED is scoped to "build-time when the suite runs" — which means the one state requirement #2 most fears (the suite never runs at all) is the one state all-skip⇒RED cannot catch.

§4.2 / §15 / §18 all qualify all-skip⇒RED as "**enforced at build-time when the
suite runs**." That qualifier is a hole. The requirement is "disabled/all-skipped
must never read green." The dangerous case is not "the suite ran and skipped
everything" (caught); it is "the suite was never invoked" (a `verify`-only
dispatch, a config-only ArgoCD sync, a crash before the final phase) — and a
not-invoked suite emits no banner, so there is nothing to be RED. The plan moved
all-skip⇒RED inside the suite, but the suite's *non-invocation* is now the silent
path. This is R2-C2's circularity reborn at the invocation layer: the guarantee
lives inside the thing whose absence is the failure mode.

**Fix:** the not-invoked state must be RED *from outside the suite* — i.e. the
HEAD-SHA gate (R3-C1) is not optional polish, it is the only place "the suite
never ran" can be turned red. State: "absence of a green suite marker for HEAD is
RED, enforced by the push gate, independent of whether any suite process ran."
Then all-skip⇒RED (inside-suite) and no-suite⇒RED (outside-suite, push gate)
together cover both halves. The plan currently ships only the first half and calls
it complete.

### R3-M2. The `verify ⇒ readonly` invariant and the expect-full floor are in unstated tension: a readonly verify cannot FAIL on a missing expensive resource it was told to expect, unless the floor is explicitly wired into the readonly path — and §4.1 implies the floor is a build-time/mutating concept.

§4.1 mandates `verify ⇒ readonly` (good — agents call `verify` often; it must not
provision). §5 makes RDS/EKS "AFTER-THE-FACT only," read-only describes. §4.3/§4.4
make expect-full (from git) promote a SKIP of an expected resource to FAIL. These
are individually right, but the plan never states that **the expect-full floor
applies on the readonly `verify` path too.** If it does not, then `verify` on a
hub where git declares an `XDatabase` but RDS was never provisioned (blocker #5's
exact shape) reads green — because readonly verify "found nothing to mutate" and
the floor only bites "at build-time." Blocker #5 is an after-the-fact, readonly
detectable condition; the floor MUST live on the readonly path or #5 escapes the
most-frequently-run action.

**Fix:** state explicitly that the git-sourced expect-full floor is evaluated on
BOTH `verify` (readonly) and `apply-and-verify` (mutating); only the
*instantiate-and-verify* (mutating create-path) checks are gated on
`LIVE_MODE=mutating`. The after-the-fact existence/convergence floor is
mode-independent. Add a `phase=test` assertion: "`verify` on a cluster missing a
git-declared expensive kind FAILs with expect-full." Without this, the cheapest
and most-run action is the blind spot for the slowest blockers.

### R3-M3. The HEAD-SHA live-evidence marker is itself a self-attested oracle (R2-C2's disease) unless its provenance and integrity are specified — the plan introduces it as the anti-regression backstop but never says what stops the marker from being written without the suite passing.

§4.3/§12/§15 introduce "a committed live-evidence marker per HEAD SHA"; a missing
marker is a push WARN/FAIL. But a marker that the apply-and-verify step writes is
written *by the same flow whose success it attests* — the round-2 C2
self-attestation anti-pattern, one layer out. If the marker is "a committed file
saying 'HEAD abc123 green'," what prevents (a) writing it on partial success,
(b) writing it when the suite all-skipped (which, per R3-M1, can read green),
(c) a stale marker from a *different* cluster/account (the account rotates — §8.1
— so "HEAD green" on the old account is meaningless on the new one)? The plan's
own §8.1 says account-derived state isn't durable; a HEAD-keyed marker that
ignores account/cluster identity will go green against a rotated account it never
ran on.

**Fix:** specify the marker's integrity contract: (1) written ONLY on a
non-all-skip, non-WARN green of `tests/live/run.sh` (tie it to the §4.4 exit-code
contract — written only on the clean-pass code, never on exit 2/3); (2) keyed on
**(HEAD SHA × account-id × cluster-name)**, not SHA alone, so a rotation
invalidates it (§8.1); (3) the writing step is the same one whose exit code it
records, so it cannot be written ahead of a pass. Until specified, the backstop
is forgeable and re-creates the exact "self-attested green" the plan spent R2-C2
eliminating.

### R3-M4. FLAKE_LOG-as-committed-file (§11) collides with the ephemeral-account reality and with the marker churn — and the auto-quarantine "teeth" can mechanically suppress a REAL recurring failure as if it were flake.

Two problems the plan does not reconcile:
- **(a) Identity drift.** FLAKE_LOG keys on "per-test stable ID + outcome" to
  detect "N of last M." But the account rotates between sessions (§8.1); a test
  that fails 3× on account-A's quota and once on account-B is "N of last M" across
  *different environments*. The false-fail ratio (§11) and the auto-quarantine
  trigger will conflate cross-account history. The plan says FLAKE_LOG "survives
  account rotation" as a *virtue* — but surviving rotation means it carries
  stale-environment outcomes into a fresh environment's flake math.
- **(b) Quarantine as a silent-disable laundering channel.** §11's "teeth":
  an SLO breach "auto-demotes the offending check to a non-gating quarantine lane
  (mechanical, not goodwill)." But a check that fails *because of a real recurring
  AccessDenied or a real expect-full miss* — exactly the auto-012 class — looks
  like "N of last M reds" too. The plan's false-fail definition (§11) excludes
  "real AccessDenied / expect-full miss" from the numerator, so in principle a real
  failure should not count as false-fail. But the **auto-quarantine trigger** in
  §11 is described as firing on the SLO/N-of-M, and the disposition (false vs real)
  is the §8 *triage classifier* — which is not infallible. If the classifier
  mislabels a real recurring AccessDenied as THROTTLE (the §8 ROTATION/THROTTLE/
  QUOTA buckets), the real failure gets auto-quarantined and the bundle goes green.
  That is §6.24 (never weaken a check to make red go green) automated. The single
  most load-bearing distinction in this whole overhaul — AccessDenied (real) vs
  Throttling (retry) — is now the input to an *automatic disable*.

**Fix:** (1) key FLAKE_LOG and the SLO window on (test-ID × account-epoch) and
reset/segment the flake math on rotation, OR store only same-account history and
state the SLO is per-account-lifetime. (2) **Never auto-quarantine a check whose
last failure's classifier disposition is `AccessDenied` or `expect-full-miss`** —
auto-quarantine is permitted ONLY for the ENVIRONMENTAL-ROTATION/THROTTLE/QUOTA
dispositions, and a check that has *ever* produced an AccessDenied/expect-full red
in its window requires a human OI- entry to quarantine. State that the classifier
fail-safe is "ambiguous ⇒ treat as REAL (do not quarantine)," so a misclassified
real failure stays red. The asymmetry must favor red.

### R3-M5. The expect-full "fail-closed on a missing oracle" rule and the three skip-states have a coverage gap for the GitOps case the plan itself relies on: "phase applied" is not observable for an ArgoCD-synced resource, so the discriminator between "phase-not-applied (allowed skip)" and "precondition-absent-but-expected (FAIL)" is undefined for the very path §10 says carries 6 of 8 blockers.

§4.4 defines three skip-states; the FAIL state is "git declares it, **the phase
applied**, it's missing." But for an ArgoCD-synced resource there is no discrete
"phase applied" event — ArgoCD continuously reconciles. So "the phase applied" is
not a clean signal; the test must infer it. The plan's §4.3 fix is "derive
expect-full from git desired-state" (correct) — but §4.4 still gates the FAIL on
"the phase applied," which for GitOps means "ArgoCD claims Synced." If ArgoCD
reports the *app* Synced while a composed MR underneath is stuck (the exact
v2-claim-verify failure mode §9.1 describes — XR Ready, child MR stuck), then
"phase applied = true, resource present at XR level = true, but the real cloud
resource is missing" — and the discriminator the plan wrote keys on the wrong
layer. The git-sourced expect-full is right; the "phase applied" qualifier
re-imports a runtime-status dependency that can lie.

**Fix:** drop "the phase applied" from the FAIL discriminator for git-declared
kinds. The rule should be: **git declares kind K for this cluster ⇒ K is
expect-full ⇒ the real cloud resource (verified via the v2-ported claim-verify
descending to the MR + cloud Describe, §9.1) must exist; absent ⇒ FAIL,
regardless of any ArgoCD/XR Synced status.** ArgoCD-Synced is never permitted to
downgrade an expect-full kind to an allowed skip. State this; otherwise the
GitOps path (6 of 8 blockers) keeps an "app says Synced ⇒ skip-green" escape.

---

## MINOR

### R3-m1. §4.4's reserved exit code (`exit 3 = expect-full violation`) must be propagated by `tests/live/run.sh`'s shared-lib sourcing of `tests/integration/lib/` (§2). The integration lib today maps anything non-0/2 to FAIL (run.sh:29). Confirm the inverted orchestrator does not collapse `exit 3` back into a generic FAIL that an outer wrapper could mistake for a retryable error — the whole point of the distinct code is that the bundle treats it as non-retryable, non-quarantinable (ties to R3-M4: an exit-3 must be ineligible for auto-quarantine).

### R3-m2. §4.1 says new `tests/unit/test_*.sh` static gates go in "both `tests/unit/run.sh` and `unit-tests.yml` in the same PR," relying on §6.16's catch-all backstop. Confirmed `unit-tests.yml` has the catch-all (verified header comment). Good — but the plan should name that the catch-all is the source of truth, so an implementer doesn't burn a loop wondering why a per-step entry is "missing."

### R3-m3. §5's idempotency standing assertion ("apply same XR twice ⇒ one cloud resource") and §6's teardown leak-poll both run inside the wall-clock budget (§6: "< 8 min over bare bring-up"). The §6 worked floor sums reaper + create/verify + double-apply + teardown poll to roughly that 8 min with "margin," but the margin is unquantified and the hermetic SET is plural (IAM/OIDC/S3/ASM/ESO/ConfigMap/ACM). 7 hermetic kinds × (create+verify+double-apply+teardown) will not fit < 8 min if run serially. State whether the hermetic set runs concurrently (then the §8 account-mutex serializes *runs*, not *kinds-within-a-run* — confirm that distinction) or whether the budget is per-kind. As written the budget and the kind-count are inconsistent.

### R3-m4. §3.2's in-band identity gate is correctly sub-second and falsifiable (source==IRSA exactly + no static-cred PC + no AWS_ACCESS_KEY_ID in pod + provider Healthy). One gap: check #2 ("no `AWS_ACCESS_KEY_ID` in the provider pod env") reads the *running* pod env — but a `source: Secret` ProviderConfig injects creds via a referenced Secret the controller reads at reconcile, not necessarily as a pod env var. The env-var check can pass while a Secret-source PC is layered. The plan's check #2 first clause ("no AWS-group ProviderConfig with source: Secret") covers it, but state that the ProviderConfig sweep is the load-bearing half and the env-var check is corroborating — otherwise an implementer may ship only the (weaker) env-var check.

### R3-m5. §13 matrix row 7 (AppProject IngressClass) and §5(b) put IngressClass/ArgoCD-registration as singleton-coupled "BRING-UP only on a spoke." But the bring-up that creates a spoke is the ~20-min+ EKS path. So requirement-4 "both" for these kinds is satisfied only on a full spoke bring-up, which the cost model (§5) wants to avoid recreating. State the cadence: these get instantiate-and-verify only when a spoke is *already* being brought up (not on every hub bring-up), and after-the-fact otherwise. The plan implies this but never says "their 'both' cadence is spoke-bring-up frequency, not hub frequency" — leaving an implementer to either skip them (req-4 violation) or force a spoke (cost violation).

---

## Are the round-2 resolutions real? Scorecard

- **R2-C1 (trigger must have a landable path / not goodwill):** PARTIALLY — and
  REGRESSED. Workflow edits are landable (correction #1, true). But the
  "build, not CI" reframing (correction #2) is a non-distinction here (R3-C1), and
  the HEAD-SHA teeth R2-C1 demanded were demoted from a FAIL gate to a WARN
  backstop. Net: less enforceable than the round-2 ask.
- **R2-C2 (self-attested expect-full oracle):** RESOLVED for the *kind set*
  (git-derived, §4.3) — genuinely good. But re-opened one layer out: the HEAD-SHA
  *marker* is self-attested (R3-M3), and "phase applied" re-imports runtime status
  (R3-M5).
- **R2-C3 (two un-reconciled IRSA oracles):** RESOLVED. §3.3's precedence
  (simulate=floor, drive-controller=signal, delta-only un-exercised tier, async
  lane) is exactly the fix asked for. Clean.
- **R2-C4 (req-4 "both" vs singleton invariant):** RESOLVED in design (§5
  hermetic/singleton partition). Residual cadence ambiguity only (R3-m5).
- **R2-M1 (false-fail SLO had no teeth/data plane):** RESOLVED in shape (triage
  ratio, committed FLAKE_LOG, auto-quarantine) but the teeth can mis-fire on real
  failures and the data plane fights account rotation (R3-M4).
- **R2-M2 (idempotency demoted):** RESOLVED (standing per-test, §5). Budget
  arithmetic only (R3-m3).
- **R2-M3 (Enforce declared vs fired):** RESOLVED (§7 cheap always-on firing test
  in throwaway ns). Good.
- **R2-M4 (side-effect coverage):** RESOLVED (RGT-diff standing oracle, §4.5).
  Good.
- **R2-M5 (wall-clock budget):** RESOLVED as a distinct budget gate (§6); only the
  serial-vs-concurrent sum is loose (R3-m3).
- **R2-m4 (don't drop the falsifiable identity check):** RESOLVED and improved —
  the in-band `source: IRSA` gate replaces the infeasible ARN check; the
  "degrade to Synced+exists" fallback is explicitly forbidden (§3.2). Best
  single resolution in the doc.

---

## What MUST NOT be lost in finalization (priority order)

1. **The spine** (§ exec-summary): real cloud × restricted identity, driving the
   REAL controller under `source: IRSA`, on by default, coupled to the change,
   all-skipped⇒RED, no probe pod / no trust widening. Every round said it. It is
   the only thing that would have caught auto-012. The build-coupling recast must
   not be allowed to quietly turn "on by default" into "a UI dropdown default"
   (R3-C1/C3) — that loses the spine through the trigger.
2. **The git-sourced expect-full floor = zero** (§4.3/§4.4). Keep it; extend it to
   the readonly `verify` path (R3-M2) and strip the "phase applied" qualifier for
   GitOps kinds (R3-M5). This is the actual answer to requirement #2.
3. **The forbidden fallback** (§3.2): "degrade to Synced+exists, drop the ARN" is
   forbidden, and the in-band `source: IRSA` gate replaces it. Do not let any
   spike-time difficulty (§14.1) reopen it.
4. **The reconciled oracle precedence** (§3.3): simulate is a FLOOR, drive-the-
   controller is the signal, the un-exercised-grant tier is async/delta-only. Never
   re-promote simulate to "the proof."
5. **Reaper friendly-fire proofing** (§8): account-mutex, age-floor ≥45 min, skip
   active-lease run-ids, structural deny-list account guard, remediate-and-RED
   after bounded poll. The only thing between on-by-default mutation and a money
   leak on the shared ephemeral account.

## Bottom line

FINAL-PLAN faithfully lands every round-2 resolution — the IRSA fix, git-sourced
expect-full, reconciled oracles, hermetic/singleton partition, RGT-diff,
wall-clock budget, concrete SLO are all correct and present. The plan is the right
document. The one thing it got wrong is the thing it was asked to get right this
round: **constraint correction #2's "build, not CI" trigger is a distinction this
repo does not have** — the bring-up IS `terraform-test.yml action=apply-and-verify`,
a dispatched CI run — so "on by default" now rests on a UI default and the
HEAD-SHA enforcement that should carry the guarantee was demoted to a WARN
(R3-C1, R3-C3, R3-M1). Worse, the GitOps config-only change path (a Composition
edit ArgoCD syncs to the live hub — the auto-012 change shape) has **no live
trigger at all** (R3-C2). Fix: name the real executor, restore the
(HEAD-SHA × account × cluster) live-evidence marker to a FAIL-closed push gate as
the mechanical default-on, apply the expect-full floor on the readonly verify
path, and add a fail-closed trigger for `crossplane/**` config changes. Then the
build-coupled model delivers requirement #1 instead of relabeling it.
