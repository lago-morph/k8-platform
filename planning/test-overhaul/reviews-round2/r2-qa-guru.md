# Round-2 Adversarial Review — SYNTHESIZED-PLAN.md

**Reviewer:** QA / test-architecture expert for systems dependent on external
live systems. Round-1 author; now adversary of the merged result.
**Lens:** taxonomy coherence vs the 6 requirements; the executed-floor /
expected-profile mechanism (sound & unbypassable?); resource lifecycle / cleanup
/ idempotency on an ephemeral account; flake / retry / timeout / false-fail SLO;
gating model + anti-silent-regression; negative / precondition / health-gate
rigor (guard-fired vs absence); observability + triage; coverage honesty; and any
classic testing anti-pattern the *merge itself* introduced.
**Method:** read the synthesis cold and full; re-read all 9 round-1 reviews to
check each claimed resolution; grounded the load-bearing repo claims.

## Grounding I confirmed (so the review stands on fact, not the plan's say-so)
- `tests/integration/lib/test-lib.sh:18` — `skip() { ...; exit 0; }`; `run.sh`
  exits 0 whenever `FAIL==0`. The plan's central diagnosis (skip=green, all-skip
  reads green) is **true**. The whole §3 mechanism is therefore load-bearing and
  must actually invert this.
- `terraform/management/irsa.tf:174` — provider role trust =
  `crossplane-system:upbound-provider-family-aws` only. The §2 "no probe SA, drive
  the real controller" pivot is correctly grounded.
- `tests/unit/test_iam_required_actions.sh:12-17` — it is a **presence/floor** test
  that *accepts* `service:*` and `X:*` wildcards by design. The §4 "convert to a
  two-sided ceiling+floor" claim is real work, not a relabel, and the header's
  `route53:*` acceptance is a live wildcard the ceiling must reckon with.
- `tests/live/` **does not exist**; `apply-and-verify` lives in
  `.github/workflows/{terraform,integration}-tests.yml` — i.e. inside the workflow
  files this environment **cannot edit**. This directly threatens the §3.1 wiring
  and §8 spoke trigger (see C1).

Verdict up front: the synthesis is a genuine improvement. It correctly killed the
probe-SA fantasy (C1/C2 of three security/SRE reviews), replaced "add-a-grant"
with simulate + a ceiling, moved enforcement onto `tests/unit/run.sh`, and
invented the `expect-full` skip-promotion — which is the single best new idea in
the document and the actual answer to requirement 2. But the merge introduced
**new** seams, and several round-1 criticals are declared resolved by *prose* that
an implementer cannot execute against. Ranked below. The §0 center (real cloud ×
restricted identity, on by default, coupled to the change) must survive
finalization unweakened — that is non-negotiable and the plan keeps it.

---

## CRITICAL

### R2-C1. The on-by-default wiring AND the spoke trigger both require editing workflow files the environment cannot edit — the same constraint that killed PLAN-B/C enforcement now silently undermines requirement 1.
The synthesis resolved the *enforcement* workflow-scope problem elegantly (§3.4:
route the GATE through the already-push-gated `tests/unit/run.sh`). But it did
**not** apply the same honesty to the two things that deliver requirement 1
itself:
- §3.1: "invoked automatically at the **end of every `apply-and-verify`**."
- §8: "run **automatically at the end of any spoke `apply-and-verify`/
  reconcile-completion**."

`apply-and-verify` is a *workflow* (`terraform-test.yml`). Wiring `tests/live/run.sh`
into it is a `.github/workflows/*` edit — exactly what §3.4 and §13 concede is
impossible in this environment (OI-2026-06-05-6). So the plan's enforcement is
landable but its **trigger is not**, by the plan's own constraint. The result is
the worst split: a *gate* that fails PRs for missing coverage (lands), and an
*executor* that never actually runs on bring-up (doesn't land) — i.e. CI goes red
demanding live evidence that nothing is configured to produce. §14.2 flags the
spoke-API read-path version as "an operator dependency," but the *general*
on-every-bring-up wiring is presented in §3.1/§12-P2 as if it ships in-band.

This is the round-1 "stranded enforcement" critical (sre-B C2, DevX-B C2)
re-appearing on the *trigger* side, un-resolved. A reader of §12 believes
requirement 1 is delivered by P2; it is delivered only if an out-of-band operator
edits the workflow.

**Fix (finalization must do this, not defer it):** add an explicit
"operator-dependency ledger" naming **every** change that requires workflow scope
(the `apply-and-verify`→`tests/live/run.sh` call; the spoke reconcile-completion
hook; any `kube-diagnose.yml` extension for spoke-API reads). For each, state the
*committable* half (the script + its self-test) vs the *operator* half (the YAML
line), and gate the requirement-1 claim behind the operator half landing.
Critically: until the trigger lands, the §3.3 executed-floor must treat
"`tests/live/run.sh` was never invoked for this HEAD SHA" as a **FAIL of the gate
in `tests/unit/run.sh`** (a HEAD-SHA "live-evidence exists" check, the teeth DevX-C
M4 demanded and the synthesis dropped) — otherwise "coupled to the change" reduces
to "coupled to whoever remembers to dispatch," the exact goodwill that produced
auto-012. [K8S/CI-SPECIALIST must confirm whether a committable script invoked by
the *existing* integration-tests step can stand in for the workflow edit.]

### R2-C2. The executed-floor is anchored to `expect-full`, which is *self-declared by the same bring-up under test* — a circular oracle the plan acknowledges (§14.4) but does not break.
§3.3 is the load-bearing anti-silent-regression mechanism, and its honesty rests
entirely on the bring-up "correctly declaring which phase it applied → sets
`expect-full`." §14.4 admits "a bug there re-introduces silent-skip-green" and
points to `phase=test` orchestrator unit tests. But those unit tests verify the
*tabulation* (`expect-full + skipped ⇒ FAIL`); they cannot verify the *input* —
that the phase actually applied is the phase that set `expect-full`. The oracle and
the system-under-test share a source of truth: if the apply step under-declares
(applies the spoke phase but fails to set `expect-full` for spoke resources, or
crashes before declaring), every spoke check legitimately downgrades to
"phase-not-applied" and reads green. That is **blocker #5's exact shape, one level
up**: a silent omission in the declaration layer produces a green where a resource
is missing.

This is a classic test-architecture anti-pattern: the **self-attested expectation**
(letting the thing under test tell the harness what to expect of it). Round-1
DevX-B C3 derived the three-state skip model precisely to avoid "is the resource
there" driving the verdict — but the synthesis swapped one self-reference (the
resource) for another (the applier's own declaration) and called it resolved.

**Fix:** derive `expect-full` from an **independent** signal, not the applier's
self-report. Candidates: (a) the committed desired-state for the cluster/phase
(what `clusters/**` or the XR set declares *should* exist) diffed against runtime —
the coverage manifest of §3.5 already derives the kind set; key `expect-full` off
*that* plus "this XR/Composition is present in git for this cluster," not off a
runtime flag the applier writes; (b) at minimum, make "the applier did not emit any
phase declaration at all" a hard FAIL (fail-closed on a missing oracle), so a
crash-before-declare cannot read green. State which. Finalization must not ship the
floor with its expectation sourced from the system under test.

### R2-C3. The plan now contains TWO un-reconciled completeness oracles for IRSA permissions — `simulate-principal-policy` (§2.3/§4.3) and the un-exercised-grant CloudTrail tier (§4.2) — and they can disagree, with no tie-break. The merge created a contradiction the source plans didn't have.
The synthesis (rightly) adopted `simulate-principal-policy` as the completeness
floor for IRSA actions (resolving security-B C2, the add-a-grant ratchet). It also
adopted security-C's C1 idea: a tier that **fails on grants never exercised** by
the positive bring-up tests (§4.2, CloudTrail / access-analyzer). Individually
each is defensible. **Together, unreconciled, they are a contradiction:**
- §2.3/§4.3 says: the role MUST grant action X (simulate returns `allowed`) because
  a Composition needs it — even for EKS/RDS which are **never instantiated**
  (§5: AFTER-THE-FACT only).
- §4.2 says: any granted action **never exercised** by the bring-up positive tests
  is a FAIL (must be removed or annotated).

EKS/RDS create-path actions are *required by simulate* yet *never exercised at
runtime by design* (the plan forbids instantiating them, §5/§13). So the EKS/RDS
IAM grants are simultaneously "must be present" (floor) and "never exercised ⇒ fail"
(ceiling). The plan's escape — "beyond the annotated allowlist" (§4.2) — means
**every expensive-kind action lives permanently in the allowlist**, which is just
the §4.1 wildcard-justification annotation by another name, and it guts §4.2's value
exactly where the highest-blast-radius grants (`iam:*`, `rds:*`, `eks:*`) live. The
un-exercised-grant tier thus polices only the cheap kinds it least needs to police.

**Fix:** make the two oracles one contract with explicit precedence. State:
"completeness (floor) = simulate against the committed required-action set derived
per §3.5; the un-exercised-grant tier (§4.2) operates **only on the delta** between
*granted* and *(exercised-at-runtime ∪ required-by-an-uninstantiated-expensive-kind
∪ annotated)*." Then the expensive-kind actions are accounted by the *derivation*
(they're required-by-a-known-kind), not dumped in a free-text allowlist. Without
this the merge ships a self-contradicting pair that an implementer resolves by
making §4.2 toothless. Also resolve §14.5 (CloudTrail latency may force §4.2
out-of-band) **before** crediting §4.2 in the §10 matrix — an async tier is not an
in-bundle gate.

### R2-C4. "Cheap = BOTH after-the-fact AND instantiate-and-verify under real IRSA" (§5, requirement 4) collides head-on with §7.1's singleton/blast-radius invariant — for the very resources requirement 4 most cares about — and the plan does not say which wins.
§5 lists the BRING-UP/BOTH set as: "IAM role, OIDC, S3, ASM secret, ESO
ExternalSecret, ConfigMap, **ArgoCD registration**, Route53 record, ACM cert,
**IngressClass**." §7.1 then declares the **invariant** that the default bundle
"never mutates a resource a running controller treats as a singleton," and names
external-dns and admission webhooks as off-limits on the shared hub — to run only
"against a spoke the bring-up created, or behind explicit opt-in."

These overlap destructively:
- A **Route53 record** instantiate-and-verify *is* an external-dns / shared-zone
  mutation — §5 puts it in BOTH (every bring-up), §7.1 fences external-dns to
  spoke/opt-in.
- **IngressClass** is cluster-scoped and the ingress controller treats it as
  shared; §5 says BOTH, §7.1 says singleton-mutators don't run in the default
  bundle.
- **ArgoCD registration** churn on the shared hub is exactly what sre-B C1 said
  poisons the next session's app list.

So requirement 4 ("instantiate-on-purpose for everything cheap") and the
blast-radius invariant are in direct tension, and the synthesis asserts both
without a resolution rule. An implementer reading §5 ships the Route53/IngressClass
BRING-UP tests on the shared hub (satisfying req 4) and violates §7.1; or honors
§7.1 and silently drops those from the default bundle (violating req 4) — and
because §5 doesn't tag *which cheap resources are singleton-coupled*, the choice is
made ad hoc, per author, invisibly.

**Fix:** partition the §5 "cheap" set into **(a) hermetically-instantiable**
(per-run-id IAM role, OIDC, S3, ASM secret, ESO ExternalSecret, ConfigMap, ACM cert
— no shared-singleton coupling) which get BOTH on every bring-up, and **(b)
singleton-coupled** (Route53 record, IngressClass, ArgoCD registration) which get
AFTER-THE-FACT on the shared hub by default and BRING-UP **only against a
bring-up-created spoke or an opt-in lane**. Make this partition a column in §5 and
in the §10 matrix, and a `singleton-coupled` tag the coverage test understands — so
requirement 4's "both" is honored *where physically safe* and the invariant is
honored everywhere. State the rule: "req-4 'both' applies to the hermetic set
unconditionally and to the singleton-coupled set on a spoke." This is the most
likely place the merge silently violates one of the user's six requirements.

---

## MAJOR

### R2-M1. The false-fail SLO (§11) has no denominator, no baseline, and no consequence wired to the gate — it is a metric, not a control, and the plan admits its state store is unsolved (§14.6).
§11 sets "false-fail rate < 2%" but: (a) **false-fail** is undefined — who
adjudicates a red as false vs true? The plan needs an operational definition (e.g.
"a red whose triage closed as ENVIRONMENTAL/ROTATION/THROTTLE/QUOTA, divided by all
reds") or 2% is unmeasurable. (b) The SLO has **no teeth**: nothing in §11 says
what happens when it's breached — §11 mentions auto-quarantine for a *per-test*
N-of-M failure, but the *bundle-level* SLO breach has no action. (c) §14.6 concedes
the append-only outcome log "where does it live" is unresolved on ephemeral
accounts — so the SLO's data substrate doesn't exist yet, making the whole control
aspirational, which is precisely the round-1 sre-C C2 critique it claims to resolve.

The merge took sre-C's "tie on-by-default to a measured SLO" and DevX-C's
"mechanical quarantine," combined them, but left the data plane (persistent
cross-run state on a rotated account) as open-question #6 — i.e. the load-bearing
substrate for *both* §11 controls is unbuilt. A flake control whose memory resets
every account rotation cannot detect "N of last M runs."

**Fix:** finalization must resolve §14.6 (committed file vs CI artifact vs external
store) **before** §11 is credited as the requirement-2-survival mechanism, because
on-by-default's durability depends on it. Define false-fail operationally as the
triage-disposition ratio (which the §7.4 classifier categories already make
machine-computable: ENVIRONMENTAL-ROTATION / THROTTLE / QUOTA / AccessDenied),
make a breach *demote the offending check to the quarantine lane automatically*
(the only consequence that matters), and pin the per-test history to a committed
`tests/live/FLAKE_LOG` (survives rotation; a real diff; reviewable) rather than an
ephemeral artifact.

### R2-M2. Idempotency and concurrency-interlock are asserted but un-falsifiable as written — and idempotency was demoted to P6 "rare manual double-run," contradicting the ephemeral-account cleanup-collision risk the plan itself raises.
- **Idempotency:** §12-P6 keeps it as "idempotency per-test (+ a rare manual
  double-run)." But §7.2 documents a *real* idempotency hazard — ASM secrets'
  7-30 day recovery window means a same-name re-run hits `ScheduledForDeletion`
  (sre-A C3), and global IAM/OIDC names collide. Those are idempotency bugs that
  bite on **every re-run on the ephemeral account**, not rare events. Demoting the
  property to a manual P6 lane means the suite ships idempotency-broken for the whole
  rollout (sre-C m5 made this exact point about PLAN-C; the synthesis re-introduced
  the demotion). The `force-delete-without-recovery` + run-id-embedding fixes in
  §7.2 are correct but **untested** unless a per-test re-apply assertion exists.
  **Fix:** make "apply the same XR twice ⇒ exactly one cloud resource, no
  `ScheduledForDeletion`, no name collision" a *standing per-test* assertion in the
  hermetic BRING-UP set (cheap; no extra wall-clock beyond a second apply of an
  already-fast resource), not a manual lane. Idempotency is a correctness property
  of the create-path the suite exists to verify, not hardening.
- **Concurrency interlock (§7.1):** "a cluster-level mutex (lease/ConfigMap) or a
  GH Actions `concurrency:` group." The `concurrency:` group is again a *workflow*
  edit (R2-C1's constraint). The lease/ConfigMap is committable but the plan never
  says what happens to a run that **fails to acquire** (block? fail? skip?) — and a
  skip-on-contention re-opens requirement 2 (a contended run that skips everything
  reads green). **Fix:** specify acquire-or-FAIL (never acquire-or-skip), with a
  bounded wait, and confirm the lease lives in committable k8s state, not workflow
  YAML. [K8S-SPECIALIST: confirm a hub Lease is writable by the integration-tests
  identity.]

### R2-M3. The negative/precondition rigor is much improved but the merge created an unfalsifiable "Enforce-mode" gap: the plan mandates `validationFailureAction: Enforce` + `failurePolicy: Fail` for the DB gate (§6) while documenting that the live withhold-DB test is "isolated, on-demand, NOT every-bring-up" — so on the default bring-up, *nothing executes the enforce path*; only a static read of the policy object proves "Enforce."
§6 correctly demands guard-fired-not-absence and asserts enforce-mode is active.
But it then (correctly, for blast-radius) makes the *behavioral* withhold-DB test
on-demand/isolated, not part of the default bundle. The residue: on every
bring-up, the DB precondition's coverage is a **static assertion that the policy
says `Enforce`** — which is itself the "manifest-says-X vs X-works" disease §0
indicts, one notch up. A policy can be `Enforce` with a `match` block that misses
the real workload (sre-C M4's mis-scope risk), and the static check passes.

This is the round-1 "guard-fired vs absence" critical recurring as "guard-*declared*
vs guard-*fires*." The plan asserts mode but, in the default path, never fires it.

**Fix:** keep the behavioral withhold-DB out of the default bundle (right call),
but add to the default bundle a **cheap, hermetic, always-on positive-control firing
of the gate**: in the throwaway `live-verify-<run-id>` namespace, apply a
deliberately-violating *throwaway* object (not Keycloak, not shared infra) and
assert the webhook **denies it with the named reason** — proving the enforce path is
wired *and scoped to fire*, every bring-up, with zero shared-infra risk. Pair it
with the §6 "does NOT block a healthy throwaway workload" negative (already
specified) so mis-scope in either direction is caught on-by-default. Without the
firing test, "Enforce mode" is a lint.

### R2-M4. Coverage honesty: the derived manifest (§3.5) cannot see the side-effect resources that were 2 of the 9 blockers (untagged subnet, controller-created NLB), and the `extra:` allowlist is the manual second-source-of-truth the section exists to abolish — the plan admits this in §14.3 but still credits the manifest as the requirement-6 spine.
§3.5 derives the provisioned set from `crossplane/**` `resources[].base.kind` +
irsa.tf actions — a real improvement over a hand list. But §14.3 concedes the exact
failure: "side-effect resources (untagged subnet, controller-created LBs) are
exactly the ones absent from `resources[]`." Blockers #9 (subnet tag) and the NLB
are *side-effects*, so the two blockers most about "the manifest said nothing and
nothing built" land in the `extra:` allowlist — a hand-maintained list with a
free-text `reason:`, i.e. the drift-prone second copy of truth that DevX-C C2 /
sre-C M3 told the synthesis to eliminate. The derivation abolished the hand list for
the *easy* resources and re-created it for the *hard* ones (the side-effects),
which are the ones coverage rot actually hides.

**Fix:** §14.3 already names the right reconciliation source — a live
`resourcegroupstaggingapi` view of what was actually created. Promote that from
"periodically" (advisory) to a **standing AFTER-THE-FACT check**: diff
*actually-tagged-created cloud resources for this run/cluster* against
(derived-kinds ∪ `extra:` allowlist); a created resource in neither is a FAIL
(uncovered side-effect) and an `extra:` entry with no matching real resource for N
runs is a FAIL (stale allowlist). That closes the side-effect blind spot with a
real oracle instead of trusting a free-text reason. Until then, do not call the
manifest "the requirement-6 spine" — call it "the spine for declared kinds; the
RGT-diff is the spine for side-effects."

### R2-M5. Wall-clock economics of "BOTH on every bring-up" are never summed — the plan sets a per-bundle ceiling (§11) but no budget reconciling (hermetic BRING-UP set × create+verify+idempotency-double-apply+teardown) against the >20-min bring-up it rides on. The thing that gets a live suite disabled is minutes, and the merge added minutes without a total.
Every round-1 SRE/DevX review flagged the missing total budget (sre-A M3, sre-C M1,
DevX-A m4, DevX-B M3). The synthesis added the §11 hard *ceiling* (good — a hung
describe can't hold a bring-up hostage) but a ceiling is a *kill switch*, not a
*budget*. With R2-M2's idempotency double-apply now standing, the hermetic BRING-UP
set is create+verify+second-apply+teardown per kind, each with bounded
eventual-consistency polls (§11), on top of a ~20-min EKS bring-up. No number
reconciles this, and §11 explicitly says targets are "measured actuals from day
one" — i.e. unknown until it runs, which is how you discover at minute 38 that
people will disable it.

**Fix:** finalization must state a **target total added wall-clock** (e.g. "< X min
over bare bring-up") as a *budget gate distinct from the ceiling*, with the §3.5
mapping test asserting each new BRING-UP check declares an expected duration whose
sum stays under budget — so adding the N+1th cheap check that blows the budget is a
red diff, not a silent slowdown. This is the DevX-A m4 / sre-C M1 ask, dropped in
the merge.

---

## MINOR

### R2-m1. `verify` read-only (§5) vs `crossplane-claim-verify` mandatory-and-mutating (§3.1): the plan says the BRING-UP (mutating) bucket runs only on `apply-and-verify`, but also makes `crossplane-claim-verify` "the per-XR unit" invoked broadly. State explicitly that the claim-verify *skill* runs its mutating instantiate-path only under `apply-and-verify`, and exposes a read-only mode for `verify` — or `verify` silently provisions (sre-C M2, claimed-resolved, but the skill-invocation line in §3.1 re-muddies it).

### R2-m2. The reaper "runs FIRST" (§7.2) + "refuse unless `sts get-caller-identity` is the expected ephemeral account" is correct, but the reaper deletes by `label + run-id-prefix + age floor` while the *primary* teardown keys off the run-id on the XR name — two different identity schemes for the same resources. Confirm the reaper's three-key match actually covers controller-tagged side-effect resources (the OI-2026-05-28-1 `k8-platform/<XR-uid>` lesson the plan itself cites) — a reaper that can't see the controller's tag scheme is defense-in-depth against nothing. [K8S-SPECIALIST.]

### R2-m3. §6 "Crossplane v2 often ACCEPTS and fails async" → split sync-reject from async-fail with a *terminal* condition + bounded time. Good. But "terminal `Synced=False`" is not a Crossplane concept — there is no terminal flag; `Synced=False` is indistinguishable from still-reconciling except by *time + reason stability*. Specify: assert the same `reason` persists across two reads ≥ the reconcile interval apart AND no cloud resource exists — else the async-negative flakes exactly as the plan warns. [K8S-SPECIALIST confirm reconcile-interval source.]

### R2-m4. §2.3 identity assertion offers "CloudTrail `userIdentity.arn` OR `sts get-caller-identity` from a pod using the provider SA." §14.1 admits CloudTrail latency may make this slow/flaky and proposes weakening to "Synced + cloud-exists" without the ARN. That fallback **deletes the only thing that makes "under IRSA" falsifiable** (security-A C1, the resolution this plan is proudest of). Finalization must NOT take that fallback silently: if CloudTrail is too slow, the falsifiable path is the **pod-using-provider-SA `get-caller-identity`** (synchronous, no CloudTrail) — mandate *that* as the identity oracle and reserve CloudTrail for the un-exercised-grant tier only. Losing the ARN assertion is the single most dangerous quiet climbdown available at finalization.

### R2-m5. §10 matrix is "the acceptance criterion" and mirrored to `ai/TESTING-PLAN.md` with a unit test that every row names an existing file. Good. But the test asserts *existence*, not that the named test carries the right *tag* (`real-irsa`/`expect-full`) or actually exercises the row's environment — DevX-B M5's "must reference a *real* check, not a tier declaration" applies to the matrix too. A row can point at a file that lints. Strengthen the matrix self-test to assert the referenced test carries the tag the row's "Push or bring-up" column implies.

### R2-m6. Register cap N, grace window, and the "floor = zero tolerated skips for expect-full" (§14.7) are deferred to "plan-to-implementation handoff." The floor=zero is the requirement-2 guarantee; deferring its *value* is fine, deferring whether it's *enforced at all* is not. State in-plan that the floor is zero and non-negotiable; only N and the grace window are tunable. (security-C m2 made exactly this point in round 1.)

---

## Are the claimed round-1 resolutions real? Scorecard
- **Probe-SA infeasibility (sec-B C1, sre-B M2, DevX-B C1, sec-A C1):** RESOLVED.
  §2 + the explicit NON-GOAL is the correct, faithful pivot. Best resolution in the
  doc.
- **Add-a-grant ratchet (sec-A C2, sec-B C2, sec-C C1):** MOSTLY — simulate +
  ceiling + deny-tests are right, but the un-exercised-grant tier contradicts the
  simulate floor (R2-C3) and is toothless on expensive kinds.
- **Skip-reads-green / all-skip (DevX-C C1, sre-A M4, sec-A M1, DevX-B C3):**
  MECHANISM right (inverted semantics + executed floor + master-switch guard), but
  the oracle is circular (R2-C2) and the floor depends on a trigger that can't land
  (R2-C1).
- **Stranded enforcement workflow (sre-B C2, DevX-B C2):** RESOLVED for the *gate*;
  RE-OPENED for the *trigger* (R2-C1).
- **Guard-fired vs absence (sec-A M2, sec-B M1, sec-C C2/C3):** RESOLVED in
  principle (positive-control + named-reason rule); but the DB enforce-gate never
  fires on the default path (R2-M3).
- **Coverage hand-list drift (DevX-C C2, sre-C M3, sec-C C4):** RESOLVED for
  declared kinds; RE-OPENED for side-effects via `extra:` (R2-M4).
- **Blast radius / cleanup-on-SIGKILL / reaper-first (every sre C1/C3, sec C3):**
  RESOLVED at the design level (strong §7); but req-4 "both" collides with the
  singleton invariant (R2-C4).
- **False-fail SLO / flake (sre-C C2, DevX-C M2):** PARTIAL — control named, data
  plane unbuilt (R2-M1).

---

## What finalization MUST NOT weaken (in priority order)
1. **The §0 center** — real cloud × restricted identity, driving the *real
   controller* under `InjectedIdentity`, on by default, coupled to the change. Every
   reviewer said it; it is the only thing that would have caught auto-012.
2. **The falsifiable identity assertion (§2.2)** — the pod-using-provider-SA
   `get-caller-identity == expected ARN`. Do NOT take the §14.1 CloudTrail-latency
   fallback that drops the ARN check (R2-m4). Without it "under IRSA" is unfalsifiable
   and rots back to admin-green.
3. **`expect-full` skip-promotion (§3.3)** — the actual mechanism for requirement 2.
   Keep it, but break its circular oracle (R2-C2) and the floor=zero (R2-m6).
4. **The two-sided IAM contract (ceiling AND floor) + deny tests (§4)** — the
   anti-ratchet. Reconcile the two completeness oracles (R2-C3) but never drop the
   ceiling or the "proven by what fails" deny tests.
5. **Reaper-runs-first + remediate-not-report + the run-id/age/label triple + the
   ephemeral-account precondition (§7.2)** — the only thing standing between
   on-by-default mutation and a money leak.

## Bottom line
The synthesis is the right document and made the hard pivots round 1 demanded. But
finalization is where it dies if three things slip: the **trigger** (not just the
gate) must have a landable path or requirement 1 is fiction (R2-C1); the
**executed-floor oracle** must not be self-attested by the system under test
(R2-C2); and **requirement 4's "both"** must be reconciled with the singleton
blast-radius invariant per-resource, not asserted twice (R2-C4). Plus: reconcile the
two IRSA completeness oracles (R2-C3), and never trade the falsifiable ARN check for
a quiet "Synced + exists" (R2-m4). Keep the §0 center and the falsifiable identity
assertion above all.
