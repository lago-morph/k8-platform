# Adversarial Review — PLAN-A (Claude lead)
## Lens: developer-experience & maintainability adversary

**Question I keep asking:** Will engineers actually run and maintain this, or
quietly disable it within three sessions? Every finding below is scored on that
axis: feedback-loop speed, flake fatigue, fixture/coverage-manifest maintenance
burden, taxonomy overhead, onboarding cost, and whether "coupled to the change"
has real teeth or just relies on goodwill.

I read the plan in full (`planning/test-overhaul/plans/PLAN-A-claude-lead.md`,
all 142 lines) and grounded the findings against the live repo: `tests/integration/`
(13 scripts incl. `08_irsa_sts_round_trip.sh`, `06_crossplane_xrd_claim.sh`,
`11_platform_secret_e2e.sh`), `tests/unit/` (60+ tests incl.
`test_iam_required_actions.sh`), `scripts/wait-for-claim.sh`,
`.claude/skills/crossplane-claim-verify/SKILL.md`, and
`.github/workflows/terraform-test.yml` (`[base] e2e-verify`, `[management]
e2e-verify`).

---

## CRITICAL findings

### C1. "Coupled to the change" has NO enforcement mechanism — it is the whole plan and it rots first
The plan's central promise (§2 "Coupling discipline: authoring a create-step
REQUIRES adding/extending its L2/L3 test in the same change") is stated as a
*discipline*, not a *gate*. The skip-guard (§2, §6) only proves the suite is
*enabled*; it cannot prove a *new create-step has a matching new test*. AGENTS.md
already encodes this discipline at length (§6.1, §6.2, §6.4) — and the premise of
this entire overhaul is that auto-012 shipped 8 blockers *anyway*, with that
discipline already written down. So the plan's load-bearing mechanism is the
exact mechanism that just demonstrably failed.

*How it bites THIS system:* a future session adds an MR kind or an IRSA grant,
runs the green suite (which has no test for the new thing), sees green, ships.
The "coupling" was goodwill; goodwill is what we are replacing. Within ~3
sessions the coverage map and reality diverge silently — the precise failure
mode auto-012 already paid for.

*Fix:* add a **coverage-manifest gate** that is itself a test. Maintain a
checked-in registry (e.g. `tests/coverage/mr-coverage.yaml`) enumerating every
XRD/MR kind and IRSA-granted action, and a unit test that **derives** the live
set from `crossplane/**` + `terraform/management/irsa.tf` and fails if any
kind/action lacks a referenced L2/L3 test. This converts "goodwill" into a
red-on-commit gate. Cite/amend §2 ("Coupling discipline") and §6 (add this as a
tooling line item alongside the skip-guard). NOTE: the repo *already* has the
seed of this in `tests/unit/test_iam_required_actions.sh` (compares irsa.tf
actions to per-component fixture lists) — the plan never references it and risks
reinventing or, worse, ignoring it. Amend §4's permission-completeness probe to
*extend* that existing test, not duplicate it.

### C2. Feedback loop for L2/L3 is "rebuild the cluster" — engineers will not run it; they'll wait for CI and disable on red
§2 says L2 "Executes in CI / the cluster context, not the CA-blocked sandbox."
Combined with §7 ("the suite runs as part of each rebuild we already do") and the
hard constraint that **cluster kube-APIs are unreachable from the dev sandbox**,
the *actual* inner loop for the new core layers is: edit → push → dispatch heavy
CI → wait 20+ min → read log. The plan never gives the developer a fast,
sandbox-local way to iterate on an L2b test. AGENTS.md §6.10/§6.7 exist precisely
because long CI loops are painful and expensive here.

*How it bites:* an L2b test that fails for a *test-authoring* reason (bad
jsonpath, wrong namespace, missing teardown) costs a full CI round-trip to
diagnose, every time. That is exactly the flake-fatigue → "add `SKIP_L2=1` to
unblock my PR" → never-removed pathway. The plan's own §2 disable switch becomes
the escape valve under deadline.

*Fix:* require every L2b test to be runnable against a **kind cluster + a fake
or moto/localstack cloud for the test-logic dry-run** (validates jsonpath,
teardown, isolation) *separately* from the real-IRSA CI run that validates
behavior. State a concrete target: "L2b test logic must pass on kind in <60s in
the sandbox; the real-IRSA assertion is the CI-only delta." Without a documented
fast loop, §3/§7's cost story only covers wall-clock, not *developer iteration
cost*, which is the thing that gets tests disabled. Amend §6 (Tooling) and §7.

### C3. "disabled/all-skipped must never read green" is asserted but the skip mechanics guarantee the opposite
The repo's integration runner (`tests/integration/run.sh`) and every script use
**exit code 2 = SKIP** on missing preconditions (e.g.
`08_irsa_sts_round_trip.sh` `skip`s when the external-dns SA annotation is
absent — *which is one of the auto-012 blockers itself*). The plan's L2a/L2b/L4
layers are riddled with preconditions ("phase 1 not deployed", "spoke not
registered", "RDS not up"). Under the existing SKIP convention, a cluster where
half the platform failed to come up will produce a sea of SKIPs and the
aggregate run still **exits 0**. §2's requirement is therefore violated by the
very harness the plan reuses.

*How it bites:* the auto-012 scenario reproduces *exactly* — external-dns SA
missing → `08` SKIPs → green. The plan claims L2b/L4 catch this, but if those
layers also `skip` on "external-dns not ready," they inherit the same blind spot.

*Fix:* the plan must define a **SKIP budget / required-coverage floor**: on
protected branches and at bring-up, a SKIP in a layer that *should* be
exercisable (the platform claims to be deployed) is a FAIL, not a pass. Concretely:
bring-up sets `PLATFORM_EXPECT=full`; any L2/L4 SKIP under that flag is promoted
to FAIL. Add this to §2 as a named sub-mechanism ("skip-promotion under
expect-full") — it is distinct from the skip-*guard* (which only checks the
disable flag) and the plan currently conflates the two.

### C4. The IRSA "permission-completeness probe" (§4) is described as the single highest-value addition but is hand-waved into existence
§4 calls for "a permission-completeness probe that exercises each MR kind's full
lifecycle (create/observe/update/delete/tag) under the real crossplane IRSA
role." That is, per MR kind, a real create→update→tag→delete cycle against AWS.
For EKS that is the ~20-min resource the plan *elsewhere* (§3) says must NEVER be
instantiated per-test. The plan does not reconcile this: §3 forbids throwaway
EKS; §4 demands full-lifecycle exercise of "each MR kind" including the EKS
composition's MRs (Cluster, Nodegroup, OIDC provider, IAM roles). It cannot be
both.

*How it bites:* whoever implements §4 either (a) excludes the expensive kinds —
re-opening the exact `eks:*`/`rds:*` IAM gap auto-012 hit — or (b) includes them
and the probe takes 30+ min and gets disabled. Either way the "single
highest-value addition" is the first thing to rot.

*Fix:* split the probe explicitly. (a) **Static-extended:** grow the existing
`test_iam_required_actions.sh` to assert the irsa.tf policy covers the *full
verb-set* (Create/Describe/Update/Tag/Untag/Delete + List) for every action
*prefix* each MR kind needs — this is the cheap, fast, no-AWS layer that would
have caught the missing `iam:Tag`/`rds:*` class at commit time. (b) **Live
dry-run:** use the AWS IAM **policy simulator** (`aws iam simulate-principal-policy`)
against the *real* crossplane IRSA role ARN to confirm Allow for each
action/resource — this exercises the *real role* per the user requirement
WITHOUT creating any resource, so it works even for EKS/RDS. (c) reserve true
create-lifecycle probing for the *cheap* kinds only (S3, IAM role, OIDC, secret).
Amend §4 and the §5 matrix row ("crossplane missing iam:Tag/Update/Get + rds:*")
to point at (a)+(b), not an unbounded live lifecycle.

---

## MAJOR findings

### M1. Five-layer taxonomy (L0–L4) with sub-modes (L2a/L2b) is more vocabulary than the team can sustain
§1 introduces L0, L1, L2a, L2b, L3, L4 — six named buckets, plus a rename of
`tests/unit/`→`tests/lint/`. AGENTS.md already names layers (Unit, kubeconform,
Kyverno, Integration, Chainsaw) and they are wired into `unit-tests.yml`,
`run.sh`, and §6.1's "lives at" table. The plan's taxonomy does not map cleanly
onto the existing one (is `08_irsa_sts_round_trip.sh` L2b? is
`test_iam_required_actions.sh` L0 or L3?). Two competing taxonomies in one repo
is an onboarding tax and a place where tests get mis-filed and therefore
mis-run.

*How it bites:* a newcomer reads AGENTS.md §6.1 and the plan's §1 and gets
contradictory mental models. Mis-classified tests land in the wrong runner and
silently don't execute (AGENTS.md §6.16 already documents this exact drift:
"17 of 39 tests in run.sh missing from unit-tests.yml").

*Fix:* do NOT invent a parallel taxonomy. Map onto the existing five layers and
add at most ONE new concept ("live-behavioral," the real-IRSA dimension) as a
*property/tag* on integration tests, not a new tier. Rewrite §1 to express L2/L3
as "integration tests that carry the `real-irsa` and `expect-full` tags" rather
than new directories. The rename (§1, §8 P1) is fine and cheap; keep it, drop the
rest of the tier vocabulary.

### M2. The `tests/unit/`→`tests/lint/` rename is a high-blast-radius change parked in "P1: immediate, cheap"
§8 P1 calls the honesty rename "immediate, cheap, high value." It is none of
those for maintainability. `tests/unit/` is referenced by `tests/unit/run.sh`,
`.github/workflows/unit-tests.yml` (per AGENTS.md §6.16 these MUST stay in sync),
the pre-commit hooks, SPEC-S6, and ~60 test files plus their `lib/` and
`fixtures/`. A rename touches CI path filters, skill docs, and every relative
`HERE/../..` assumption.

*How it bites:* a "cheap" P1 rename breaks `unit-tests.yml` path triggers and the
run.sh/workflow sync invariant on day one, eroding trust in the whole overhaul
before any real test lands.

*Fix:* either (a) defer the rename to its own isolated PR with a mechanical
sweep + the §6.16 sync check, explicitly NOT bundled with the skip-guard and
verify-platform.sh wiring; or (b) skip the physical rename entirely and achieve
"honesty" via a README + a label, since the value is conceptual, not structural.
Amend §8 P1 to unbundle.

### M3. `verify-platform.sh` runs L0→L4 "in order" — a 20-min serial pipeline nobody runs locally and that fails slow
§2 + §7 describe a single entrypoint running all layers in order, with EKS
amortized into bring-up. But "in order" means a lint typo (L0) is found fast,
while an L4 e2e failure surfaces only after L0–L3 pass — and L2a after-the-fact
EKS assertions sit behind a 20-min cluster build. There is no fail-fast ordering
story for the *common* developer change (tweaking a Composition), and no
statement that L0/L1 gate locally on every commit while L2–L4 gate only at
bring-up/CI.

*How it bites:* developers experience the suite as "the thing that takes 20+ min
and occasionally goes red at the very end." That is the canonical profile of a
suite people route around with `SKIP_L2=1`.

*Fix:* specify the execution contract explicitly in §2: L0+L1 run on every
commit (sandbox-local, seconds); L2b-cheap runs on PR CI (minutes); L2a/L3-live/L4
run at bring-up and on a label-gated CI dispatch. Make `verify-platform.sh`
*tiered with per-tier exit*, not a monolithic ordered run. Reconcile with
AGENTS.md §6.7 (heavy workflows are dispatch-only) — the plan's "every bring-up
runs L0→L4" must not silently make L4 a push-triggered heavy workflow.

### M4. L2b teardown + per-run-ID prefixing is real maintenance burden the plan underestimates on an ephemeral, rotated account
§7 reuses "per-run-ID resource prefixing + a guaranteed cleanup trap." AGENTS.md
§6.19 forbids `|| true` on cleanup, and the account is ephemeral/rotated. Every
new L2b test (the plan wants one per cheap MR kind) is a new place for an orphan
resource, a new teardown trap to get right, and a new flake source when AWS
eventual-consistency makes a just-deleted resource still observable. The plan
treats this as solved ("the chainsaw pattern") but chainsaw runs on kind+fake
cloud — the real-AWS L2b case is genuinely harder and the repo's own
`docs/open-issues.md` history (OI-2026-05-28-1) shows cleanup masking cascading
failures.

*How it bites:* leaked IAM roles/OIDC providers/S3 buckets accumulate across
runs on a long-lived account; on a *rotated* account, half-torn-down state from a
failed teardown produces confusing red on the *next* account. Flake fatigue
again.

*Fix:* add a **sweeper** as a first-class deliverable, not an afterthought: a
`scripts/l2b-sweep.sh` that deletes every resource carrying the run-ID *or
test-harness* tag, run at the START of each L2b suite (not just via trap), so a
prior crashed run self-heals. Mandate a single shared tag key
(`harness=l2b`) so the sweep is exhaustive. Amend §7 and §9 (the isolation
risk is named but the mitigation is under-specified).

### M5. Negative/precondition tests (§4) assert "stays NotReady/crashloops" — these are slow, timing-dependent, and flaky by construction
§4 wants assertions like "Keycloak Deployment stays NotReady when the DB secret
is absent" and "external-dns surfaces an auth error and writes no records." These
are *negative-liveness* assertions: proving something *stays* bad requires
waiting out a window, and "writes no records" is unfalsifiable without a bounded
wait + a real Route53 read. Negative tests that wait are the #1 flake source and
the #1 candidate for `|| true` / timeout-bumping (which §6.19 / §6.24 forbid but
which deadline pressure produces anyway).

*How it bites:* a CI runner under load takes longer to crashloop; the test's
"stays NotReady for 60s" window flakes; an engineer bumps the window or skips it.
The precondition guarantee silently erodes.

*Fix:* prefer **deterministic** precondition checks over liveness windows where
possible: assert the *guard exists and fires* (e.g. an admission/Kyverno policy
or an init-container that exits non-zero on missing DB secret) rather than
observing crashloop behavior over time. AGENTS.md §6.1 already lists Kyverno as
the runtime-invariant layer — route preconditions there. Reserve
deployment-stays-NotReady tests for the few cases with no static/admission
expression, and give them a single shared bounded-wait helper (extend
`wait-for-claim.sh`'s pattern) so the timeout policy lives in one place. Amend §4.

### M6. The §5 coverage matrix is a static doc that will go stale — it has no test
§5 maps each of the 8 (listed as 6) auto-012 blockers to a catching layer. This
is exactly the kind of traceability matrix AGENTS.md §6.4 keeps in
`ai/TESTING-PLAN.md`. A matrix in a plan file is write-once: when an XRD changes
or a layer is refactored, nobody updates §5, and it becomes a comforting lie.
Also: the matrix lists only 6 rows but the premise (§0) and the CONTEXT cite **8**
blockers — two are silently missing from the matrix (the ArgoCD application-
controller SA IRSA annotation is folded in, but e.g. the EKS authenticationMode
and the AppProject IngressClass are present while at least two named blockers —
the chart SA-name mismatch and untagged subnets — are partially covered; the row
count doesn't reconcile to 8).

*Fix:* (a) reconcile the matrix to all 8 named blockers explicitly, one row each,
or state which are merged and why. (b) Move the matrix into
`ai/TESTING-PLAN.md`'s bug-to-test traceability section (the canonical home per
§6.4) and add a unit test that every blocker row names a test file that *exists*.
A matrix with no test is documentation; documentation rots.

---

## MINOR findings

### m1. Disable-switch governance (§9) is listed as an open question, not answered — and it's load-bearing
§2 mandates `PLATFORM_VERIFY=off` exists and §9 admits "who may set it and the
audit trail" is open. An unowned disable switch is a disabled suite waiting to
happen. *Fix:* answer it in-plan: the flag may only be set in a committed file
(not an ad-hoc env in CI), so flipping it is a reviewable diff; the skip-guard
checks for the file, not an env var. Cheap, closes the goodwill gap.

### m2. "Re-point chainsaw at a real cluster" (§6) fights the repo's chainsaw contract
AGENTS.md §6.7/§6.8 build chainsaw around kind + a verifier workflow + a static
pre-dispatch audit. §6's "re-point chainsaw (or add kuttl)" at a real cluster is
a big tooling fork stated as a parenthetical. *Fix:* don't re-point chainsaw;
keep it L1 (the plan even says so in §1) and use the existing **integration
suite** (`tests/integration/`) as the real-cluster harness — it already has
cluster access, RUN_ID prefixing, skip/fail conventions, and 13 live tests. The
plan under-credits this existing asset throughout.

### m3. RDS "opt-in L2b behind a flag" (§3) creates a layer that is off by default — contradicting the plan's own thesis
§3 puts the RDS ephemeral test "behind a flag," i.e. normally not run. The whole
plan's thesis (§0, §2) is that off-by-default verification is how auto-012
happened. A flagged-off L2b for the Composition-change case will not be on when
the Composition changes unless something *forces* it. *Fix:* tie the flag to a
path trigger — if `crossplane/.../xdatabase/**` changes, the RDS L2b is required,
not optional. This is the §C1 coverage-gate mechanism applied to the one case the
plan already wanted to special-case.

### m4. No statement on test runtime budget / total wall-clock ceiling
§7 addresses per-resource cost but never states a *total* budget for
`verify-platform.sh` or a per-layer timeout policy beyond "via
wait-for-claim.sh." Without a ceiling, the suite grows unbounded as each phase
adds tests (§8 says every phase adds coupled tests), and an unbounded suite is an
abandoned suite. *Fix:* state explicit per-tier wall-clock ceilings and make
exceeding them a CI warning.

---

## What the plan got RIGHT — the synthesis MUST preserve these

1. **The honesty thesis (§0, §1): lints are not tests.** Naming the
   `yq`/`grep`-over-YAML class as "lint" and reserving "test" for behavioral
   verification is correct and is the single most important conceptual fix.
   Preserve the *concept* even if you drop the six-tier vocabulary (M1).

2. **Real-IRSA verification as the core (§1 L2, §2, §4 probe).** The insight that
   the bug class is invisible until something runs *under the restricted
   Crossplane IRSA role*, not admin creds, is exactly right and is the root cause
   of auto-012. Preserve it — but implement it via the IAM policy simulator + a
   static verb-completeness extension (C4) so it's cheap enough to actually run
   every change.

3. **On-by-default with a reviewable disable, and "all-skipped ≠ green."** (§2)
   The *requirement* is correct and matches the user's hard constraint. Preserve
   it; harden the mechanics with skip-promotion-under-expect-full (C3) and a
   committed-file disable switch (m1).

4. **Slow-vs-cheap split: EKS verified after-the-fact, amortized into bring-up;
   cheap resources instantiate-and-verify (§3).** This is the right cost model
   for an ephemeral, expensive-EKS account. Preserve it — just resolve the §4-vs-§3
   contradiction (C4).

5. **Reuse of existing assets: `crossplane-claim-verify` as the mandatory
   verifier, `wait-for-claim.sh` for bounded waits, the chainsaw RUN-ID prefix +
   cleanup trap (§6, §7).** Building on what exists rather than greenfield is the
   right maintainability instinct — extend it to *also* credit the existing
   integration suite and `test_iam_required_actions.sh` (M1, m2, C1).

6. **Phased rollout that adds coupled tests per component, nothing deferred to a
   nightly (§8).** The "no nightly" stance is correct — nightly is where coupling
   dies. Preserve it; just give "coupled" real teeth via the coverage-manifest
   gate (C1).

---

## Bottom line
The plan's *requirements* and *thesis* are correct and must survive synthesis.
Its *mechanisms* lean on goodwill (C1), a painful inner loop (C2), a skip
convention that re-creates the exact auto-012 blind spot (C3), and a flagship
probe that contradicts its own cost policy (C4). Fix those four and the plan
becomes something engineers will actually keep on; leave them and it is disabled
within three sessions.
