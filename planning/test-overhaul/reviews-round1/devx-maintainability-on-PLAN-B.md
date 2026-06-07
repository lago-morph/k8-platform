# Adversarial review — PLAN-B (k8s-testing-expert) — DevX & Maintainability lens

**Reviewer persona:** developer-experience & maintainability adversary. The
single question behind every finding: *will engineers actually run and maintain
this, or quietly disable it and let it rot within a few sessions?*

**What I read:** the full plan
(`planning/test-overhaul/plans/PLAN-B-k8s-testing-expert.md`), `AGENTS.md`
(all 1342 lines), and grounding from the live repo: `tests/unit/` (~57 scripts),
`tests/integration/` (01–13), `tests/chainsaw/`, `.github/workflows/*`,
`terraform/management/{irsa,crossplane-phase3}.tf`, the
`crossplane-claim-verify` skill, and the Composition `providerConfigRef` wiring.

I rank findings **Critical / Major / Minor**. Critical = the plan's load-bearing
claims are wrong or undeliverable as written, OR the maintenance/feedback-loop
cost is high enough that engineers route around it (the exact failure the plan
exists to prevent). Section citations are to PLAN-B unless noted.

---

## CRITICAL

### C1. The central mechanism — "run L4 create-and-verify *under the restricted Crossplane IRSA role*" — is not deliverable the way the plan assumes. (§2 L4, §4.1, §5.2, §7 footer, §11 Assumption 1)

This is the plan's thesis ("the single most important change," §7 footer) and it
rests on Assumption 1 (§11): *"The restricted Crossplane IRSA role is assumable
by a probe pod/SA we can stand up on the hub."*

Grounded in the repo, that assumption is **false in the form the plan leans on**.
The Compositions authenticate via a single shared `ClusterProviderConfig` whose
`source: InjectedIdentity` (`crossplane/compositions/*.yaml`;
`terraform/management/crossplane-phase3.tf:241`). The IRSA identity is the
**provider controller pod's ServiceAccount**, annotated through a
`DeploymentRuntimeConfig` (`terraform/management/irsa.tf:51` —
*"the ONLY subject the [trust policy permits]"*). There is no standalone
"restricted Crossplane role" that an arbitrary probe pod can `AssumeRoleWithWebIdentity`
into; the trust policy is scoped to exactly the provider's SA subject.

So a "probe pod under the IRSA role" (§4.1, §5.2 "Crossplane-IRSA permission
negative") will get `AccessDenied` on assume — not because the *system* is
broken, but because the test is impersonating a subject the trust policy
deliberately excludes. That is a **false red that looks exactly like blocker #8**,
and it will fire on every clean cluster.

The plan's own fallback (§11 Assumption 1, second sentence) silently concedes
this: *"If it can only be used by the Crossplane controller itself, L4-under-IRSA
becomes 'apply the claim and let the real controller act' rather than a direct
probe — still faithful."* That fallback is almost certainly the real world here —
which means the headline "L4 direct probe under IRSA" mechanism is dead on
arrival and the plan actually reduces to *"apply a real claim, watch the real
controller reconcile."* That is fine and correct — **but it is just
`crossplane-claim-verify` against a real claim**, which already exists. The plan's
most-emphasized novelty collapses into "use the skill we already have." The whole
of §5.2's "AssumeRole denied for mismatched subject" negative is then testing a
trust-policy tautology, not a system contract.

**How it bites THIS system:** PR-3 (the plan calls it "the central fix") is
scheduled around a probe mechanism that won't exist. The author at PR-3 time
hits §12's open question ("dedicated probe SA vs reuse the controller path") with
no answer, the adversarial-subagent review (§9) re-derives this, and PR-3 stalls
or ships the watered-down "let the controller act" version while the plan text
still claims "under the restricted IRSA role." Future readers trust the stronger
claim. This is the §6.25 trap (one signal ≠ proof) baked into the plan.

**Fix:** Rewrite §4.1/§5.2/§7 to state the *actual* faithful mechanism up front:
the only way to exercise the provider's IRSA permission surface is to apply a
real (throwaway, run-id-prefixed) XR and let the **provider controller**
reconcile it under its own injected identity, then assert `Synced`/`ReconcileError`
+ AWS `Describe*`. Delete the "direct probe assumes the role" framing. For the
IRSA *trust-subject* class (blocker #8), keep the **static** check
(`irsa_trust_validator.py --all`, which already exists and is already mandated by
AGENTS.md §6.3) as the primary gate and drop the live "mismatched-subject
AssumeRole denied" probe as redundant/tautological. Resolve §12's open question
*in the plan*, not "at PR-3 author time" — the answer determines whether PR-3
exists at all.

### C2. "Disabled/all-skipped must never read green" depends on a CI enforcement (§8.4 `live-verify` verifier) the plan admits it **cannot build this session** — so the teeth are aspirational. (§3.2 bullet 3, §8 preamble, §8.4)

User requirement 2 ("disabled but not silently regressing") is the requirement
the persona cares about most, because *silent disablement is exactly how a
slow/flaky real-cloud suite dies.* The plan's enforcement is the §8.4
`live-verify` verifier that "fails the PR check if the live-verify skip count
rose vs main without a `SKIP_REGISTER.yaml` diff."

But §8 preamble states plainly: **"this session cannot create/edit
`.github/workflows/*` (OI-2026-06-05-6)."** So the one piece of machinery that
turns "skip register" from goodwill into enforcement is the one piece the plan
cannot land. The plan's mitigation — "authored as runbook YAML + committed
scripts, then applied via the operator / `ext-github` Contents-PUT" — means the
enforcing workflow lands through a side channel that is (a) not exercised by this
session, (b) not testable locally, and (c) trivially divergent from the
committed scripts it's supposed to call.

**How it bites THIS system:** until that workflow actually exists and runs,
`LIVE_VERIFY=0` (§3.2) is a one-line env var that makes the entire live suite
pass green with a loud-but-ignorable stdout banner. CI is the only place the
cluster is reachable (the sandbox can't reach the kube-API, §6.26/§6.27), so the
*only* enforcement point is CI, and CI enforcement is exactly what's deferred. An
engineer under deadline sets `LIVE_VERIFY=0` in the workflow env (or the suite
auto-skips because of C3 below) and ships. The register test (§3.2 bullet 2)
catches *durable* `SKIP_REGISTER.yaml` disables but **not** a runtime
`LIVE_VERIFY=0` that bypasses the register entirely — the plan even says the
register is "the only sanctioned way," but nothing *prevents* the unsanctioned
env-var path.

**Fix:** (1) Make `LIVE_VERIFY=0` itself a register-gated, loud-failing state:
`run.sh` must exit **non-zero** (not green) when `LIVE_VERIFY=0` unless a
top-level register entry `disable_all` with `reason/owner/expires` exists — so
"all-skipped" is red by construction, satisfying requirement 2 literally. (2)
Sequence the plan so the enforcement (§8.4) lands *before or with* the first live
check (PR-1), not at PR-6 (§9). Shipping the checks (PR-2..5) before the
enforcement (PR-6) is precisely the window in which the discipline rots. (3) State
the dependency on OI-2026-06-05-6 as a **hard blocker** in §9, not a footnote in
§8.

### C3. The skip-guard (§3.3) is an unbounded "auto-skip when precondition absent" — which in a phase-aware, ephemeral-account, mostly-empty world means **the default outcome is "almost everything auto-skips, and that reads green."** (§3.3, §4.2, §8.3, §11 Assumption 4)

§3.3: a check "auto-skips (loudly) when its precondition is structurally absent."
§8.4 enforcement only catches *increases vs main*. AGENTS.md §8.4 establishes the
operating reality: **a rotated account is EMPTY until proven otherwise** — no
spoke, no RDS, often no mgmt cluster. §11 Assumption 4 makes the live suite
"phase-aware and skip-guards absent phases."

Combine these: on a fresh account running phase-1 bring-up, every L5 spoke/RDS
check (the slow ones, blockers #1/#2/#5/#9 — *6 of 8 blockers*) auto-skips
"loudly" because no spoke exists yet. The L4 checks that need a spoke also skip.
The summary banner says "47 skipped (precondition absent)" and **the suite exits
0**. Requirement 2 says "all-skipped must never read green" — but the plan's own
skip-guard manufactures near-all-skipped as the *normal* phase-1 state, and it's
green.

The §8.4 "vs main" diff doesn't save this: if main *also* skips them (because main
is also tested on empty accounts), the count never "increased," so the gate never
fires. The blocker-#1/#5/#9 class — the EKS/RDS/subnet ones — is therefore
*structurally* exempt from the every-bring-up guarantee for the most common
bring-up (a hub without a spoke). That's the §8.5 dispatch job's job, but §8.5 is
a *dispatch* job (manual), not on-by-default — re-opening requirement 1.

**How it bites THIS system:** the blockers the plan most wants to catch live in
the hub→spoke flow (plan §1 says "6 of 8 blockers" are there). Those are exactly
the ones that auto-skip on a hub-only bring-up and only run in a manually
dispatched §8.5 job. So the headline "runs EVERY bring-up, on by default"
(requirement 1) holds only for the cheap L4 hub-local checks; the expensive,
highest-value L5 spoke checks fall back to a manual job — the very "decoupled from
the change" anti-pattern §0 rails against.

**Fix:** Distinguish three skip states, not two: (a) **not-applicable** (no kube
access at all, e.g. sandbox — fine, informational); (b) **precondition-absent
but expected-present** (a spoke phase has been applied but the resource is
missing — this is a **FAIL**, not a skip: it's literally blocker #5's "silent
never-provisioned" shape); (c) **phase-not-applied** (legitimately skip). The
plan currently merges (b) into auto-skip, which re-creates the silent-failure
class. Drive the distinction off the phase-state the bring-up *intended* (the
`apply-and-verify` knows which phase it just applied), not off "is the resource
there" (which is the thing under test). And require §8.5's spoke verify to run
**automatically at the end of any spoke `apply-and-verify`**, not only on manual
dispatch.

---

## MAJOR

### M1. The maintenance-burden math is the persona's core worry and the plan under-prices it: this adds **four new authored artifacts that must be kept in sync** plus per-resource live fixtures, on top of an already-large suite. (§3.2, §4.3, §9, AGENTS.md §6.16)

The plan introduces, as durable maintained artifacts:
`tests/live/run.sh`, `SKIP_REGISTER.yaml` + `test_live_skip_register.sh`,
`COST_TIERS.yaml` + its mapping test, plus the §8.4 verifier and per-resource L4
create/verify/cleanup scripts. AGENTS.md §6.16 already documents that the repo
**could not keep `run.sh` in sync with `unit-tests.yml`** (17 of 39 tests drifted
out). The plan adds *three more* sync relationships:
`run.sh`↔`unit-tests.yml` (existing, now bigger), `SKIP_REGISTER.yaml`↔runtime
skips, and `COST_TIERS.yaml`↔every XRD in `crossplane/`. Each is a new drift
surface. §4.3's "a unit test asserts every XRD maps to a tier" is good, but it
means **every new XRD now fails CI until someone hand-edits `COST_TIERS.yaml`** —
a speed bump that, per the repo's own drift history, engineers will resent and
route around.

**How it bites:** the `expires` field on every `SKIP_REGISTER.yaml` entry (§3.2)
means stale entries turn CI red on a *date*, with no code change — the classic
"CI went red overnight and nobody touched anything" that erodes trust in the
suite and trains engineers to bump the date mechanically (defeating the purpose).

**Fix:** (1) Cut artifacts: fold `COST_TIERS.yaml` into a single annotation on
each XRD/Composition (`platform.k8-platform.io/verify-tier: cheap|slow`) so the
tier lives *with* the resource and can't drift into a separate file — the mapping
test then just asserts the annotation exists. (2) For `expires`: make an expired
entry a **warning that escalates to failure only after a grace window**, or
require the date-bump to come with a re-review checkbox, so a pure calendar event
doesn't break unrelated PRs. (3) Adopt the §6.16 catch-all pattern explicitly for
`tests/live/run.sh`↔workflow from day one (PR-1), not later.

### M2. Feedback-loop speed: L3/L4/L5 only run in CI on a real cluster, and the sandbox provably cannot reach the kube-API (§6.26/§6.27). So the author's inner loop for any live test is **"push → dispatch → wait ~20+ min → read CI."** The plan never gives the author a faster loop. (§2 environments, §8.3, §11 Assumption 3)

Every layer above L2 is gated on a live cluster the developer cannot reach
locally. The plan's own §8.2 keeps chainsaw kind-only as a "pre-flight," but a
chainsaw-on-kind run is itself a heavy `workflow_dispatch` (~15 min, AGENTS.md
§6.7). So authoring or debugging a single L4 check is a multi-dispatch,
tens-of-minutes loop. The persona's prediction: engineers write the L4/L5 check
once, it goes red intermittently, debugging it costs 20 minutes per iteration
(C1's false-IRSA-red will be the first such loop), and they add it to
`SKIP_REGISTER.yaml` "temporarily." The expiry date arrives, they bump it. The
check is now permanently dark.

**Fix:** The plan needs an explicit *local-iteration story* for live checks:
either (a) a documented `kubeconform`/`kuttl`/`chainsaw-on-kind`
local-Docker harness the author runs before any dispatch (AGENTS.md §6.12 shows
docker/kubectl *are* installable in the sandbox — the plan should mandate using
them), or (b) a "live-check dry-run" mode in `run.sh` that validates the check's
*shape* (selectors, AWS calls parse, cleanup logic) against recorded fixtures
without a cluster. Without one of these, the inner loop is too slow to maintain
and the suite rots — name this as a first-class requirement, not an §12 aside.

### M3. Flake policy is principled but operationally brittle: "no blind retries; eventually-consistent APIs get a bounded poll-until-true with a documented consistency budget" (§6) pushes a **per-check tuning burden** onto authors for Route53/IAM propagation, and the budgets *will* be wrong on first authoring. (§6, §5.2)

Route53 record propagation, IAM eventual consistency, and
`AssumeRoleWithWebIdentity` after a fresh OIDC provider are all genuinely
eventually-consistent. The plan correctly refuses blind retries (good — see
"preserve" list) but replaces them with hand-tuned per-check "consistency
budgets." On the ephemeral/rotated account, propagation timing varies run to run.
A budget tuned on a warm account flakes on a cold one. The plan routes flakes to
`docs/open-issues.md` (§6.18) rather than retry-til-green — correct discipline,
but it means **each flake costs an OI entry + a human tuning pass**, and the
persona knows what happens to suites that demand a human tuning pass per flake:
they get disabled.

**Fix:** Standardize *one* shared bounded-poll helper in `scripts/_lib/` with a
single, generous, env-overridable default budget per AWS service class
(DNS/IAM/STS), so authors don't hand-tune per check and the budget is changed in
one place when the account behaves differently. Cite the existing
`scripts/wait-for-claim.sh` exact-equality pattern as the model. This converts N
per-check tuning surfaces into one.

### M4. Taxonomy complexity (six layers L0–L5) raises onboarding cost and creates ambiguous assignment, and the plan's own assignments are inconsistent. (§2, §5, §7)

Six layers, two axes ("when the contract fails" + cost), and a per-contract
"cheapest layer that fails for the right reason" rule is a lot of ontology for a
new contributor to internalize before they can place a single new test. Evidence
it's already ambiguous: §5.1 places XRD required-field rejection at **both** L1
and L3; §5.2's IRSA-permission negative is called L4 in §2's table but §7 row 2
labels the same blocker "L4/L5 under restricted IRSA"; the Keycloak precondition
spans L0/L2 *and* L4/L5 (§5.3). When the canonical example contracts each land in
2–3 layers, the "assign each contract to the cheapest single layer" discipline
(§2) isn't actually being followed — which means new contributors will copy the
inconsistency.

**How it bites:** onboarding friction + assignment bikeshedding + the §6.4
adversarial-review step (mandatory per AGENTS.md) spends its budget arguing layer
placement instead of coverage. Taxonomies that aren't crisp get ignored;
engineers dump everything into whichever layer they understand (here: L0 static
lints — the exact regression the plan is trying to reverse).

**Fix:** Collapse to **three** operationally-distinct buckets that map to *where
the test runs*, which is what actually constrains authors: **pre-flight** (local,
no cluster = today's L0+L1+L2), **bring-up create-and-verify** (real cluster,
cheap = L4), **after-the-fact** (real cluster, slow = L5). Fold L3 (live
admission/RBAC) into bring-up. The "fails for the right reason" prose can stay as
guidance, but the *names* engineers use day-to-day should be three, not six.

### M5. "Coupled to the change, not nightly" has **no enforcement teeth** beyond the §8.4 verifier (already shown shaky in C2) and goodwill toward AGENTS.md §6.1/§6.2. The persona's brief explicitly asks whether this rots — it will. (§0, §9 closing paragraph, AGENTS.md §6.1/§6.4)

§9's closing sentence leans entirely on AGENTS.md §6.2 ("write the failing test
first") and §6.4 (adversarial subagent). Those are *process* disciplines enforced
by **agent goodwill**, not by a machine. Nothing in the plan mechanically asserts
"a PR that adds/changes an XRD also adds/changes a live check." The
`COST_TIERS.yaml` mapping test (§4.3) forces a *tier decision* on new XRDs but
**not** an actual live check — you can satisfy it by writing `tier: slow` and
never authoring the L5 verifier. So the coupling the plan sells is, at the
machine level, "you must declare a tier," not "you must verify."

**Fix:** Make the mapping test stronger: every XRD with `tier: cheap` must have a
discoverable L4 check keyed to its kind (the test greps `tests/live/` for a check
referencing that kind); `tier: slow` must have an L5 check referenced in the §8.5
job manifest. Now "add an XRD" mechanically fails CI until a real verifier exists
or the absence is registered with `reason/owner/expires`. *That* is a tooth.
Without it, §0's thesis is unenforced.

### M6. Negative/precondition tests (§5.3) that assert a pod "stays Pending/CrashLoopBackOff and never goes Ready" are a **slow, flaky, expensive failure to prove a negative**, and the cleanup/setup ("DB intentionally absent") mutates shared cluster state. (§5.3 L4/L5)

Proving Keycloak "does NOT go Ready" requires waiting out a timeout (you can't
wait-for-condition on the *absence* of Ready — you wait a fixed budget and assert
it never flipped). That's a built-in slow path and an inherent flake risk
(too-short budget = false pass; too-long = slow suite). Worse, "with the DB
intentionally absent/unreachable" means **mutating the live cluster** (deleting
the DB secret or scaling down RDS) on a shared bring-up — exactly the kind of
destructive setup that contaminates other checks if cleanup fails (AGENTS.md §6.19
exists because cleanup masking already burned this repo).

**Fix:** Push the Keycloak-needs-DB precondition down to **L2 (`helm unittest` /
render)** as the primary gate — assert the init-container/readiness-gate that
blocks startup *exists in the rendered manifest* (deterministic, fast, no cluster
mutation). Keep a single live "fails-closed" check only in the dedicated §8.5 e2e
job in an isolated namespace with its own torn-down DB, never inline in the
on-by-default bring-up suite. The plan already gestures at the L2 version
(§5.3 bullet 1) — make it the load-bearing one and demote the live mutation.

---

## MINOR

### m1. `whereami.sh` + `sts get-caller-identity` rotation guard (§6) is good, but the plan should also assert the suite **fails fast with a rotation message in < 5s**, before any check runs — otherwise the first 10 checks emit confusing AccessDenied noise that looks like blockers #2–#5. (§6 "account-rotation guard")

### m2. "Cost guard … `aws ce`/tag-scan budget check" (§6) — Cost Explorer data lags ~24h and CE itself costs per API call; it cannot gate a synchronous bring-up. Replace with a synchronous **tag-scan leak count** (enumerate run-id-prefixed resources at suite end), which the plan also mentions and which actually works in-band. Drop the `aws ce` reference.

### m3. §9 PR ordering ships the *mechanism* (PR-1) and *checks* (PR-2..5) before the *enforcement* (PR-6). Per the persona, the un-enforced window is where disablement becomes habit. Reorder so the verifier (§8.4) is in PR-1 with the scaffold. (See C2.)

### m4. The plan says static `yq`/`grep` lints are "demoted to pre-flight, never the test" (§0, §2 L0) but AGENTS.md §6.1 mandates *maximal* overlapping coverage including these lints as first-class. "Demoted" risks reading as "deprioritized" to a future agent and conflicting with §6.1. Reword to "retained as the fast first gate; no longer *sufficient* on their own" to avoid the appearance of weakening §6.1's required layers.

### m5. §8.1 wants new L0 guards in `unit-tests.yml`, but per AGENTS.md §6.16 the plan must say *which* pattern (per-step vs catch-all). Unspecified, this is the exact drift §6.16 documents. (Minor only because §6.16 already mandates it; the plan should just name it.)

### m6. `test_keycloak_db_secret_contract.sh` and `test_keycloak_db_xr.sh` already exist (repo grounding). §5.3 says "extends `test_keycloak_db_secret_contract.sh`" — good, but the plan should audit what's *already covered* before authoring the L2 precondition test, or it duplicates existing coverage (a maintenance smell the persona flags).

---

## What the plan got RIGHT — the synthesis MUST preserve these

1. **The core diagnosis and the create-and-verify *coupling* (§0).** "Prove X
   works, not that the manifest says X," coupled to the change rather than
   nightly, is exactly correct and is the whole point. Preserve the thesis even
   while fixing the mechanism (C1).

2. **Reusing existing assets instead of rebuilding (§1, §10):**
   `crossplane-claim-verify`, `wait-for-claim.sh`, `irsa_trust_validator.py --all`,
   `composition-render.sh`, `kube-diagnose.yml`. The plan correctly leans on
   what's proven. This keeps maintenance cost down — the persona's prime concern.

3. **Slow-vs-cheap split by cost (§2 key rule, §4):** L5 *never re-creates* the
   20-min EKS / multi-min RDS; verifies the one already built. This is the right
   cost/wall-clock answer to requirements 3 & 4 and must survive.

4. **No blind retries; flakes go to the open-issues register, not retry-til-green
   (§6).** Even though the consistency-budget implementation needs the M3 fix, the
   *principle* — never hide the failure class you're trying to surface — is
   correct and aligned with AGENTS.md §6.18/§6.24.

5. **Per-run-ID prefix + loud cleanup trap, no `|| true` (§6).** Directly honors
   AGENTS.md §6.19 and is the only way a real-cloud suite stays survivable on a
   shared ephemeral account. Preserve verbatim.

6. **The skip-register *concept* — disable must be a visible, expiring, reviewed
   diff (§3.2).** The implementation has gaps (C2, C3, M1's expiry friction) but
   the *idea* that disablement is a reviewed artifact, not an env var, is the
   right shape for requirement 2 and mirrors the existing kubeconform-skip
   discipline. Keep the concept; harden the enforcement.

7. **The blocker→layer coverage matrix (§7).** Even with the taxonomy collapse
   (M4), the discipline of mapping *each of the 8 real blockers* to a concrete
   catching layer is exactly the traceability AGENTS.md §6.4 demands. Preserve the
   matrix; just re-key it to the simpler 3-bucket taxonomy and fix the IRSA rows
   per C1.

8. **Running negative/precondition tests at all (§5).** "Cannot build a broken
   thing" is genuinely beyond static lint and is requirement 5. Keep it — but move
   the slow/mutating live negatives (M6) to the dedicated e2e job and lead with the
   fast L2 render-level assertions.

---

## Bottom line

The plan's *diagnosis* and *asset reuse* are excellent and must survive. Its
*central novel mechanism* (direct probe under the restricted IRSA role) is not
deliverable against this repo's `InjectedIdentity` provider config (C1) and
collapses into "use `crossplane-claim-verify` on a real claim." Its *enforcement*
of the no-silent-regression requirement depends on a workflow this session can't
ship and is sequenced last (C2), and its skip-guard makes near-all-skipped the
*normal* green state on the empty/rotated accounts this repo actually runs on
(C3). Fix those three and the maintenance-cost reductions (M1/M4 fewer artifacts,
M2 a local loop, M5 a real coupling tooth), and it becomes a suite engineers will
actually run instead of quietly disabling.
