# SRE / production-ops adversarial review — PLAN-B-k8s-testing-expert.md

**Reviewer persona:** skeptical SRE fixated on real-cloud latency, flakiness,
isolation/cleanup leaks, wall-clock + $/run, the 20-min EKS create, concurrency
& API-rate limits, blast radius against the LIVE cluster, and whether "on by
default" actually survives a long, occasionally-red suite.

**Verdict up front:** the plan's *taxonomy* and its central thesis (run L4 under
the restricted IRSA role; demote static lints) are correct and must survive into
synthesis. But the plan is dangerously optimistic about three things that decide
whether it survives reality: (1) it runs live mutating tests **against the same
hub cluster developers depend on**, with no isolation story for the cluster
itself; (2) its "on by default, can't silently regress" mechanism is built on a
push-time verifier the plan *itself admits it cannot create* (workflow-scope
gap, OI-2026-06-05-6); (3) it under-budgets wall-clock, eventual-consistency
flake, and leak-sweep correctness on an ephemeral shared account. Details below,
ranked.

---

## CRITICAL findings

### C1. Blast radius: L3/L4 mutate the LIVE hub that the build/dev workflow depends on. (§3.1, §3.3, §4.1, §8.3)
The plan wires `tests/live/run.sh` (L3+L4+L5) into the **end of every
`apply-and-verify`** and says it "runs against whatever cluster the current
kubeconfig/AWS creds point at." That cluster is the **management hub** — the one
running ArgoCD, Crossplane, ESO, Kyverno, that every spoke build depends on. L3
applies real `Application`s and runs `auth can-i`; L4 *creates real IAM roles,
ASM secrets, Route53 records, IngressClasses, and Crossplane XRs* on that hub,
under the real controller. §5.2 even applies a claim that **deliberately fails
with AccessDenied** and §5.3 deliberately stands up Keycloak **with its DB
absent**.

How it bites THIS system:
- A negative test that leaves a `Synced=False/ReconcileError` MR on the hub, or a
  half-created IAM role, pollutes the *real* Crossplane reconcile queue and the
  *real* ArgoCD app list that the next phase/spoke build reads. Crossplane will
  keep retrying the broken MR; ArgoCD will show the probe `Application`
  OutOfSync/Degraded — indistinguishable from a real platform fault to the next
  session, which per §8.4 assumes nothing and re-diagnoses.
- An L4 IngressClass / ext-dns probe creates a real Route53 record and possibly a
  real NLB/ELB on the shared account. A cleanup miss = a dangling LB billing by
  the hour (the exact "orphaned cloud resources cost money" fear).
- Running this **at the end of every apply-and-verify** means the hub gets
  mutated *on every bring-up of phase 1* — including bring-ups whose purpose was
  to give a developer a working hub. The suite degrades the thing it just built.

Fix: the plan needs an explicit **blast-radius / namespace-isolation contract**
for live tests, not just a per-run-ID *name* prefix:
- All L4 mutations confined to a dedicated, labeled throwaway namespace
  (`live-verify-<run-id>`) that is `kubectl delete ns` at trap time — a namespace
  delete is the one cleanup that reliably garbage-collects the k8s side even if
  the per-resource deletes fail. The plan's prefix scheme (§6) only covers
  *cloud* resources via ASM-style enumeration; it has no k8s-side bulk-delete.
- Negative-claim tests (§5.2 AccessDenied, §5.3 DB-absent Keycloak) must run in
  that throwaway namespace AND assert the MR/pod is **torn down**, with a final
  assertion that the hub's *real* Crossplane queue and ArgoCD app list are clean
  (no probe-prefixed objects, no probe MRs in ReconcileError) before the step
  exits green. Add this as an explicit post-condition in §6's leak sweep.
- State, loudly, that live-verify must **never** run against a hub that is also
  mid-spoke-build (concurrency interlock — see C4).

### C2. The "can't silently regress" enforcement depends on a workflow the plan cannot create. (§3.2.3, §8.4, §8 preamble)
The load-bearing anti-regression control is §8.4's `live-verify` *verifier
workflow* that "fails the PR check if the live-verify skip count rose vs main
without a SKIP_REGISTER diff." But §8's own preamble concedes this session
**cannot create/edit `.github/workflows/*`** (OI-2026-06-05-6 — confirmed in
`docs/open-issues.md:284`; the OAuth token lacks `workflow` scope, and
`create_or_update_file` 404s on that path). The plan hand-waves this as "authored
as runbook YAML + applied via the operator / ext-github Contents-PUT."

How it bites: until *someone with workflow scope* lands that verifier on main,
**there is no push-time gate** — exactly the "disabled/all-skipped reads green"
failure the user explicitly forbade (requirement 2). The plan ships PR-1's
mechanism (loud skips, SKIP_REGISTER, the L0 register test) but the actual
*enforcement* that a skip-count increase fails a PR is stranded behind an
un-committable file. A reviewer merging PR-1..PR-6 would believe regression is
gated when it is not.

Fix:
- Make the regression gate **not** depend on a new workflow. Put the skip-count
  comparison + SKIP_REGISTER-diff check **inside `tests/unit/run.sh`** (a
  committable script already gated by the existing `unit-tests.yml`, per
  AGENTS.md §6.16). The script computes skip-count-on-HEAD vs a committed
  `tests/live/SKIP_BASELINE` and fails if it rose without a register diff. This
  rides the push-time workflow that *already exists*, removing the workflow-scope
  dependency entirely.
- Until the §8.3 `apply-and-verify` wiring (also a workflow edit!) lands, the
  plan must state that "on by default at bring-up" is **not yet true** and gate
  that claim behind the operator landing the edit. Otherwise PR-2 reports
  "wired" while `terraform-test.yml` still calls the thin e2e step.

### C3. "On by default at every bring-up" collides with the §6.7 heavy-workflow / cost discipline and will get switched off in practice. (§3.1, §8.3, §4.1)
The user's #1 requirement is live verify on *every* bring-up. But AGENTS.md §6.7
mandates heavy workflows be `workflow_dispatch`-only and *not* run on every push,
precisely because a long, occasionally-red suite burns runner minutes and gets
babysat. L4 create-and-verify (IAM + ESO + Route53 + ACM + AppProject sync,
each with eventual-consistency polls) bolted onto the **end of every
apply-and-verify** adds multi-minute wall-clock and real $ to an operation that
already takes ~20 min. The realistic outcome the persona has seen: the first time
this suite is red for an environmental reason during a bring-up the dev needed,
someone sets `LIVE_VERIFY=0` "just for now" — and now the green/red signal is a
lie.

How it bites THIS system: §8.3 makes the bring-up the gate. If live-verify is
flaky (C5) or slow, the pressure to disable it is highest *exactly when the
cluster is most needed*. The SKIP_REGISTER (C2) is the intended guard, but a
person under pressure sets the env var, not the register — and the env-var path
has no expiry/owner/review.

Fix:
- Split the contract the plan blurs: **L5 after-the-fact** (cheap reads, no
  mutation) genuinely *can* run on every bring-up and should. **L4
  create-and-verify** (mutating, slow, costs $) should run on bring-up **but its
  failure must be diagnosable and non-blocking-to-the-cluster-handover** — i.e.
  the cluster is reported "up"; live-verify is a *separate* gate whose red is
  loud but does not make the operator believe the hub itself is broken. The plan
  currently fuses them.
- Make the `LIVE_VERIFY=0` env path **route through the same fail-closed logic as
  the register**: if `LIVE_VERIFY=0` is set in CI without a SKIP_REGISTER entry,
  the summary banner is RED, not green (the plan only enforces register
  discipline for *per-check* skips in §3.2, not for the master kill-switch). The
  master switch is the most likely thing to be abused and is currently the least
  guarded.

### C4. No concurrency/interlock model — parallel CI runs collide on the shared hub and the ephemeral account. (§6, §3.1)
The plan's isolation story is the per-run-ID **name** prefix (good for ASM, IAM,
Route53 *names*). It does not address:
- Two `apply-and-verify` runs (or a bring-up + a dispatched §8.5 hub→spoke job)
  hitting the **same hub** concurrently. Crossplane has one reconcile queue; two
  live suites applying/deleting XRs and IngressClasses interleave. `kubectl auth
  can-i` and AppProject permit/deny are global cluster state — run-ID prefixing
  doesn't isolate them.
- AWS API **rate limits / throttling** on the shared account when N runs each do
  `Describe*` loops + IAM creates. The plan *explicitly declares rate-limiting
  out of scope* (§12) — but it's not optional when the design is "poll-until-true
  against real AWS on every bring-up under a shared ephemeral account." That's a
  self-inflicted throttle.

How it bites: flaky AccessDenied/Throttling errors that look exactly like the
real IRSA-permission failures the suite is built to detect — poisoning the
signal. A concurrent ns/IngressClass collision produces a red that isn't a real
regression.

Fix: add a §6 subsection: (a) a **cluster-level mutex** for the live suite (e.g.
a lease/configmap lock on the hub, or GH Actions `concurrency:` group keyed on
the cluster) so only one live suite mutates a given hub at a time; (b) state the
**expected concurrency** (the plan says "single spoke is the contract," §12 —
then say the same for live-verify: serialized per hub); (c) replace "rate-limit
out of scope" with a concrete **bounded-concurrency + jittered-backoff-on-
Throttling** rule for the `Describe*`/IAM calls, distinguishing
`ThrottlingException` (retry) from `AccessDenied` (real failure, fail red).

---

## MAJOR findings

### M1. Eventual-consistency "consistency budget" is named but not bounded — this is the flake engine. (§6 bullet 4, §4.1)
The plan correctly refuses blind retries and proposes "bounded poll-until-true
with an explicit consistency budget, documented per check." Good instinct — but
no budgets are given, and the resources it polls (Route53 record propagation, IAM
role/trust-policy propagation, ACM issuance, ext-dns reconcile loop) have
*wildly* different real-world latencies (IAM eventual consistency can exceed
60s; ext-dns sync interval is a tunable minute-ish; ACM DNS-validated issuance is
minutes). Without per-check budgets, every one of these is a future flaky red.

Fix: §4.1 / §6 must ship a **per-check timeout table** (the COST_TIERS.yaml is
the natural home — add a `consistency_budget` field per check) with budgets
derived from observed latency, and the L0 mapping test (§4.3) must assert every
check has one. Tie a budget breach to an `OI-` entry (§6.18), not a retry.

### M2. The restricted-IRSA assumption mechanism — the central fix — is an open question deferred to author time. (§11 bullet 1, §12 last bullet, §7 "the pattern")
The plan's whole thesis is "run L4 under the restricted Crossplane IRSA role."
Then §11/§12 admit they don't know *how*: maybe a probe SA can assume it, maybe
not, "pick at PR-3." I confirmed `terraform/management/irsa.tf` defines the
roles, but if the Crossplane controller's role trust policy only trusts the
*controller's* SA, a probe pod cannot `AssumeRoleWithWebIdentity` it, and the
plan's fallback ("apply the claim and let the real controller act") is **not the
same test** — it can't do the §5.2 *direct* AssumeRole negative, and it muddies
"did the role lack the permission" vs "did the controller mis-reconcile."

How it bites: the single most important change (PR-3) may be undeliverable as
specified, and the fallback silently weakens the IRSA-negative coverage that
catches blockers #2–#5,#8 — the exact class that motivated the whole overhaul.

Fix: resolve the mechanism *in the plan*, not at author time. Either (a) provision
a dedicated probe SA whose name is added to the controller role's trust
`sub` condition (a one-line TF change the plan should call for), or (b) accept
the controller-path fallback but then **keep the direct-AssumeRole negative as
its own L4 check using a purpose-built probe role** (cheap to create/delete), so
the negative isn't lost. State which, and acknowledge it's a TF change with its
own test.

### M3. Leak-sweep correctness is asserted, not proven — and the existing ASM sweep needed a UID fix. (§6 bullets 1–2, 5)
The plan reuses the chainsaw cleanup pattern and says a "leaked-resource sweep
(enumerate by run-id prefix) runs at suite end and reports leaks." But:
- I read `tests/chainsaw/run.sh`: its own comment (lines ~76–78) notes the
  provider tags ASM secrets `k8-platform/<XR-uid>` — which **never matched the
  old `${ASM_RUN_PREFIX}/`** scheme. The prefix-enumeration sweep has *already
  been wrong once* for exactly the resource the plan wants to reuse it for. IAM
  roles, Route53 records, and ELBs created by Crossplane/ext-dns will likewise be
  named/tagged by the **controller's** convention (XR uid), not the test's
  run-id prefix. The sweep will silently miss them.
- "Reports leaks" ≠ "deletes leaks." On an ephemeral account a *reported* leak
  that nobody actions still bills until rotation. The plan needs the sweep to
  **fail the run** on a detected leak (visible, per §6.24 don't-weaken-checks
  ethos), not just print it.

Fix: the sweep must enumerate by the **tag the controller actually applies**
(discover it, don't assume the test prefix), cover IAM/Route53/ELB not just ASM,
and a non-empty leak set must turn the summary RED. Cite the chainsaw UID-vs-
prefix lesson explicitly so PR-3 doesn't re-make it.

### M4. The §8.5 hub→spoke e2e (6 of 8 blockers) needs a spoke that takes ~20 min — and the plan never says who builds it or when. (§8.5, §4.2, §11 last bullet)
§8.5 runs `curl https://hello.platform.<domain>` and "Keycloak Ready against
RDS" against "a live hub with a built spoke." But spoke EKS is L5/~20 min and the
plan explicitly does *not* create it in the suite (§4.2). So this job's
precondition (a built spoke) is unowned: it either (a) silently auto-skips on
every run because no spoke exists (and per requirement 2, "all-skipped must not
read green" — but skip-guard auto-skips are *designed* to be green per §3.3,
contradiction), or (b) assumes a human built a spoke first, in which case it's
not coupled to any change (violating requirement 6 "coupled to the change, not
nightly").

Fix: the plan must pick a lane: either the §8.5 job is part of a **spoke
bring-up** pipeline (coupled to the spoke build that *is* the change), or it's an
explicitly-scheduled post-spoke verifier with an `OI`/register-tracked status —
and the auto-skip-when-no-spoke case must be distinguished from "passed" in the
banner (a third state: `SKIPPED-PRECONDITION-ABSENT`, counted separately, so a
run where the *only* coverage is skipped never reads green — directly the
requirement-2 trap §3.3 currently fails to close).

### M5. Account-rotation mid-suite (§6 last bullet) only guards the *preamble*. (§6, §8.2)
The plan runs `whereami.sh` + `get-caller-identity` as a **preamble** guard. But
the suite's L4 create-and-verify + L5 reads can run for several minutes; the
ephemeral account/creds can rotate or the STS session expire *mid-run* (AGENTS.md
§8.2 catalogs `InvalidClientTokenId` surfacing mid-session). A rotation after the
preamble passes produces AccessDenied on a *create* that looks identical to the
IRSA-permission negative the suite is asserting — false green or confusing red.

Fix: classify mid-run STS/credential errors centrally (a shared helper) as
`ENVIRONMENTAL-ROTATION` → stop with the §8.2 rotation message, distinct from
`AccessDenied-on-restricted-role` → the real signal. The plan's §6 negative-test
logic *depends* on telling these apart and currently can't.

### M6. EKS authenticationMode is checked at L5 (describe-cluster), but the failure it caused (blocker #1) is that AccessEntries can't be created — verify the *effect*, not just the *mode*. (§7 row 1, §4.2)
§7 says L5 asserts `accessConfig.authenticationMode includes API` and "AccessEntry
for the hub app-controller role exists." Good — but blocker #1's real damage was
the hub couldn't manage the spoke. Asserting the mode + entry exists is
necessary but the *behavioral* proof is "the hub app-controller can actually
`kubectl get ns` on the spoke." That's the L5→behavior gap: the plan verifies
configuration presence, which is one notch above the static lint it's replacing.

Fix: add a behavioral L5 check that the hub identity can authenticate to the
spoke API (through CI, since kube-API is private-CA per §6.26) — the difference
between "AccessEntry row exists" and "access actually works" is exactly the
manifest-says-X vs X-works gap the plan's own §0 thesis indicts.

---

## MINOR findings

### m1. Helm-precondition test for "Keycloak won't start without DB" may assert a contract Helm can't enforce. (§5.3)
§5.3 L0/L2 asserts the chart "wires an init-container / readiness probe /
dependsOn that blocks startup on DB reachability." A readiness probe failing
keeps a pod un-Ready but **running** (not the "must not start" the requirement
says); an init-container is the only thing that truly blocks *start*. The plan
conflates "not Ready" with "not started." Pick the init-container contract for
the hard-precondition and reserve readiness for the soft case; assert the right
one so the L4 live check (`Pending`/`CrashLoop`) matches the L0 claim.

### m2. `kube-diagnose.yml` reliance for L5 kube reads (§4.2, §11 bullet 3) is itself a workflow the session can't edit. Same OI-2026-06-05-6 trap as C2 — if L5 needs to *extend* `kube-diagnose.yml`, that's blocked. Flag it in §11 as a dependency on operator action, not an assumption.

### m3. Cost guard is `aws ce`-based (§6 bullet 5) — Cost Explorer data lags 24h+ and is useless for a per-run, per-bring-up budget check on an ephemeral account. Replace with a **tag-scan count** (resources tagged with the run-id at suite end) as the real-time guard; keep `aws ce` only as an out-of-band monthly sanity, not a per-run gate.

### m4. "Demote static lints to pre-flight" (§0, §2 L0) risks losing the fast, cheap signal that catches the IAM-action-presence class *before* a 20-min apply. The plan keeps them (§7 says L0 lints stay as stopgaps) but the framing ("never the test") could be read as deprioritizing the cheapest catch. Keep the L0 IAM-action / dual-SA / subnet-tag lints as **blocking** push-time gates — they're the only layer that fails in seconds without touching the account.

### m5. PR sequencing (§9) puts the restricted-IRSA harness (PR-3, the central fix) third, behind two PRs of scaffolding. Given M2's unresolved mechanism, PR-3 is the highest-risk PR and should have a spike/proof-of-assumption *before* PR-1 ships, so the whole stack isn't built on an assumption that fails at PR-3.

---

## What the plan got RIGHT — synthesis MUST preserve these

1. **The core thesis: run create-and-verify under the restricted Crossplane IRSA
   role, not admin creds.** This is the single change that catches blockers
   #2–#5,#8 and the one thing the current kind/admin chainsaw *masks*. (§0, §7
   closing.) Non-negotiable keeper.
2. **The six-layer taxonomy organized by *when the contract fails*, with L4-vs-L5
   decided by cost.** Slow EKS/RDS = after-the-fact (L5), everything cheap =
   instantiate-and-verify (L4). Matches user requirements 3 & 4 precisely. (§2,
   §4.)
3. **Negative + precondition tests as first-class** — the IRSA-permission
   negative (claim → ReconcileError/AccessDenied instead of silent-never), the
   IRSA-subject-mismatch negative, the XRD required-field admission reject, and
   Keycloak-without-DB. This is what static lint can never do. (§5.) Keep.
4. **The blocker→layer coverage matrix (§7)** — explicit traceability from each
   of the 8 auto-012 blockers to the layer that now catches it. Preserve this as
   the acceptance criterion for the overhaul.
5. **The discipline scaffold *concept*: loud skips + an expiring/owned
   SKIP_REGISTER + a runtime-skip-not-in-register failure + COST_TIERS mapping
   test.** The *mechanism* is right (mirrors the kubeconform-skip + open-issues
   discipline); only its *enforcement vehicle* needs moving off the
   un-committable workflow (C2).
6. **Reuse, don't rebuild:** `crossplane-claim-verify` made mandatory,
   `wait-for-claim.sh`, `irsa_trust_validator.py --all` as a hard `0 MISMATCH`
   gate, the chainsaw run-ID + cleanup-trap pattern, no-`|| true` cleanup
   (§6.19). Leaning on proven assets is the right call.
7. **No blind retries; eventual consistency handled as a bounded budget, flakes
   go to the open-issues register.** The *policy* is exactly right (§6) — it just
   needs the concrete budgets (M1).

---

## Bottom line for synthesis
Keep the thesis, the taxonomy, the negative tests, and the blocker matrix
verbatim. Before any of it is buildable, the synthesis MUST resolve: the
**blast-radius/namespace isolation** of mutating the live hub (C1), move the
**regression gate off the un-creatable workflow** into the existing push-time
script (C2), **decouple cluster-up from live-verify-red** so "on by default"
survives a flaky run (C3), add a **per-hub concurrency mutex + throttling
policy** (C4), and **resolve the restricted-IRSA assume mechanism in the plan**
rather than deferring it to the highest-risk PR (M2). Everything else is
hardening.
