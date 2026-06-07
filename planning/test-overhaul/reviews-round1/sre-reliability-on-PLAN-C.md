# SRE / Production-Ops Adversarial Review of PLAN-C

**Reviewer persona:** skeptical SRE fixated on whether this survives real-cloud
latency, flakiness, isolation/cleanup leaks on an ephemeral account, total
wall-clock + $ per run, the 20-min EKS create, API rate limits, blast radius
against the LIVE cluster developers depend on, and whether "on by default"
actually stays on across a long, occasionally-red suite.

**Verdict in one line:** the *diagnosis* is correct and several mechanisms
(restricted identity, coverage manifest, cleanup-as-assertion) are exactly
right — but the plan is dangerously optimistic about **blast radius against the
shared live cluster**, **cleanup actually running**, **wall-clock/quota math**,
and **flake economics**, and it leaves the single highest-risk mechanism
(restricted identity) as an open question while still scheduling it on-by-default.
As written, this gets switched off within a month. Below: every gap I found,
ranked, with a concrete amendment citing the plan's sections.

---

## CRITICAL findings

### C1. Blast radius: T4 instantiate-and-behave runs against the SAME live mgmt cluster developers depend on (§3.1, §4.2, §5.3, Assumption 5)
The plan's cost lever is "reuse the bring-up's cluster/DB for T4 app/identity
tests" (§5.3, Assumption 5). That means every `apply-and-verify` now **creates
throwaway claims, deployments, ingresses, LBs, IAM roles, and namespaces inside
the live management cluster** that ArgoCD is continuously reconciling and that
other developers/agents are using. Concrete ways this bites THIS system:
- An ingress/LB T4 test (§4.2) creates a real NLB + mutates shared-VPC subnet
  usage and Route53. ExternalDNS and the real ingress controller are *cluster
  singletons*; a throwaway ingress with a colliding host or class can race the
  real ones. The brief's own history includes ingress-nginx admission-webhook
  deadlocks (AGENTS §6.24) — a T4 ingress test that wedges that webhook takes
  down real provisioning, not just the test.
- A T4 namespace + workload churn drives the **pod-IP / ENI exhaustion** class
  that already bit this cluster (AGENTS §6.26: t3.medium ≈ 17 max-pods,
  18/18 IPs). On a `t3.medium × 2` mgmt cluster (testing-guidelines §1), a
  parallel fan-out of T4 workloads (§5.2, concurrency 4) can exhaust pod IPs and
  crash-loop *production* controllers.
- ArgoCD self-heal/prune: if a T4 test creates resources in an ArgoCD-managed
  namespace, auto-sync may prune them mid-test (false fail) or, worse, the test's
  cleanup may fight ArgoCD (false pass / orphan).

**Fix:** Make blast-radius isolation a first-class section, not an assumption.
(a) T4 mutating tests MUST run in a dedicated, ArgoCD-*excluded* namespace
(AppProject deny or `argocd.argoproj.io/sync-options` exclusion) so self-heal
never races them. (b) Cap T4 concurrency by *measured remaining pod-IP headroom
on the mgmt nodes*, not a static "4" (§5.2). (c) Singleton-mutating tests
(ingress controller, ExternalDNS, webhooks) must NOT run against the shared
cluster at all in the default bundle — either gate them behind an explicit
opt-in or run them only against a spoke the bring-up created. (d) State the
explicit invariant: "the default live bundle never mutates a resource a running
controller treats as a singleton."

### C2. "On by default" will be switched off because failure ≠ "code is broken" (§3.2, §3.3, §7, §8.2)
The plan asserts on-by-default + reason-required disable will hold. SRE reality:
a gate that is *frequently red for reasons unrelated to the developer's change*
gets disabled regardless of how loud the disable is. This suite adds 10–15 min
of **live cloud calls on every bring-up** (§5.2 budget), and live calls on an
*ephemeral, rotated* account fail constantly for environmental reasons (AGENTS
§8.2 enumerates the exact shapes: `InvalidClientTokenId`, stale secrets,
245s timeouts). The plan's mitigation is the precondition step tagging failures
`ENVIRONMENT` (§7, §10), but:
- That only covers creds/cluster/state reachability. It does NOT cover
  mid-test transients: Route53 propagation slow, ACM ISSUED taking >budget,
  EKS API throttling under the fan-out, eventual-consistency 404s. Each of
  those reads as a `TEST FAIL` and trains people to ignore red — which the plan
  itself names as the failure mode (§7 intro) and then under-defends.
- "Reason-required disable" (§3.2 guard 1) raises the friction of disabling but
  does nothing to reduce the *rate of false red*. High friction + high false-red
  = people set `LIVE_BUNDLE=disabled, reason="flaky, see #999"` permanently.

**Fix:** The plan needs an explicit **false-positive budget / SLO** for the
bundle (e.g. "live bundle false-fail rate must stay <2% or it auto-demotes the
offending check to the quarantine lane, §7"). Tie the on-by-default promise to a
*measured* reliability target, published in the PR summary (§10), with a
standing dashboard. Without a reliability SLO, "on by default" is aspirational.
Also: separate "the developer's change is bad" from "the environment is bad"
must extend past preconditions to *every assertion*, via a transient-classifier
that re-probes the environment on failure before reporting code-fail.

### C3. Cleanup-as-assertion has a fatal gap: a crashed/cancelled run runs NO cleanup (§6, §3.1 step 5)
The plan leans entirely on `trap EXIT` + `add_cleanup` (§6) and makes cleanup a
tested assertion (§3.1 step 5). Good — but `trap EXIT` does **not fire** when:
- the GitHub Actions job is **cancelled** (SIGKILL / job timeout), which happens
  constantly during the iterative red-CI loops AGENTS §6.7 describes;
- the runner is **evicted** or the step hits the workflow-level timeout;
- the sandbox **suspends mid-wait** (AGENTS §6.20 documents this exact
  lifecycle), leaving a 20-min EKS create or a fan-out of T4 resources stranded.
On an ephemeral account these orphans cost money AND contaminate the next run's
quota (C4). The orphan sweeper (§6) is correctly identified as defense-in-depth
but is deferred to **Phase F** (§12) — i.e. the leak protection lands LAST,
after the bundle has been running on-by-default for the whole rollout.

**Fix:** Promote the orphan sweeper to **Phase A/B**, before any T4 creates
resources by default. Make it a *pre-run* sweep keyed on the `test.k8-platform/
live=true` label + age (§6 already proposes this) AND run it as the **first**
step of every bundle, not just opportunistically. Add a GitHub Actions
`if: always()` cleanup job (fires on cancel) in addition to `trap EXIT`, because
`trap` cannot catch SIGKILL. State explicitly that cleanup correctness does not
depend on the happy-path trap.

### C4. Quota math is hand-waved and will cause mid-bundle cascade failures (§5.2, Open Q5)
The plan notes the **9-instance EC2 ceiling** (testing-guidelines §1) and says
the orchestrator should "query remaining quota and refuse to over-provision"
(§5.2) — then files the actual math as Open Question 5. SRE reality: the mgmt
cluster is `t3.medium × 2` = 2 instances baseline; a spoke EKS cluster the
bring-up created adds its nodegroup; NAT is separate but EIPs are capped at 5
(2 used). After a spoke is up you may have **0–3 instances of headroom**. A T4
fan-out (concurrency 4) that creates *any* instance-backed resource will hit the
cap mid-run, and — critically — a cap hit during Crossplane provisioning
produces a `Synced=False` that looks identical to a real permission bug (the
very class #1 this plan exists to catch). So a quota exhaustion masquerades as a
real-failure, burning a debug loop.

**Fix:** Resolve Open Q5 *before* Phase F, not after. The bundle MUST compute
`headroom = 9 - (mgmt nodes + spoke nodes + any in-flight)` at runtime and set
T4 instance-backed concurrency to `min(4, headroom)`, failing **closed with a
distinct `QUOTA` tag** (cf. the `ENVIRONMENT` tag, §10) so a cap-hit never reads
as `AccessDenied`. Prefer T4 designs that create **zero new instances** (IAM,
secret, DNS, cert round-trips need none) and explicitly forbid instance-backed
T4 in the default bundle on the shared account.

### C5. The restricted-identity mechanism — the entire point of the plan — is unresolved yet scheduled on-by-default (§9, §2 T2, Open Q1/Q2, Assumption 2)
§9 offers three mechanisms (in-cluster verifier job / CI assume-role / T2 stub
simulation) and §13 Assumption 2 admits "if neither [job nor assume-role] works,
the T2 fallback is the floor, which is weaker." Open Q1 and Q2 both flag this as
the primary unknown. But the restricted-identity dimension is what catches
failures #1–#4 (§8) — i.e. **most of the value**. Risks:
- The **CI assume-role fallback** uses the admin CI key to `sts assume-role`
  into the restricted role. But the restricted Crossplane role's trust policy is
  scoped to the **EKS OIDC provider / specific SA** (IRSA), not to the CI key's
  principal. The CI key likely **cannot assume it at all** without trust-policy
  changes — which would then make the test identity *not* the production
  identity, defeating the purpose. The plan does not check this.
- The **in-cluster verifier job** (preferred) requires running a Job *in the
  controller's namespace using the controller's SA* — which means the test has
  cluster-admin-adjacent ability to impersonate production controllers, inside
  the shared live cluster (compounds C1 blast radius).
- **T2 stub honoring restricted creds** (Open Q2) is explicitly "possibly false
  comfort." A green T2 that the stub didn't actually enforce is *worse* than no
  test — it's a silent-pass, the exact class AGENTS §6.24 forbids manufacturing.

**Fix:** Phase C cannot be scheduled until Open Q1 is answered with a *working
prove-it* (one real positive + one real negative call under the restricted
identity, demonstrated end-to-end per AGENTS §6.25 — not one green signal).
Until then, T4-identity tests must be **explicitly SKIP with a counted,
budget-failing skip** (§3.2 guard 2) so "we never wired restricted identity"
reads RED, not green. Add an acceptance test for the mechanism itself: prove the
CI principal can/can't assume the role, and that the negative call is actually
denied by IAM (not by a typo'd ARN returning NoSuchEntity, which also "fails"
but proves nothing).

---

## MAJOR findings

### M1. Wall-clock budget is fiction until measured; "+15 min on every apply" compounds badly (§5.2)
Targets (preconditions <30s, T3 <2min, T4 <10min, total <15min) are stated as
"initial, tune after first runs" — i.e. guesses. On a rotated account with cold
AWS API paths, ACM ISSUED alone can exceed 10 min; Route53 propagation is
minutes; an EKS `describe` fan-out under throttling adds retries. 15 min *on top
of* a ~20-min EKS apply means a 35-min bring-up, every time. That's the wall-clock
that makes people disable it (ties to C2).
**Fix:** Make the budget a *gate with measured actuals* from day one (§10 already
proposes publishing actuals — promote it to Phase B). If a tier blows budget,
that's a tracked issue (AGENTS §6.18), not a silent slowdown. Set a hard
per-bundle wall-clock ceiling that fails the bundle (so a hung describe can't
hold a bring-up hostage for an hour).

### M2. `verify` action re-runs "the relevant slice" — but T4 *creates resources*, so `verify` is no longer cheap/idempotent (§3.3, §5)
§3.3 says the bundle "runs again on `verify` (cheap, no Terraform)." But T4
instantiate-and-behave *creates and destroys real cloud resources* (§4.2). Re-
running it on every `verify` means every read-only verification now provisions
NLBs/IAM/secrets and depends on cleanup succeeding. That's neither cheap nor
side-effect-free, and it multiplies C3/C4 exposure by the number of `verify`
invocations (which agents call frequently per AGENTS §6.3).
**Fix:** Split the bundle: `verify` runs only **T3 (read-only Describe*)** +
precondition + coverage cross-check. T4 (mutating) runs only on
`apply-and-verify`. Make this split explicit in §3.1/§3.3 so `verify` stays a
true read-only operation.

### M3. Coverage manifest source-of-truth will drift or block unrelated work (§3.2 guard 3, Open Q3, §12 Phase A)
The durable anti-rot guard depends on deriving "what resources does this phase
create" from Terraform plan JSON + Composition `resources[]` (Open Q3 admits
this may have to be hand-maintained and thus drift). Two failure modes: (a) if
auto-derived, side-effect resources (the untagged subnets, an LB created by a
controller, an OIDC provider) are *exactly* the ones not in `resources[]` — i.e.
the guard misses the same class it's meant to catch (failure #5 was a missing
*tag* on a shared subnet, not a Composition resource). (b) if hand-maintained,
the unit test (`test_live_coverage`) goes red on every PR that adds a resource,
blocking unrelated work until someone updates the manifest — friction that gets
the test weakened (AGENTS §6.24 risk).
**Fix:** Resolve Open Q3 before Phase E flips enforcement. Derive from BOTH
Terraform plan JSON AND the live `aws resourcegroupstaggingapi` view of what was
actually created (catches side-effects), and reconcile. Add a "known side-effect
resources" allowlist that is itself reviewed. Define the grace-window /
skip-budget thresholds (Open Q6) concretely, not "tune later."

### M4. Negative tests that withhold the DB run in the shared cluster too (§4.3, C1 overlap)
The §4.3 precondition test "make the DB unavailable / withhold its secret and
assert Keycloak stays NotReady" is the right test — but executed against the
shared mgmt cluster it means deliberately breaking a dependency in a live
namespace, and the proposed Kyverno admit-gate (route a) is a *cluster-wide*
admission policy. A mis-scoped admit-gate that blocks "auth workload without DB
readiness signal" can block the *real* Keycloak on a transient DB blip — a
self-inflicted outage.
**Fix:** Negative/precondition tests run in an **isolated throwaway namespace
with their own throwaway DB**, never by degrading shared infra. The Kyverno
admit-gate must be scoped by label/namespace and itself have a negative test
proving it doesn't block healthy real workloads. Cite this isolation explicitly
in §4.3.

### M5. Parallel fan-out + per-test cleanup races the shared orphan label (§5.2, §6)
Concurrency 4 with a *shared* sweep label (`test.k8-platform/live=true`) plus a
*pre-run* age-based sweeper (§6) creates a race: a concurrently-running bundle
(two developers, or a `verify` overlapping an `apply-and-verify`) can have its
in-flight resources swept by the other run's pre-sweep if the age threshold is
short, or leaked if long. The plan assumes single-run serialization but the
shared live cluster permits concurrent dispatches.
**Fix:** Scope the sweeper to `RUN_ID`-prefixed resources older than N hours AND
exclude any `RUN_ID` currently registered as active (a lightweight in-cluster
lease / ConfigMap of live run IDs). Add a concurrency guard on the workflow
(`concurrency: live-bundle-${cluster}`) so two mutating bundles don't run against
the same cluster at once.

### M6. Transient-retry policy can mask a real intermittent failure (§7)
"Wrap cloud API calls in bounded retry-with-backoff for known transient classes
only; never retry an assertion" (§7) is correct in principle, but the boundary
is fuzzy: a real IAM permission that is *eventually* granted by an async policy
attachment looks identical to throttling on first read. Retrying it hides a real
race in production IAM propagation (which is itself a bug class worth catching).
**Fix:** Log every retry with the classified reason in the auto-dump (§10), and
cap retries low (e.g. 3). If a test only passes *with* retries, surface that as a
warning in the PR summary — "passed on retry N" is a flake signal (AGENTS §6.18),
not a clean pass.

### M7. No story for in-flight EKS create failing the after-the-fact T3 (§4.1, Req 3)
T3 verifies the cluster the bring-up created is ACTIVE. But if the 20-min EKS
create itself failed/timed out, the bundle's T3 will report "cluster not ACTIVE"
— correct, but it's reporting the apply's failure, not adding value, and the
plan doesn't say how the bundle distinguishes "apply failed" (upstream) from
"cluster created but unhealthy" (the thing T3 should catch). Conflating them
sends people debugging the wrong layer.
**Fix:** T3 must short-circuit with a distinct `UPSTREAM-APPLY-FAILED` status
when the apply step didn't complete, vs. `RESOURCE-UNHEALTHY` when it did but the
resource is wrong. Same disambiguation discipline as the ENVIRONMENT tag (§10).

---

## MINOR findings

### m1. Path/name accuracy (§10, §11)
The plan cites `scripts/compute-gates.sh` (§11); the file is actually at
`.github/scripts/compute-gates.sh`. The `STEP_LABELS`/`OUTCOMES` keys-equal
invariant (§10) is real (in `.github/scripts/post-comment.py`). Minor, but the
synthesis should fix the path so an implementer doesn't waste a lookup.

### m2. `SPEC-LC5-cleanup-orphans.md` / `SPEC-C3` / `SPEC-S7` etc. referenced but not verified to exist (§6, §8, §7)
The plan cites several specs as prior art. If any are backlog-only, the plan's
"align with it" instruction is a dangling dependency. Synthesis should confirm
each cited spec exists or mark it as to-be-authored.

### m3. `test.k8-platform/` label namespace typo risk (§6)
Label used is `test.k8-platform/live=true`. The repo is "k8-platform" in places
and "k8s-platform" as the dir. A label-prefix typo means the sweeper silently
matches nothing (a leak that reads green — the worst kind). Pin the exact label
string and add a unit test asserting every T4 test sets it.

### m4. PR-summary observability assumes the summary mechanism scales (§10)
Adding per-tier pass/fail/skip + wall-clock + coverage delta + switch state to
the existing comment is fine, but the `post-comment.py` keys-equal regression
test (§10) means every new field needs paired `STEP_LABELS`/`OUTCOMES` edits or
CI goes red. Flag this coupling so the implementer doesn't trip it.

### m5. Idempotency double-run lane is good but deferred to Phase F (§6, §12)
The back-to-back double-run idempotency lane is exactly the right SRE test, but
deferring it to Phase F means idempotency bugs ship for the whole rollout.
Move at least a single manual double-run check into Phase C/D acceptance.

---

## What the plan got RIGHT (synthesis MUST preserve)

1. **The diagnosis and the identity×fidelity matrix (§0, §2).** "Real cloud ×
   restricted identity" is precisely the empty cell, and admin creds are exactly
   what hid #1–#4. This framing is correct and load-bearing — keep it.
2. **Restricted-identity is non-negotiable for T4 (§9).** Even though the
   *mechanism* is unresolved (C5), the *requirement* is right. Do not let the
   synthesis water this down to "test under admin, it's easier."
3. **Cleanup as a tested assertion, not best-effort; no `|| true` (§6).**
   Aligns with AGENTS §6.19. This is the correct posture — just needs the
   crash-path coverage from C3.
4. **Anti-silent-regression via three independent guards + "everything-skipped
   never reads green" (§3.2).** The skip-budget + counted-SKIP + coverage
   manifest combination is the right shape and directly answers Req 2. Preserve
   all three; a single guard rots.
5. **Slow resources verified after-the-fact only; never recreate EKS/RDS in test
   (§4.1, §5.1).** Correct cost discipline and directly satisfies Req 3.
6. **Reuse existing primitives verbatim** — `wait-for-claim.sh`,
   `crossplane-claim-verify`, `RUN_ID`/`trap`/`add_cleanup`, the #11
   PlatformSecret pattern as the T4 template (§1, §4.2). Don't rebuild these.
7. **Precondition step as a hard gate that tags ENVIRONMENT vs TEST-FAIL
   (§3.1 step 1, §10).** The single best defense against the rotated-account
   false-negative class (AGENTS §8.2). Keep — and extend it past preconditions
   to every assertion (C2/M7).
8. **Phased rollout ordering A→B→F with "make the gap visible first" (§12).**
   The sequencing instinct is sound; the only changes needed are pulling the
   orphan sweeper (C3) and quota math (C4) earlier, and gating Phase C on the
   identity prove-it (C5).
9. **Negative + precondition testing as first-class (§4.3).** Bad-param
   rejection and fail-closed health-gates are exactly Req 5; preserve the
   "test fails if the bad claim succeeds" inversion.

---

## Bottom line for synthesis
The plan's *intent* is right and most of its mechanisms are reusable. It will
not survive contact with production unless the synthesis: (C1) hard-isolates T4
from the shared cluster, (C2) ties on-by-default to a measured false-fail SLO,
(C3) makes cleanup survive job-cancel/suspend and runs the sweeper FIRST, (C4)
resolves quota math before instance-backed T4, and (C5) proves the
restricted-identity mechanism end-to-end before scheduling Phase C on-by-default
— with every gap reading RED (counted skip), never green.
