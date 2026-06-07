# Adversarial review of PLAN-C — DevX & Maintainability lens

**Reviewer persona:** developer-experience & maintainability adversary. The
question I keep asking is not "is this correct?" but "will an engineer six
sessions from now actually run this, keep it green, and not quietly route
around it — or will it rot into a disabled gate and a stale manifest?"

**Verdict in one line:** PLAN-C is the most operationally-honest of the test
plans — it reuses the right primitives and names the real blind spot — but it
is *heavy*, and almost every load-bearing anti-rot mechanism it proposes is
a new piece of bespoke infrastructure that itself needs maintaining. Three of
its central claims are also contradicted by the very assets it cites as the
model. Left as written, the most likely 6-month outcome is: `LIVE_BUNDLE`
quietly defaulted to `disabled` in the common dispatch, `coverage.yaml`
drifted and permanently in "warn" mode, and the T4 suite quarantined as
"flaky" with no owner. Below, ranked, with concrete fixes.

---

## CRITICAL findings

### C1. The "everything-skipped can never read green" guarantee is contradicted by the harness the plan models it on. (§3.2 guard 2, §3.1 step 5)

The plan says the bundle distinguishes PASS/FAIL/**SKIP** "like
`tests/integration/run.sh` does" and that "everything skipped can never read
as green." I read `tests/integration/run.sh`. It does the **opposite**: a
script that `exit 2` is counted as SKIP and the orchestrator **`exit 0`** as
long as `FAIL == 0`. SKIP is benign. And the integration tests use SKIP as
the normal path when phase-1 isn't deployed (e.g.
`08_irsa_sts_round_trip.sh` → `skip "...phase 1 not deployed"`). So the
existing idiom is *exactly* "all-skipped reads green," and the live tests are
the case where the environment-absent skip is most common (rotated account,
no cluster, restricted role not discoverable).

**Why it bites THIS system:** the rotated-ephemeral account means "resource
absent / creds not yet wired" is the *steady state* at the start of most
sessions. Under the existing skip semantics, a live bundle run against a
half-built or mid-rotation account returns green-with-all-skips — precisely
the silent-disable the brief (requirement #2) forbids, and precisely the
class (§8.2/§8.4) the repo has been burned by repeatedly.

**Fix:** the plan must not say "like run.sh does" — it must specify the
*inverted* contract and own it as new code: the bundle computes an *expected
set* (from the coverage manifest, per phase) and **fails** if any expected
test SKIPped, rather than only failing on FAIL. State explicitly that
`exit 0 && skip>0` is a bug, add a unit test for the orchestrator's
tabulation logic (`phase=test` style) that asserts all-skip → non-zero, and
distinguish "ENVIRONMENT-absent skip" (which fails the bundle, because the
bring-up *claims* the environment exists) from a legitimately-not-applicable
skip. Without this, guard 2 is decorative.

### C2. The coverage manifest is the load-bearing anti-rot guard and it is the single most rot-prone artifact in the plan. (§3.2 guard 3, §13 open Q3)

Guard 3 — `tests/live/coverage.yaml` + `test_live_coverage.sh` — is what the
plan leans on so "absence of a test is a first-class failure." Open question
3 already admits the source-of-truth derivation may have to be
hand-maintained. As a maintainability adversary this is the finding I care
about most: **a hand-maintained coverage manifest is a second copy of the
truth, and second copies drift the instant attention lapses.** The plan's own
repo history is full of "two things must stay in sync and didn't"
(§6.16: 17 of 39 unit tests missing from the workflow list). A YAML that
enumerates "every resource every Composition/Terraform module creates" is a
strictly harder sync problem than that one, and it has no compiler.

**Why it bites:** the manifest will be edited to *make CI green* (add an
entry pointing at a stub test, or worse, mark a resource `covered: false`
with a TODO) rather than to reflect reality — and AGENTS.md §6.24 (never
weaken a check to go green) will be honored in spirit by deleting it in
practice, because the manifest *is* the check and it's the cheapest thing to
edit. Six sessions later it asserts a fiction.

**Fix (pick the enforceable one, not both):**
- **Derive, don't declare.** Make the "what does this phase create" side
  *generated* — parse Composition `resources[].base.kind` and the Terraform
  plan JSON `resource_changes[].type` at test time, and have
  `test_live_coverage.sh` diff the *generated* set against the *test
  registry* (which test defends which kind). The human only maintains the
  registry side, and only *additions* (a new kind) can break CI — which is
  the desired behavior. If derivation is genuinely incomplete (side-effect
  resources), allow a small, explicitly-justified `extra:` list with a
  required `reason:` per entry (mirror §3.2 guard 1's reason-required idea).
- **If you cannot derive**, then guard 3 is not durable and the plan must say
  so honestly and downgrade it from "the durable anti-rot guard" to "a
  best-effort checklist" — do not sell a hand-list as un-regressible.

The plan currently has it both ways: calls it "the durable anti-rot guard"
*and* flags its source-of-truth as an open question. Resolve before this is
the spine of requirement #2.

### C3. "On by default, never silently disabled" has a single point of subversion the plan doesn't close: the dispatch input default itself. (§3.2, §11)

The disable mechanism is `LIVE_BUNDLE=enabled|disabled` defaulting to
enabled, with reason-required. Good. But the *default* lives in workflow YAML
(`workflow_dispatch.inputs.LIVE_BUNDLE.default`). Changing that one line from
`enabled` to `disabled` is a one-character diff that turns the whole edifice
off — and it would *pass every guard*, because reason-required only fires
when someone explicitly passes `disabled`, not when the default is flipped.
The skip-budget and coverage manifest also can't see it: if the bundle never
runs, nothing reports a skip.

**Why it bites:** under throughput/auto modes (§6.6) an agent fighting a red
live bundle on a rotated account is *exactly* the actor who will "temporarily"
flip the default to unblock a stack of PRs and forget. The plan's own §6.24
anti-pattern.

**Fix:** add a push-time unit/lint assertion (it belongs next to the §11
"`LIVE_BUNDLE`-switch lint") that the YAML default is literally `enabled` —
make the *default value itself* a tested invariant, not just the runtime
reason. And require that any run with `LIVE_BUNDLE!=enabled` (default OR
explicit) writes the disabled banner to the PR summary, so a flipped default
is as loud as an explicit disable.

---

## MAJOR findings

### M1. The plan adds five tiers, three identity mechanisms, a manifest, an orchestrator, a sweeper, a budget board, and a triage playbook — and never confronts its own maintenance surface against the team that quietly under-used the *existing* helper. (§2, §3, §6, §10, §12)

The diagnosis (§0) is that `crossplane-claim-verify` was "underused,
optional." The remedy is ~9 new maintained surfaces. The plan never asks the
adversarial question: *if the team couldn't be bothered to call one existing
skill, what makes a five-tier taxonomy with a coverage manifest and a quota
calculator stick?* Heavier machinery is under-run *more*, not less. The
T0–T4 taxonomy plus the admin/restricted × fake/real 2×2 (§2) is genuinely
clarifying for a doc but is onboarding cost: a new contributor must now
classify every test they write into a 5-tier × 2-axis grid before they can
add coverage.

**Fix:** sequence and *gate adoption on usage*, not completeness. Phase A/B
(§12) are the high-ROI, low-surface parts (deepen T3, make the gap visible).
Commit to shipping A+B and **measuring whether they're actually run on every
bring-up for two real sessions** before building C/D/E's new identity
mechanism and orchestrator. Collapse the taxonomy in contributor-facing docs
to a 2-line decision ("does it need the real cloud? does it need the
restricted role?") and keep the 2×2 as appendix rationale. Do not present
T0–T4 as five things a contributor must learn.

### M2. Flaky-test fatigue is the predictable death of this suite, and the mitigation is goodwill ("quarantine, never silence") with no teeth. (§7)

Live AWS calls against an ephemeral account *will* be flaky: eventual
consistency, throttling, Route53 propagation, cold-start providers (the repo
already has `composition-drift` cold-start flakes in `docs/open-issues.md`).
The plan's defense is "quarantine to a non-gating lane with a tracking issue
and an owner" and "two occurrences without an entry IS the problem." That's a
*norm*, not a *mechanism* — there is nothing that *detects* the second
occurrence or *assigns* the owner. The same goodwill that failed to call the
existing skill will fail to file the issue at 11pm in an auto-run.

**Why it bites:** the first time the live bundle blocks a merge on a Route53
propagation timeout that's "obviously not my change," the path of least
resistance is to bump the timeout (weakening the check, §6.24) or flip
`LIVE_BUNDLE=disabled` with reason "flaky, see issue" (C3). Either way the
gate is gone for that PR and the next.

**Fix:** make quarantine mechanical. (a) The orchestrator emits a stable
per-test ID and outcome to a small append-only log; a push-time check flags
any test that FAILed in N of the last M bundle runs and **auto-opens/-updates
the `docs/open-issues.md` entry** rather than relying on a human to notice.
(b) A quarantined test must keep running in the non-gating lane *and* its
quarantine must carry an expiry — a quarantine older than X with no owner
update fails the push check. Otherwise "quarantine" is "delete with extra
steps." (c) Separate the *transient-retry* envelope (§7) per AWS error class
into a single shared helper so the retry policy is reviewed in one place, not
re-implemented (and mis-tuned) per test.

### M3. T4 "instantiate-and-behave under the restricted identity" depends on an unresolved mechanism, yet the plan's whole value proposition (catching #1–#4) rests on it. (§9, §13 open Q1/Q2)

The four most important failures (#1–#4: IAM perms, IRSA binding, blocking
default, SA-name mismatch) are caught *only* by T4-under-restricted-identity.
The mechanism for obtaining that identity is open question #1, with three
fallbacks of decreasing fidelity, and the cheapest (T2 stub-with-restricted-
creds) is flagged by the plan itself as possibly "false comfort" (open Q2).
So the plan's headline ROI is gated on an unsolved problem, and its fallback
may not catch anything.

**Why it bites (DevX angle):** the "in-cluster verifier job that assumes each
controller SA" is elegant but is a *whole new test-execution substrate* —
jobs in controller namespaces, RBAC to run as those SAs, log exfiltration
back to the bundle, cleanup of the jobs themselves. That's a large, brittle,
specialist-owned surface. If it's flaky or hard to debug (and cross-namespace
job orchestration over a private kube-API reachable only from CI — §6.26/§6.27
— will be), it's the first thing disabled.

**Fix:** the plan should commit to the **CI `assume-role` fallback as the
*primary* mechanism for #1–#4**, not the in-cluster job. `sts assume-role`
into the restricted role ARN + positive/negative cloud calls catches the
exact permission/identity classes with a *tiny, debuggable* surface and no
new in-cluster substrate. The plan even concedes it "catches the permission/
identity classes cleanly." Reserve the in-cluster verifier job as a later,
optional fidelity upgrade (Phase F), not the recommended primary (§9 says
in-cluster is primary — invert that for maintainability). And explicitly
**drop T2** unless open Q2 resolves positive — a tier the author suspects is
false comfort should not ship; it's pure maintenance debt that trains people
to trust a green that means nothing.

### M4. "Coupled to the change, not a nightly" has weaker enforcement teeth than the prose implies. (§3.3, §11)

The plan satisfies requirement #6 by running the bundle inside
`apply-and-verify`. But `apply-and-verify` is a `workflow_dispatch` action an
agent chooses to run; the *push-time* enforcement is only the §11 verifier
("confirm a green live-bundle run exists for the PR's HEAD SHA"), mirroring
§6.7. That verifier is the real teeth — and it's mentioned in one clause. For
a *Terraform/Composition* change that doesn't touch a unit-tested path, what
*forces* a live-bundle dispatch before merge? §6.7's own note admits
`terraform-test.yml` "does not yet have a verifier." So today, nothing.

**Why it bites:** "coupled to the change" degrades to "coupled to whoever
remembers to dispatch apply-and-verify," which is the same goodwill that
under-ran the skill. A Composition edit can merge with zero live evidence.

**Fix:** elevate the HEAD-SHA verifier from a clause to a first-class
deliverable in Phase E, *with* the path-trigger that decides *when* a green
live-bundle run is required (which changed paths demand it — crossplane/**,
terraform/**, clusters/**). State the rule: "PR touching <these paths> is
mergeable only if a green live-bundle run is cached on HEAD SHA." That is the
actual implementation of requirement #6; the in-dispatch run alone is not.

### M5. Negative tests (#5, Keycloak-without-DB) are the highest-maintenance, most-likely-to-flake tests in the plan, and the plan proposes building *two* implementations of each. (§4.3, §13 open Q4)

Requirement #5 is real and the plan takes it seriously. But "withhold the DB
and assert the auth deployment stays NotReady" is a *timing* assertion ("must
NOT become ready") — the hardest kind to make non-flaky, because proving a
negative requires waiting long enough to be confident it won't flip, which is
slow and still probabilistic. And §4.3 proposes *both* a Kyverno admit-gate
*and* a live withhold-DB test "I recommend both" — doubling the surface for
the single hardest-to-maintain contract, with open Q4 unresolved on which one
actually gates.

**Why it bites:** a "must stay NotReady for 5 minutes" test adds 5 minutes to
every bundle (blowing the §5.2 <15min budget) or is shortened and becomes
flaky-by-construction. Two implementations means two things to keep in sync
and two things to disable when one flakes.

**Fix:** make the **Kyverno admit-gate the single gating mechanism** for #8
(it's continuous, fast, deterministic, and already the repo's idiom for
runtime invariants — §6.1). The live withhold-DB test becomes a *one-time*
Phase-D acceptance check that the admit-gate + startup probes behave, run on
demand, **not** part of the every-bring-up budget. Resolve open Q4 in the
plan rather than shipping both as co-gates.

---

## MINOR findings

### m1. Parallel fan-out + quota-aware concurrency (§5.2) is real complexity for a budget the plan hasn't shown is breached.
The plan moves from `run.sh`'s serial loop to "bounded concurrency 4" *and* a
runtime EC2-quota calculator that "queries remaining quota and refuses to
over-provision." A live quota calculator that has to know "mgmt nodes + NAT +
any spoke" math (open Q5, unanswered) is a brittle, account-shape-coupled
piece. Most T4 resources (secret/IAM/DNS/cert) are *not* instance-backed, so
the 9-instance ceiling only constrains the ingress/LB test. **Fix:** keep the
orchestrator serial initially (it's debuggable and the non-instance T4 set is
seconds-to-minutes); defer fan-out + quota math to Phase F and only if a
measured budget breach justifies it. Don't pay the concurrency-bug tax up
front.

### m2. `test.k8-platform/live=true` label-sweep cleanup assumes all Crossplane-created out-of-band AWS resources carry the label. (§6, open via §6's own [K8S-SPECIALIST] flag)
Crossplane creates downstream cloud resources (the LB behind an ingress, the
ASM secret behind a PlatformSecret) whose tagging the *test* doesn't fully
control. A label-only sweep will miss exactly the orphans that cost money on
the ephemeral account. **Fix:** the cleanup *assertion* (§6, step 5) must key
off the `RUN_ID` *prefix on the XR/claim name* (which the test does control)
and then verify deprovisioning *down the tree*, not off a label on leaf cloud
resources. Align with `SPEC-LC5` but state that label-sweep is defense-in-
depth, not the primary teardown check.

### m3. Idempotency "double-run lane" (§6, §12 Phase F) doubles wall-clock and cost on an ephemeral account for a property better asserted cheaply.
Running the whole bundle twice back-to-back to catch idempotency regressions
is expensive insurance. **Fix:** assert idempotency *per-test* (each T4's
create-if-absent + no-op-teardown is checked within its own run) rather than
a whole-bundle re-run lane; keep the double-run as a rare manual lane, not a
standing one.

### m4. The PR-summary comment is becoming a god-object. (§10)
The plan piles per-tier pass/fail/skip, per-tier wall-clock vs budget,
`LIVE_BUNDLE` state+reason, and coverage-manifest delta onto the existing
comment — which already has a `STEP_LABELS`/`OUTCOMES` keys-equal invariant
with its own regression test. Each addition is another sync point. **Fix:**
fine to extend, but each new field needs its own assertion in the existing
keys-equal test (the plan says "extend in lockstep" — make that a hard
checklist item, not an aside), or the comment silently drifts like §6.16's
workflow list did.

### m5. Phase A "warn-then-fail after a grace window" is where anti-rot guards go to die. (§12 Phase A, §3.2)
A guard that warns indefinitely is a guard that never fails. Open Q6 even asks
"when to flip from permissive to enforcing" — i.e. the plan ships the *off*
state and defers the *on* decision. **Fix:** put a hard date/commit-count on
the flip *in the plan* (e.g. "enforcing by Phase E merge, no later"), and
make the warn period itself fail if it's exceeded — a permissive guard older
than its grace window is a CI failure. Otherwise Phase A's "make the gap
visible" is the whole plan that actually ships and the rest stays "warn."

### m6. Terminology: the plan repeatedly says "claim" where this repo is Crossplane v2 (no claims). (§4.2, §6, §8, throughout)
AGENTS.md §12.1 is explicit: these are XRs, not claims; "create a throwaway
instance via a claim," "the IAM role claim," "DNS record claim" will read as
out-of-date to maintainers and the v1-era framing risks a real design slip
(e.g. waiting `--for=condition=Offered`, which §6.8 notes never appears in
v2). **Fix:** scrub to "XR / composite resource"; quote v1-holdover proper
names verbatim only where they're literal artifact names.

---

## What the plan got RIGHT — the synthesis MUST preserve these

1. **The diagnosis and the 2×2 blind-spot framing (§0, §2).** "real cloud ×
   restricted identity" is *exactly* the empty cell all eight failures live
   in, and "admin creds are what hid #1–#4" is the single most important
   true sentence in any of the plans. Any synthesis that keeps testing under
   admin reproduces the blind spot. **Non-negotiable to preserve.**
2. **Reuse over rebuild (§1).** Explicitly building on `wait-for-claim.sh`,
   `crossplane-claim-verify`, the `RUN_ID`/`trap`/`add_cleanup` isolation,
   and the §11 PlatformSecret pattern (#11) as the generalizable shape — and
   *not* building a better cloud mock (§15) — is the right instinct and the
   one that keeps maintenance bounded.
3. **The failure-class → catching-test matrix (§8).** Mapping each of the 8
   live failures to a specific tier *and* "why it slipped today" is the
   deliverable that makes coverage auditable and keeps the suite honest about
   what it does/doesn't defend. Preserve this table verbatim as the spec.
4. **Precondition-as-hard-gate to disambiguate environment-vs-code (§3.1
   step 1, §7, §10).** Making rotated-account/unreachable-cluster fail *as a
   distinct ENVIRONMENT precondition* up front is directly responsive to the
   repo's most-repeated pain (§8.2) and is the right defense against
   flaky-by-environment fatigue.
5. **No-fresh-cluster/DB-per-test; slow resources after-the-fact only
   (§4.1, §5).** Correctly maps requirement #3 to cost reality on an
   ephemeral account. This is the cost discipline that makes "every
   bring-up" affordable at all — keep it.
6. **Cleanup is a tested assertion, not best-effort; no `|| true` (§6).**
   Directly honors §6.19/§6.24 and the cost-leak risk. Preserve.

---

## Bottom line for the synthesizer

Keep PLAN-C's *diagnosis, the restricted-identity insight, the §8 matrix,
the reuse posture, and the precondition gate.* Cut or defer its heaviest
bespoke machinery until the cheap high-ROI layer (deepened T3 + visible-gap)
is proven to actually get run. Fix the three contradictions before anything
ships: the skip-semantics inversion (C1), a derived-not-declared coverage
guard (C2), and a tested default-value invariant (C3). And replace
"goodwill" enforcement (quarantine norms, in-dispatch-only coupling) with
mechanical teeth (auto-quarantine + HEAD-SHA verifier with path triggers),
or this becomes a disabled gate and a lying manifest within a few sessions.
