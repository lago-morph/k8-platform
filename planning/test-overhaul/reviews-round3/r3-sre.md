# Round-3 Adversarial Review — SRE / Production-Operations Persona

**Target:** `planning/test-overhaul/FINAL-PLAN.md` (revised final, post-corrections #1 & #2)
**Reviewer lens:** skeptical SRE / production-ops — flakiness & false-fail rate,
isolation/cleanup leaks on a shared ephemeral billed account, wall-clock + $ per
bring-up, the ~20-min EKS, parallelism/rate-limits, blast radius against the live
hub, the reaper account-mutex/age-floor soundness, and — the round-3 focus —
whether the **build-coupling + dispatch-only recast** was applied soundly or
introduced a new contradiction/gap where nothing reliably runs.

**Method:** read the plan cold and fully (1001 lines), then grounded the new
load-bearing claim of correction #2 — that "the build" is decoupled from CI — against
the repo (`.github/workflows/terraform-test.yml`, `.github/scripts/compute-gates.sh`,
`tests/integration/run.sh`, `scripts/`, `crossplane/compositions/*`), and re-checked
the round-2 CRITICALs that this revision claims to have closed.

---

## What is now SOLID and must NOT be lost

The spine survived the recast intact and is correct:

1. **Drive-the-real-controller under `source: IRSA`, no probe SA, NON-GOAL of no new
   AssumeRole principal / no trust widening / no token-copy** (§3.1, §3.2). Verified:
   `crossplane/providerconfig/00-clusterproviderconfig.yaml` is `source: IRSA`; the
   trust subject is a single SA; a probe cannot assume it. This is the whole
   anti-bloat thesis. Do not let any future "just stand up a probe pod to read STS"
   climb-down back in.
2. **`simulate` demoted to a FLOOR; drive-the-controller is the real completeness
   signal** (§3.3). The `Resource:"*"` grounding is real (irsa.tf). Do not restore
   simulate to "the faithful proof" — that re-creates auto-012's exact blind spot
   with a green light.
3. **`all-skipped ⇒ RED` + master-switch-guarded + `expect-full`-from-GIT** (§4.2,
   §4.3, §4.4). The git-sourced oracle correctly closes the self-attested-oracle hole
   (blocker #5 one level up). The reserved `exit 3` for `expect-full` violations is a
   genuine improvement over the round-2 two-state model.
4. **Reaper remediate-and-RED only after bounded teardown poll + account-mutex +
   structural deny-list account guard + skip-active-lease-run-ids + age-floor ≥ 45 min**
   (§8). Every round-2 reaper finding (C2, M5, M6) is addressed soundly. The
   deny-list-not-allow-match framing is the durable fix for the rotating account.
5. **Per-check red ≠ bundle red; SLO into committed `FLAKE_LOG`; auto-quarantine**
   (§11). This is the mechanism that actually defends "on by default" against the
   social disable. Keep it.

The yq Pipeline-mode extraction (§4.5) is verified working against all four
compositions and reproduces the stated MR set. The exit-code contract, the
hermetic/singleton partition, and the secret-redaction prerequisite are all sound.

---

## CRITICAL

### C1. Correction #2's load-bearing premise is factually inverted: "the build" IS a CI `workflow_dispatch` workflow, not something decoupled from CI

This is the most important round-3 finding and it strikes the *new* material the
revision is built on. Correction #2 says, repeatedly and as the organizing principle
of §4.1/§4.2/§10/§18: *"GitHub Actions fires at PR/commit time, which is DECOUPLED
from when the cluster is actually brought up,"* so verification *"moves out of CI and
into the build."* Three strictly-separate contexts are then defined with *build-time*
as a distinct third thing from *push/PR CI* and *workflow_dispatch*.

**Grounded against the repo, this distinction does not exist:**

- `apply-and-verify` is **not** a build procedure outside CI. It is a literal
  `workflow_dispatch` **input value** to `.github/workflows/terraform-test.yml`
  (verified: `on: workflow_dispatch: inputs: action: options: [... apply-and-verify ...]`,
  lines 15-25; `compute-gates.sh` maps it to `mgmt_apply + mgmt_verify`). The cluster
  bring-up happens **inside a GitHub Actions runner**, in the `[management] apply` and
  `[management] e2e-verify` steps (terraform-test.yml:296-383).
- There is **no** local/agent bring-up script: `ls scripts/*apply* *bring* *build*`
  returns nothing. The only place a cluster is ever created is the Actions runner.
- Therefore the plan's own taxonomy collapses: "build-time = the full live suite,
  NEVER push/PR-triggered" and "`workflow_dispatch` = ad-hoc, never auto-triggered"
  are **the same execution context** — both are `terraform-test.yml`
  `workflow_dispatch` runs. The plan draws a three-way line where the repo has a
  two-way line (push/PR auto vs. `workflow_dispatch` manual), and `apply-and-verify`
  sits squarely on the `workflow_dispatch` side.

**Why this is worse than the round-2 C3 it replaces.** Round-2 C3 said "the trigger
needs a workflow edit the environment forbids." Correction #1 fixed the *forbids*
(jentic can edit workflows). But correction #2 then re-derived a *conceptual*
distinction — build ≠ CI — that is not true here. The "every bring-up" guarantee now
rests on the claim that there is a non-CI build flow to wire `tests/live/run.sh`
into. There isn't. The only thing to wire it into is **a step inside
`terraform-test.yml`** — i.e., exactly the CI workflow file the plan spends §4.1
insisting is the wrong place. The recast moved the language, not the mechanism.

**How it bites.** P1 says "land the build-flow wiring that makes the bring-up invoke
`tests/live/run.sh` (build-coupled, not CI)." The implementer goes looking for a
build flow that is not a workflow, finds only `terraform-test.yml`, and is now in
direct contradiction with the plan's own prohibition. Either (a) they add a
`[management] live-verify` step to `terraform-test.yml` — correct, deliverable via
jentic, but it *is* the CI workflow the plan said to avoid; or (b) they wait for a
mythical non-CI build flow and requirement #1 strands again. The plan's §12 ledger
row 1 ("the bring-up/build-flow wiring that invokes it (committed build flow; jentic
for any helper workflow)") papers exactly this gap with a phantom "committed build
flow."

**Fix.** Rewrite §4.1/§4.2/§10/§12/§18 to state the real topology:
*the bring-up IS `terraform-test.yml action=apply-and-verify`, a `workflow_dispatch`
run; verification is coupled by appending a `[management] live-verify` step (gated on
`mgmt_verify`, mutating only when `apply` also ran) that invokes
`tests/live/run.sh`.* The honest distinction is **not** "build vs CI" but
**"auto-on-push (static, no cluster) vs `workflow_dispatch`-with-`apply-and-verify`
(live suite, on by default within that dispatch)."** This is fully deliverable via
jentic and preserves every invariant — but the plan must stop asserting a
decoupling that the repo does not have, because an implementer who believes the
decoupling will build the wrong thing or strand the trigger.

### C2. "On by default" is now coupled to a `workflow_dispatch` action a human/agent must choose — the default lives one level too high to be a tested invariant

Given C1, requirement #1 ("live verification EVERY cluster bring-up, on by default")
reduces to: the live suite runs **iff** someone dispatches `terraform-test.yml` with
`action=apply-and-verify`. The plan's §4.2 "default-ON is a tested invariant"
protects two things statically: (a) the orchestrator's own config value is
`enabled`, and (b) a lint asserts the bring-up flow *invokes* `tests/live/run.sh`.
Both are real and good. **But neither defends the actual gap:** nothing forces a
bring-up to go through `apply-and-verify` rather than plain `apply`. `compute-gates.sh`
shows `apply` (no verify) is a first-class action. An agent that dispatches
`action=apply` (faster, common) brings up the cluster with **zero** live
verification, and **no invariant in the plan fires** — the suite was never invoked,
so "all-skipped ⇒ RED" never runs, and the static "is-it-wired" lint is green because
the wiring exists in the `verify` step that didn't execute.

This is the round-3 version of the persona's core worry — *does on-by-default survive*
— and the answer is: it survives only if every operator always picks the slower
action. That is precisely the "on by default" that quietly becomes "on when someone
remembers."

**Fix.** Make the coupling structural at the gate layer, not advisory:
- In `terraform-test.yml`, gate the live-verify step on `mgmt_apply` **as well as**
  `mgmt_verify`, so that **any apply** (whether `apply` or `apply-and-verify`)
  triggers live verification. I.e., the invariant becomes "you cannot apply the
  management cluster without the live suite running." A bare `apply` that skips verify
  is the hole; close it in `compute-gates.sh` by making `mgmt_apply ⇒ mgmt_verify`
  for the management phase (or by a dedicated `live_verify` gate keyed on apply).
- Add a unit test (push-time, no cluster) asserting `compute-gates.sh management apply`
  yields `mgmt_verify=true` — so "apply without verify" becomes a red diff. This is
  the only thing that makes "every bring-up" mechanically true rather than
  convention.

Without this, §4.2's two invariants guard the *wiring* but not the *triggering*, and
requirement #1 is satisfied on paper while a one-word action choice bypasses it.

---

## MAJOR

### M1. The spoke "build-coupled" trigger has no build to couple to at all — it is a hub-side watcher with no committed host process

§10 says the spoke trigger is "part of the bring-up/reconciliation path, not a CI
job," a "hub-side watch/invoke script" that watches `XPlatformCluster`/`XSpokeAccess`
for `Ready=True` and invokes `tests/live/run.sh`. §12 row 2 calls the other half
"wiring the script into the reconciliation/bring-up path" and marks it **YES**.

Grounded: there is **no long-running hub-side process** in this repo that could host a
watcher. The hub runs ArgoCD/Crossplane/ESO/Kyverno; nothing runs a custom
"watch-XR-then-invoke-tests/live" loop, and the plan commits nothing to create one
(no Deployment, no CronJob, no controller). A "hub-side watch script" that nobody runs
is not coupled to anything. The only actual trigger surfaces available are again the
two CI ones: a `workflow_dispatch` run, or a scheduled/polled CI job. So the spoke
trigger has the same C1 problem in sharper form: the "reconciliation path" it claims
to hook is a GitOps controller loop the plan cannot inject a test call into without
either (a) a new in-cluster controller (large undelivered scope), or (b) a polling CI
job (which is the CI the plan disclaims, and which would need to reach the spoke
kube-API — the unresolved §14.2 dependency anyway).

**Fix.** State the real options and pick one: either (a) the spoke verification is a
**`workflow_dispatch`/scheduled CI job** that polls hub XR status and runs the spoke
after-the-fact suite (honest, deliverable, but it IS CI and depends on §14.2 spoke
kube-API access), or (b) it is a step appended to the same `apply-and-verify` run that
provisions the spoke XR, blocking on `kubectl wait --for=condition=Ready` on the hub
object (deliverable in CI, bounded). Drop the "hub-side watcher wired into the
reconciliation path" framing — it implies a daemon the plan does not build. §12 row 2
should be **CONDITIONAL**, not YES.

### M2. The HEAD-SHA "live-evidence marker" backstop is a new green-without-running hole and a churn/forgery surface

§4.3/§4.1/§15 introduce a push/PR static backstop: a committed "live-evidence marker
per HEAD SHA" that records a green build-suite result for the deployed SHA; a missing
marker is a push WARN/FAIL. This is new in the finalizer/correction-#2 layer and it
quietly re-opens the exact disease the overhaul exists to kill:

- **It is self-attested.** The marker is written by whoever ran the suite (or claims
  to have). Nothing in the plan ties the marker's authenticity to an unforgeable CI
  artifact (a run ID + conclusion fetched from the Actions API). A developer who wants
  green can commit a marker. "Manifest says X" becomes "marker says the suite was
  green" — the same gap, one level up, which §4.3 itself warns against for
  `expect-full`.
- **On a rotated account the marker is stale by construction.** §8.1 says the account
  rotates and account-derived state is non-durable. A green marker for the prior
  account's cluster/SHA tells you nothing about the current account, but the push
  check can't tell the difference — it only checks "a marker exists for this SHA."
- **Churn.** A committed per-SHA marker reds or warns every PR until someone runs the
  live suite and commits the marker, on a suite whose live runs are
  `workflow_dispatch`-gated and slow. This is the "calendar event reds unrelated PRs"
  failure the plan elsewhere takes pains to avoid (§4.6 grace window).

**Fix.** Either drop the marker entirely (the plan already, correctly, says the
PRIMARY guarantee is build-coupling, not the PR check — so the backstop earns little
and risks much), or make it **unforgeable and freshness-checked**: the marker records
a GitHub Actions **run ID** for `terraform-test.yml action=apply-and-verify`, and the
push check calls the Actions API (via the §6.7 verifier pattern already in the repo:
`chainsaw-verify.yml`) to confirm that run exists, is `conclusion=success`, ran
against this SHA, and is newer than the current account's bootstrap. A committed
free-text "green marker" with no API cross-check is strictly worse than no backstop.

### M3. Wall-clock budget omits the EKS-bring-up serialization cost under the account-mutex + the 18×10s pod-wait already in the verify step

§6 sets a budget of "< 8 min over bare bring-up" and gives a worked floor (reaper
~30s + hermetic ~2-3min + idempotency ~30s + teardown poll ~2min). Two omissions make
this budget unenforceable in practice:

1. **The account-mutex (§8) serializes live runs account-wide.** Under AGENTS §6.6
   parallel stacked-PR throughput mode, a second `apply-and-verify` blocks on the
   lease for up to the lease TTL (which §8 sets `< reaper age-floor`, i.e. up to ~45
   min). The "added wall-clock" a developer experiences includes **lease wait**, not
   just the bundle's own work. The budget measures the wrong envelope: an 8-min bundle
   behind a 40-min lease wait is a 48-min experience, and the developer reaches for
   `LIVE_VERIFY=0`. The budget gate must either account for lease-wait or the plan
   must state the mutex makes concurrent bring-ups serial-by-design and size the
   expectation accordingly.
2. **The existing verify step already burns up to 3 min** in a pod-readiness retry
   loop (`for i in $(seq 1 18); do ... sleep 10`, terraform-test.yml:351-361). The
   live suite is *appended* to this. The "< 8 min over bare bring-up" budget must be
   measured over the *current* verify step, which already includes minutes of polling
   — otherwise the first hermetic-create check that "blows it" reds a diff for crossing
   a line the baseline measurement never accounted for.

**Fix.** Define the budget envelope explicitly as "added wall-clock **inside the
`apply-and-verify` run, excluding account-mutex lease wait**," and separately bound
lease-wait as its own operational SLO with its own consequence (serial-by-design,
documented). Re-baseline the budget against the existing verify step's runtime.

### M4. Idempotency double-apply (§5) collides with the account-mutex hold time and the per-bring-up wall-clock on every single bring-up

§5 makes idempotency a *standing per-test assertion* ("apply the same XR twice ⇒
exactly one cloud resource"). Combined with C2's fix (every apply runs the live
suite) and §8's account-mutex, every management bring-up now: acquires the
account-lease, runs the reaper sweep (RGT + describe + delete API calls), creates the
hermetic set, double-applies each for idempotency, polls teardown to empty, releases
the lease. On a shared ephemeral account this is real API-call volume and real lease
hold-time on **every** bring-up, multiplying the §6 throttle risk the plan itself
flags. The double-apply specifically doubles the create-path API calls that are the
most throttle-prone (IAM/STS).

**Fix.** Make the standing idempotency assertion **sampled, not every-run** (e.g. one
hermetic kind per run, rotated), or gate it behind a `LIVE_IDEMPOTENCY=1` that the
nightly/dispatch lane sets but the per-bring-up default does not. Keep it standing as
a *capability*; do not pay its full cost on the latency-sensitive every-bring-up path.

### M5. The `extra:` stale-allowlist "FAIL after N runs with no matching resource" needs durable cross-run state the plan does not site

§4.5's RGT-diff side-effect oracle fails if an `extra:` entry has no matching real
resource "for N runs." Counting "N runs" requires durable per-entry run-count state
that survives account rotation and parallel runs. The plan sites `FLAKE_LOG` and
`SKIP_REGISTER` as committed files but does not say where the `extra:`-staleness
counter lives, and a naive in-CI counter resets every account. Without a durable home
this check either never fires (counter always resets → stale entries live forever) or
false-fails (counter shared across parallel runs miscounts).

**Fix.** Either site the staleness counter in the same committed-file data plane as
`FLAKE_LOG` (a per-entry last-seen SHA/date, "fail if not seen in the last N committed
runs"), or downgrade the stale-`extra:` check to a periodic dispatch-lane audit rather
than a per-push gate. State the data plane explicitly.

---

## MINOR

### m1. The deriver keys on `group/version/kind`, not the claimed `group/kind`
The verified yq expression emits `iam.aws.m.upbound.io/v1beta1/Role` (includes the
`v1beta1` version segment), but §4.5 says "key on group/kind, never bare kind." A
provider version bump (`v1beta1`→`v1beta2`) would silently break every registry match
and red the coverage gate for a non-bug. Strip the version: key on
`(group, kind)` derived from `apiVersion` minus its version suffix. One-line fix to
the expression; flag it so the implementer doesn't ship the version-coupled key.

### m2. `ScheduledForDeletion` ASM force-delete is gated on run-id substring — but the controller tags ASM secrets with `k8-platform/<XR-uid>`, not the run-id
§5/§8 require force-delete gated on the **run-id** substring (good, per round-2 m3).
But §8 also documents (correctly) that the Composition tags ASM secrets
`k8-platform/<XR-uid>`, "never the test's prefix." So the run-id is on the **XR name**
the test controls, not on the **ASM secret tag** the controller applies. The
force-delete gate must therefore resolve XR-name(run-id) → composed-secret(XR-uid) →
ASM ARN before force-deleting, not grep ASM tags for the run-id (which won't be
there). The plan's two statements are individually right but the join between them is
unstated and an implementer could grep the wrong field. Spell out the resolution path.

### m3. "Lease TTL < reaper age-floor" + "reaper skips active-lease run-ids" can still orphan a resumed run whose lease expired during sandbox suspension
§8 sets lease TTL `< 45 min` so a dead holder self-expires, and the reaper skips
run-ids in the active lease. But AGENTS §6.20 documents the sandbox suspends mid-wait
for long periods. A run suspended > TTL loses its lease (expired), drops out of the
active-lease set, and its in-flight resources (older than the 45-min floor by the time
it resumes) become reapable by a sibling — the exact friendly-fire §8 closes for the
non-suspended case. The age-floor protects ≤45-min resources; a suspended-then-resumed
run breaks both guards simultaneously.

**Fix.** On resume (§6.20 already mandates a status re-check), the run must
**re-acquire/renew its lease before trusting any of its prior resources**, and the
reaper's age-floor should key off the resource's own creation+lease-renewal recency,
not wall-age alone. At minimum, name this interaction as a residual risk; the plan
currently treats lease-expiry and age-floor as independent when sandbox-suspend
couples them.

### m4. False-fail SLO denominator excludes lease-contention reds
§11 defines false-fail = `reds ∈ {ENVIRONMENTAL-ROTATION, THROTTLE, QUOTA}` ÷ all
reds. A bring-up that reds because it **timed out waiting for the account-mutex**
(M3) is none of those three categories, so it counts as a *true* red — inflating the
apparent true-fail rate and, worse, presenting a pure-infrastructure-contention
failure to the developer as a real defect. Add a `LEASE-CONTENTION` (or
`MUTEX-TIMEOUT`) triage category to the §8 classifier and the §11 numerator, or the
SLO will systematically misclassify the most common operational red under parallel
mode.

---

## Verdict on the corrections

- **Correction #1 (workflows editable via jentic):** applied soundly. The
  push-static / dispatch-only split is consistent and deliverable.
- **Correction #2 (build-coupling, dispatch-only):** applied **unsoundly at the
  conceptual level (C1)**. The recast invented a "build ≠ CI" distinction the repo
  does not have — `apply-and-verify` is itself a `workflow_dispatch` CI run. The
  intent (couple verification to the apply, keep cluster work off push) is right and
  achievable; the *framing* is wrong and will mislead implementation. The fix is
  framing + one structural gate change (C2), not a redesign. **The round-2
  resolutions (identity gate, simulate-floor, git-sourced expect-full, reaper
  hardening, per-check≠bundle) all survived intact** — the recast did not regress
  them. The new damage is concentrated in the trigger story (C1, C2, M1) and the new
  HEAD-SHA marker (M2).

*Bottom line:* the spine is solid and the round-2 critical fixes held. The
correction-#2 recast is the new weak point: it describes a non-CI "build" that does
not exist, leaving "every bring-up, on by default" resting on an operator choosing
`apply-and-verify` over `apply` with no invariant enforcing it. Fix C1 (tell the
truth about the topology), C2 (gate live-verify on any management apply, unit-tested),
and M1 (the spoke trigger has no daemon to host it) before P1 lands the wiring.
