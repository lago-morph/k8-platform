# Round-3 DevX / Maintainability Review — FINAL-PLAN.md

**Reviewer persona:** developer-experience & maintainability adversary.
**Question driving every finding:** will engineers actually run and maintain
this, or quietly disable it? With the trigger now BUILD-COUPLED (not CI), is the
inner loop sane, and is "on by default" *enforced* — or does build-coupling rest
on goodwill to invoke the suite?

**Verdict in one line:** the round-2 resolutions are genuinely strong and the
plan is far more honest than the synthesized version, but **correction #2
("the trigger is the BUILD, not CI") is built on an artifact that does not exist
in this repo, and that hole quietly converts the headline "on by default"
guarantee into goodwill.** That is the central DevX failure and it is Critical.

I verified the load-bearing claims against the tree this session; citations
inline.

---

## CRITICAL

### C1. "The build invokes `tests/live/run.sh` as its final phase" — there is no build to wire it into. The committable artifact does not exist; `apply-and-verify` IS a `workflow_dispatch` GitHub Actions workflow, so correction #2 is internally contradictory.

This is the spine of the entire revised plan and it rests on a phantom.

The plan says, repeatedly (§4.1, §4.2, §10, §12 ledger row 1, §15, §18), that
"the bring-up procedure — the operator/agent's `apply-and-verify` /
cluster-creation flow — **invokes `tests/live/run.sh` as its final phase**,"
and that this is "**requirement #1's real every-bring-up guarantee**." It draws
a hard line: build-time ≠ CI, *because* CI fires at PR/commit time which is
decoupled from the bring-up.

What is actually in the repo:

- `apply-and-verify` exists **only** as an `action=` input value on
  `.github/workflows/terraform-test.yml` (verified: terraform-test.yml:24, and
  the `[base]/[management] e2e-verify` steps gate on
  `action=apply-and-verify`, :232/:315). It is a `workflow_dispatch:` workflow
  (terraform-test.yml:3-4).
- There is **no** `scripts/apply-and-verify.sh`, no `bring-up.sh`, no
  "cluster-creation flow" script. `ls scripts/` shows diag/status/verify
  helpers only; the bring-up is the `terraform-test.yml` dispatch (AGENTS §5,
  testing-guidelines §6 phase procedure: "`workflow_dispatch (phase=N,
  action=apply-and-verify)`").

So the plan's foundational distinction collapses: **the build flow IS a GitHub
Actions workflow** — specifically the `workflow_dispatch`-triggered
`terraform-test.yml`. There is no third place. "Coupled to the build, not CI"
is a distinction without a referent: the build *is* a CI workflow (just a
dispatch-triggered one, which is exactly what AGENTS §6.7 prescribes and what
the plan itself classifies as "context 3, never the every-bring-up guarantee").

The consequences for DevX are severe and concrete:

1. **The "every bring-up" guarantee is undeliverable as described.** The
   committable half (§12 row 1: "`tests/live/run.sh` + its self-test") is real,
   but the "other half" — "the bring-up/build-flow wiring that invokes it" — has
   nowhere to live *except* `terraform-test.yml`. Which means it is wired into a
   `workflow_dispatch` workflow, i.e. it only runs when a human/agent dispatches
   it. That is **exactly the goodwill dependency the persona was told to hunt
   for.** "On by default" reduces to "on by default *if* someone dispatches
   `action=apply-and-verify`."

2. **The static "wired-and-on-by-default" lint (§4.2) cannot do what it
   claims.** §4.2 says a push lint will "grep the flow definition for the
   invocation" of `tests/live/run.sh`. The only flow definition that exists is
   `terraform-test.yml`. Editing it requires the `workflow` scope, which the
   plan itself says the git-push token and GitHub MCP lack (§4.1) — so the live
   suite gets wired in *via jentic*, and the push lint asserting that wiring is
   present is asserting a property of a workflow file the normal push path
   cannot even modify. The lint and the wiring live on opposite sides of the
   `workflow`-scope wall. The plan never reconciles this.

3. **The agent-driven inner loop already runs the suite a different way.**
   AGENTS §6.3 ("Always run all tests when the environment is brought up") tells
   the agent to run `tests/integration/run.sh` etc. *after* `apply-and-verify`
   as a **separate manual step**, not as a phase *inside* the workflow. The plan
   never acknowledges that the de-facto "bring-up invokes the suite" mechanism
   today is **an AGENTS.md instruction to the agent** — i.e. goodwill — not a
   wired build phase. If that is the intended home, the plan must say so and must
   confront that AGENTS-instruction ≠ mechanical enforcement.

**Fix (pick one, name it explicitly in the plan):**

- **(a) Honest framing:** state that the only build flow is
  `terraform-test.yml` (dispatch-triggered), add a new
  `e2e-verify`-style step that invokes `tests/live/run.sh` *gated on
  `action=apply-and-verify`* inside that workflow, landed via jentic. Then "on
  by default" means "default-on whenever `apply-and-verify` is dispatched,"
  and the all-skipped⇒RED / expect-full floor live inside that workflow step.
  This is deliverable and honest — but it makes the "build, NOT CI" distinction
  cosmetic and the plan must drop the rhetoric that they are different things.
- **(b) Real script:** create `scripts/apply-and-verify.sh` as the canonical
  bring-up entrypoint that both the agent and `terraform-test.yml` call, with
  `tests/live/run.sh` as its final line. Then the §4.2 grep-lint has a real,
  push-editable target. This is more work but actually delivers the spine.
- Either way: **the plan as written claims a guarantee whose enforcement point
  does not exist. That must be corrected before P1, because P1 ships "the
  build-flow wiring that makes the bring-up invoke `tests/live/run.sh`" (§16) —
  an implementer will reach P1 and discover there is nothing to wire.**

This is the one finding that, left unaddressed, reproduces the exact disease the
overhaul exists to kill: a green that proves nothing because the verifying step
was never actually invoked.

---

## MAJOR

### M1. Build-coupling silently weakened the all-skipped⇒RED teeth, and the plan half-admits it via the "static-evidence backstop."

All four invariants (§18) — on-by-default, disable-able-not-disabled,
all-skipped⇒RED, coupled-to-change — are now enforced **only when the suite
actually runs at build-time**. Under the old CI model, a PR could not go green
without the check; under build-coupling, *nothing at PR time forces the suite to
have run at all.* The plan's answer is the "HEAD-SHA live-evidence marker"
static backstop (§4.3, §12, §15): a committed marker per HEAD SHA, missing ⇒
push WARN/FAIL.

This is the right instinct but it is **under-specified to the point of being
un-implementable as a teeth-bearing gate**, and it reintroduces a
goodwill/forgery surface:

- **Who writes the marker, and what stops a human writing it by hand?** A
  committed file that says "SHA abc123 had a green live run" is exactly the
  self-attested oracle §4.3 spends a page forbidding for `expect-full`. If the
  marker is hand-committable, an engineer under deadline writes
  `green: true` and the push goes green with zero live runs. The plan must
  specify the marker is **machine-emitted only** (signed by the live-run, e.g.
  contains the run-id + a value derived from real cloud state the run observed)
  and that the push lint validates that provenance — otherwise it is the
  skip-is-green hole wearing a marker file's clothes.
- **WARN vs FAIL is left open** ("push WARN/FAIL"). A WARN is ignorable; under
  flaky-test fatigue it WILL be ignored. If this is the secondary anti-regression
  guarantee, it must be FAIL with a registered, expiring exception — same
  discipline as the SKIP_REGISTER.
- **It re-opens "coupled to whoever remembers."** §4.3 itself worries about this
  ("not reduced to coupled to whoever remembers to dispatch") and then leans the
  whole secondary guarantee on a marker that only exists if someone dispatched
  the build. The honest statement is: under build-coupling, the PR-time
  guarantee is **necessarily** weaker than CI-gating was, and the residual rests
  on (a) the marker's forgery-resistance and (b) someone running the build. The
  plan should say that plainly in §18's "no property was weakened" paragraph —
  which is currently **false as written**: the PR-time enforcement property *was*
  weakened, by design, and pretending otherwise is the kind of overclaim that
  erodes reviewer trust.

**Fix:** specify the marker as machine-emitted + provenance-checked; make the
missing/forged-marker case a push **FAIL** with a registered exception; and
rewrite §18's "no property was weakened" to "PR-time gating is intentionally
traded for build-coupling; the residual PR-time signal is the provenance-checked
HEAD-SHA marker, weaker than a CI gate and acknowledged as such."

### M2. Three execution contexts are correct but the onboarding/decision surface is too heavy — the predictable failure mode is people running the wrong one or disabling.

The taxonomy is genuinely good (buckets keyed on *where it runs*, two tags). But
the *operational* surface a contributor must hold in their head to use it
correctly is large, and complexity is the #1 driver of "disable it":

- **Three contexts** (push/PR static, build-time live, dispatch kind/ad-hoc) ×
- **Two `LIVE_MODE` values** (`mutating`/`readonly`) × **`verify` vs
  `apply-and-verify`** mapping ×
- **Three skip states** (not-applicable / phase-not-applied /
  precondition-absent-but-expected) ×
- **Two tags** (`real-irsa`, `expect-full`) + **cost tiers**
  (hermetic/singleton-coupled/slow) + **`singleton-coupled` tag** ×
- **SKIP_REGISTER** (reason/owner/expires, cap N=12, OI- cross-link for
  security) + **disable_all register** + **`LIVE_VERIFY=0`/`LIVE_SKIP`** +
  **FLAKE_LOG** + **quarantine lane** (with its own expiry).

That is ~8 orthogonal classification axes and ~5 disable/exception mechanisms.
A contributor adding one XRD must: write a fixture, add a registry entry (with
group/kind, cost tier, condition, singleton flag), ensure exactly one
skip-state classifier is wired (§4.4 meta-test reds them otherwise), and not
trip the wall-clock budget. **The plan asserts §2 "collapsed from 5-6 tiers"
but the *net* cognitive load went up, not down, once registers + tags + modes +
states are counted.**

The risk is not that the design is wrong — it is that the **first engineer who
hits a red they don't understand reaches for the biggest lever they can find.**
The plan has good *mechanical* anti-disable teeth (master switch RED unless
registered), but DevX disable is social, not mechanical: "I'll just run with
`action=verify` so it stays read-only and I don't deal with the live stuff," or
"I'll dispatch terraform-test without the live step." Both are available and
neither trips a register.

**Fix:** (1) Require a **one-page decision flowchart** as a P1 deliverable
("I am adding/changing X → which bucket, which tag, which registry fields") —
make it acceptance-gated like §15. (2) Add a **`tests/live/run.sh --explain`**
that, for the current context, prints exactly which checks will run, which will
skip and why, and which mode it's in — so a confused engineer's first move is
`--explain`, not `LIVE_VERIFY=0`. (3) Collapse the disable mechanisms: there
should be **one** durable disable path (SKIP_REGISTER), with `LIVE_VERIFY=0`/
`disable_all` being a thin alias that *writes a register entry*, so there are
not two parallel "off" doors with different teeth.

### M3. Per-resource live-test maintenance burden is acknowledged (one parametrized harness) but the harness is the single biggest unproven assumption after the P0 spike, and it is not itself spike-gated.

§5 leans hard on "**one parametrized harness**" generalizing the
`11_platform_secret_e2e.sh` shape so "adding an XRD is a fixture+registry entry,
not a new 142-line script" (§5(a), DevX M4). This is the right maintainability
goal and the make-or-break for whether per-resource live tests are sustainable.
But:

- The harness must parametrize over wildly heterogeneous kinds: IAM Role
  (global, no region), OIDC provider (global), ASM Secret (force-delete window,
  `k8-platform/` prefix, run-id substring), ACM cert (per-region limits,
  reuse strategy), S3, ConfigMap, ESO ExternalSecret (cross-controller). Each
  has a different "behaves" assertion, a different teardown, a different
  idempotency shape, a different quota. A single parametrized harness covering
  all of that is **plausible but unproven**, and it is the thing that determines
  whether P4 is 6 fixtures or 6 bespoke scripts that drift.
- The P0 spike (§12, §16) validates the **identity gate + v2 claim-verify port**
  but **does not validate the parametrized harness.** So the highest-burden,
  highest-drift component ships first proven only at P1 (skeleton) and lands for
  real at P4 with no earlier de-risking.

**Fix:** add a harness proof-of-concept to **P0 or early P1**: instantiate
**two maximally-different kinds** (e.g. ASM Secret with its force-delete window
+ a global IAM Role) through the single harness, proving the parametrization
seams (behaves-assertion, teardown, idempotency, quota tag) actually generalize.
If two kinds can't share the harness cleanly, the "fixture+registry entry, not a
new script" promise is false and P4's burden estimate is wrong — better to know
at P0.

### M4. The coverage deriver works (verified), but the plan's own example output and the real output differ in two ways the implementer will trip on — and "WARN-ONLY until fixture-test green" has no exit criterion.

I ran the exact extraction (§4.5) against all four committed compositions this
session. It works and produces the claimed kinds. **But:**

1. **Duplicates.** `platform-cluster.yaml` emits `Role` and
   `RolePolicyAttachment` multiple times (multiple Roles/attachments in the
   pipeline). The plan's "verified MR set" (§4.5) lists each kind once. The
   deriver needs an explicit **dedup/`unique`** step the plan never mentions;
   without it the fixture-test's "assert the exact set" will compare a deduped
   expectation against a duplicated actual and red. Minor to fix, but it's in
   the load-bearing fixture-test, so call it out.
2. **`apiVersion` carries the version, not just the group.** The extraction
   yields `iam.aws.m.upbound.io/v1beta1/Role`; the plan keys "on group/kind"
   and its §4.5 example shows `iam.aws.m.upbound.io/Role` (no version). So the
   deriver must **strip the `/vN...` segment** to get group/kind, or a provider
   version bump (`v1beta1`→`v1beta2`) silently changes every key and reds the
   whole manifest — a pure-maintenance red with no behavior change, which is
   precisely the "mis-firing gate that reds every PR" the plan calls *worse than
   the hand manifest* (§4.5). The version-stripping rule must be explicit and
   fixture-tested for version-independence.
3. **"WARN-ONLY until the fixture-test is green" has no owner and no exit
   criterion.** WARN-only is the correct ramp, but a warn-only gate that nobody
   is accountable for flipping to enforcing stays warn-only forever (the
   classic dead ramp). The plan must name **who/what flips it** and **when**
   (e.g. "enforcing in the same PR that lands a green fixture-test; a push lint
   asserts that once the fixture-test file exists and passes, the deriver's mode
   flag is `enforce`"). Otherwise the deriver is decorative.

**Fix:** specify dedup + version-stripping as fixture-tested deriver
requirements; add the version-independence fixture (same comps with a bumped
provider version must yield the same keys); give the warn→enforce ramp a
mechanical flip condition, not a vibe.

---

## MINOR

### m1. Flaky-test fatigue: the per-check≠bundle-red separation is the single best anti-fatigue control in the plan, but it depends on a classifier that must be near-perfect, and the plan never says what happens when the classifier itself is wrong.

§11/§8 do real work here: only `expect-full` miss or real `AccessDenied` reds
the bundle; THROTTLE/QUOTA/ROTATION are non-bundle-red. This is exactly what
stops "I saw red on my unrelated change → `LIVE_VERIFY=0`." Good. **But** the
classifier is the load-bearing piece, and a *misclassification* is the worst
case in both directions: a real `AccessDenied` mislabeled THROTTLE = a true blocker
goes non-bundle-red (the disease returns); a THROTTLE mislabeled `AccessDenied`
= fatigue returns. The plan asserts "a hard classifier separates Throttling from
AccessDenied" but gives no test that the classifier itself is correct on real
error strings, and no fallback for the unclassifiable error (default to
bundle-red, presumably — but say so). **Fix:** ship a classifier fixture-test
over a corpus of real AWS error strings, and state the default for an
unmatched error is **bundle-red** (fail-closed), with an `OI-` entry.

### m2. `verify ⇒ readonly` is asserted by a unit test (good) but the dangerous default is the *other* direction and isn't guarded.

§4.1 protects against `verify` accidentally mutating (NLBs/IAM/secrets) — a unit
test asserts `verify ⇒ readonly`. Good. But the symmetric DevX hazard is an
engineer running the bring-up and getting **fewer** checks than they think
because `LIVE_MODE` defaulted wrong, or because the build flow passed no mode.
The plan should assert the **default when no `LIVE_MODE` is passed** (fail-closed
to `readonly`? or refuse to run?) — an unset mode must not silently pick
`mutating` (surprise cost) *or* silently pick a no-op. State the unset-default
explicitly and unit-test it.

### m3. SKIP_REGISTER cap N=12 + 14-day grace are reasonable, but the cap's failure mode is a DevX cliff.

When the 13th legitimate skip is needed, the push reds with "retire one of
these" (§4.6). If all 12 are genuinely still needed, the engineer is stuck
between a red push and removing a still-needed skip — the pressure valve is to
bump N (gameable, the plan notes this for skip-counts but the *cap* itself is a
count). **Fix:** make raising N itself require a registered, expiring,
owner+reason entry (same shape as a skip), so the cap can flex under
accountability instead of being a hard wall that invites a quiet edit. The
intent — "annotate everything is mechanically impossible" — survives because the
cap-raise is auditable.

### m4. FLAKE_LOG as a committed file (§11, §14.6) will generate merge-conflict churn and PR-diff noise that engineers will route around.

The plan flags this as a known trade (§14.6) — credit for that. But the
practical DevX failure is specific: a committed append-only log touched by every
live run becomes a **merge-conflict magnet** on busy branches, and the path of
least resistance is `--no-verify` / editing the log to clear a conflict, which
corrupts the "N of last M" data the quarantine teeth depend on. **Fix:** if it
stays a committed file, make it **append-only with a structured one-line-per-run
format keyed by run-id** (conflicts resolve by union, mechanically), and add a
lint that rejects edits/deletions of existing lines (only appends allowed). Or
take the owner's offered alternative (external store) — but then the
"survives account rotation / reviewable diff" benefit is lost; name the trade.

### m5. The §15 acceptance checklist is excellent but conflates "mechanism tested" with "mechanism wired into the real bring-up" — the C1 gap hides inside checkbox 9.

Checkbox 9 ("The bring-up/build flow ... invokes `tests/live/run.sh` ...; a
static push lint asserts the suite is wired into the bring-up") will read as
satisfied by a lint that greps a file — but per C1 that file is
`terraform-test.yml` (or a nonexistent script). An implementer can make the lint
green by pointing it at *any* grep target, satisfying the checkbox while the
guarantee is hollow. **Fix:** the acceptance test for checkbox 9 must assert the
grep target is the **actual dispatched bring-up workflow/script** (the same one
AGENTS §5 / testing-guidelines §6 names), not just "a flow definition," and must
assert the invocation is gated on `action=apply-and-verify`. This ties the
checkbox to C1's fix.

---

## What the plan gets RIGHT (must not be lost)

- **simulate-as-FLOOR + drive-the-controller-as-completeness-signal** (§3.3).
  The single most important correctness idea in the document. The "narrow the
  wildcard, do not annotate it green" + capped annotations is exactly right.
- **`expect-full` from git, not self-report** (§4.3), and **fail-closed on a
  missing oracle** (no classification ⇒ treated as expect-full). This is the
  correct shape and directly kills blocker-#5-one-level-up.
- **Reaper age-floor ≥ slowest build + active-lease skip + structural deny-list
  account guard** (§8). The deny-list-not-allow-match framing survives account
  rotation; the allow-match version would brick on every rotation (AGENTS §8.1).
- **No probe pod / no new AssumeRole principal / no trust widening** (§3.1).
  Non-negotiable; the whole point.
- **Per-check red ≠ bundle red** (§11) — the best *social*-disable defense.

## The one thing that must not be lost

**The spine: drive the REAL provider controller under `source: IRSA`, with
all-skipped ⇒ RED and `expect-full` sourced from git — never a probe pod, never
skip-is-green.** Every pressure point below tempts the climb-down. But the
*specific* thing this round must not let slide is **C1's corollary**: the spine
is only real if the verifying step is *mechanically invoked by the actual
bring-up*. "On by default" via build-coupling is worth nothing if the build-flow
it couples to is a `workflow_dispatch` workflow nobody is forced to dispatch.
Make the invocation point real and mechanically enforced, or the overhaul ships
a more elaborate version of the exact green-that-proves-nothing it was built to
kill.
