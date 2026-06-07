# Adversarial Review of PLAN-C — Security & Least-Privilege / Negative-Test Lens

**Reviewer persona:** security & least-privilege adversary, negative-test stickler.
**Target:** `planning/test-overhaul/plans/PLAN-C-qa-live-systems.md` (read in full).
**Grounding checked in repo:** `terraform/management/irsa.tf` (the Crossplane AWS
provider policy), `tests/unit/test_iam_required_actions.sh`,
`tests/integration/run.sh` + `lib/test-lib.sh` (skip semantics),
`tests/integration/11_platform_secret_e2e.sh`, `.claude/skills/crossplane-claim-verify/SKILL.md`,
`scripts/wait-for-claim.sh`, chainsaw XRD `must-fail-at-admission` negatives.

---

## Executive judgment

PLAN-C correctly diagnoses the structural blind spot ("real cloud × restricted
identity") and the right primitives to reuse. But viewed from a least-privilege
and negative-rigor seat, it has a **load-bearing flaw it never names: testing
"the controller can do its job" under the real restricted role creates a
permission-bloat ratchet** — every time a positive T4 test sees `AccessDenied`,
the documented remedy is to *add a grant* (§8 row 1: "extend
`test_iam_required_actions.sh`"; §4.2 "missing IAM permission … surface here").
The plan has **no counterweight test that the role is not too broad**, and the
one negative-IAM idea it floats (§4.3, §8 row "negative IAM") is vague, ungated,
and not in the coverage matrix's failure→test mapping. Combined with a policy
that is *already* `eks:*` + `Resource="*"` on IAM/RDS/EC2 (verified in
`irsa.tf`), this plan as written will make the role broader and call it
"verified least-privilege." That is the central thing to fix.

Several negative/precondition tests also **assert the wrong thing** (absence of a
resource rather than the guard firing), and the anti-silent-regression machinery
has gaps that let "disabled/all-skipped" read green through paths the plan didn't
close.

---

## CRITICAL findings

### C1. Permission-bloat ratchet with no upper-bound test (§4.2, §8 rows 1–2, §9, §13.3)
The plan's positive T4 loop is: instantiate under the restricted role → if
`AccessDenied`, the gap is "missing IAM permission" → fix = add the action
(§8 row 1 "extend `test_iam_required_actions.sh`"). `test_iam_required_actions.sh`
today is a **completeness/allowlist** test — it asserts required actions are
*present*. Coupling T4 to it means every live failure pushes the policy strictly
wider, and the test then *locks the wider grant in* as "required." There is no
test that fails when the policy grows beyond what the workload demonstrably uses.

**How it bites THIS system:** `irsa.tf` already grants `eks:*` and account-wide
`Resource="*"` for IAM (`iam:CreateRole`, `DeleteRole`, `PassRole`,
`*OpenIDConnectProvider`), RDS, and EC2 — with comments explicitly rationalizing
account-wide scope ("identifiers are not known ahead of create"). A test suite
whose only IAM signal is "did the action succeed?" will green-light
`iam:*`/`Resource="*"` forever. The eight historical blockers were all
*under*-permissioned; a suite tuned only to catch those will systematically
over-correct. The Crossplane provider holding `iam:CreateRole`+`PassRole`
account-wide is a privilege-escalation primitive; nothing in the plan tests that
it *cannot* create a role outside the platform's naming/path scope.

**Fix:** Add a first-class **least-privilege upper-bound tier** (call it
T4-deny), gated equally with the positive T4:
1. A **permissions-diff test**: enumerate the actions the bundle's positive T4
   runs actually exercised (CloudTrail for the role's session during the run, or
   an access-analyzer "generate policy from CloudTrail" pass), and **fail when
   the granted policy contains actions never exercised** beyond an explicitly
   annotated allowlist. This makes `eks:*` cost something — each wildcard must be
   justified in-repo or the test goes red.
2. Convert `test_iam_required_actions.sh` to a **two-sided** contract: required
   actions present AND no action outside a reviewed set; wildcards
   (`eks:*`, `Resource:"*"`) require an inline `# lpe-justified:` annotation that
   the test parses, so widening is never silent.
3. The coverage matrix (§8) must add a row: "policy broader than exercised →
   caught by T4-deny," or it overclaims "least-privilege is real" (§4.3 makes
   that claim with no test behind it).

### C2. Negative IAM test is asserted as absence, not as a fired guard (§4.3 "Negative IAM", §8 row "negative IAM")
§4.3 says "Assert the controller *cannot* do things outside its scope." As
written this is the classic weak negative: it will pass if the action is denied
*or if the action simply doesn't apply / the resource doesn't exist / the call
errored for an unrelated reason*. An `AccessDenied` and a `NoSuchEntity` and a
network blip all look like "didn't succeed." The plan never specifies the
**assertion must be on the explicit deny** (`AccessDenied` / authorization
failure error code), not on generic non-success.

**How it bites:** A future over-broad grant (C1) would make a "must-be-denied"
call *succeed*, but if the test was lazily written to "expect non-2xx" it can
still pass for the wrong reason, or worse, a refactor that removes the call
entirely passes vacuously. This is exactly the "asserting a resource is absent
instead of proving the guard fired" failure my persona is told to hunt for.

**Fix:** Mandate in §4.3 and §10 that every negative IAM/admission test
**assert the specific deny signal** (error code = `AccessDenied`/`Forbidden`,
or a named admission-webhook rejection reason), captured verbatim, and that the
test **first proves the call is well-formed** (same call succeeds for an
in-scope target) so a deny-for-the-wrong-reason can't pass. Add a meta-test that
the negative test fails if you grant the permission (the §6.2 "run red against
unfixed code" discipline, applied to negatives).

### C3. Keycloak DB health-gate proves "not ready," not "the gate fired" (§4.3 precondition, §8 row 8)
The brief's marquee precondition is "Keycloak must not start without its DB."
§4.3 route (b) "withhold the DB and assert non-readiness" is **under-specified in
a way that lets it pass for the wrong reason.** A pod that is `NotReady` because
its *image is still pulling*, because the namespace has no quota, or because an
unrelated initContainer failed, satisfies "stays NotReady" — without the DB-gate
existing at all. Asserting "deployment is not Ready" does **not** prove the
health gate is what's holding it.

**How it bites:** Someone deletes the DB-dependency check from the Helm chart;
the pod still crash-loops on first DB connection attempt eventually, but maybe
not within the test window, or it comes up `Ready` against a stale/cached
connection and serves an unauthenticated error page. The test as specified can't
tell "fails closed because the gate fired" from "fails for incidental reasons"
from "actually came up degraded."

**Fix:** Split into two assertions, both required:
(1) **Positive control:** with the DB present, the workload reaches `Ready`
   within budget (proves the test harness can detect readiness at all).
(2) **Gate-fired assertion:** with the DB withheld, assert the **specific
   failure reason** — the readiness/startup probe's named failure, or the
   admission policy's named rejection (route (a)), captured verbatim — *and*
   assert the service does **not** serve traffic (a request returns the
   fails-closed response, not a 200). Prefer §4.3 route (a) (Kyverno admit-gate)
   as the *gating* signal because it is deterministic and names its own reason;
   route (b) is the corroborating runtime proof. The plan's open question #4
   leaves "which gates 'verified'" unanswered — answer it: the admission gate
   gates; the runtime test corroborates. Leaving it open means it may ship as the
   weak "is NotReady" form.

### C4. `disabled` / `all-skipped` can still read green through paths the plan leaves open (§3.2, §3.1 step 5)
The plan's three guards are good but have holes my persona must flag, because the
brief makes "disabled/all-skipped must never read green" a hard requirement:
- **`exit 0` is the current per-test skip behavior.** `tests/integration/lib/test-lib.sh`
  `skip()` does `exit 0`; `run.sh` counts skips but **`exit 0` even if every test
  skipped** (verified). The plan inherits this orchestrator shape (§3.1 "mirroring
  `tests/integration/run.sh`"). Unless §3.2 guard 2's skip-budget is wired as the
  *default and non-zero-floor* (any phase-claimed resource skipped ⇒ non-zero),
  the bundle ships with the same all-green-on-all-skip bug it's trying to kill.
- **Precondition step doubles as a skip launderer (§3.1 step 1, §7).** The plan
  says a rotated account fails "as a precondition … never as a code failure." A
  precondition *abort* must **not** exit 0 and must **not** count as "bundle ran."
  If `LIVE_BUNDLE=enabled` but preconditions abort, the phase's "verified" state
  must be **unset/failed**, not silently skipped-green. The plan tags it
  `ENVIRONMENT` (§10) but never says the overall phase result is non-green.
- **Coverage manifest is the anti-rot guard but is hand-maintainable (open Q #3).**
  If the manifest is hand-written and `test_live_coverage` only checks
  manifest↔test consistency (not manifest↔reality), an attacker/forgetful author
  drops a resource from the manifest and the "uncovered resource" goes invisible.
  The plan flags the source-of-truth question but ships Phase A on the permissive
  hand-maintained version.

**Fix:** (a) State explicitly that `tests/live/run.sh` returns **non-zero when
any phase-declared resource is SKIP**, and add a unit test for that orchestrator
rule (the gate-matrix testing of §11 must cover "all-skip ⇒ red" and
"precondition-abort ⇒ red/unset, not green"). (b) Make the coverage manifest
cross-check derive the *expected* set from Terraform plan JSON + Composition
`resources[]` (open Q #3) as a **blocking** part of Phase E, not perpetually
permissive — a manifest that can be edited to hide a resource is not a guard.

---

## MAJOR findings

### M1. Bad-param negative tests duplicate existing chainsaw negatives without raising the bar (§4.3 bad-param, §8 row 3)
Chainsaw already has `must fail at admission` negatives for XRDs
(`platform-cluster/00-xrd-establishes`, `xdatabase/00-xrd-establishes` —
"value must fail kubectl-apply at admission time, not silently";
"omitting it must fail at admission"). §4.3's bad-param T4-negatives risk
re-implementing these one tier up (live, real cloud) at real cost, for the
*same* contracts, while missing the cases chainsaw structurally **cannot** see:
params that are schema-valid but **policy/semantically** invalid (a name that is
valid RFC-1123 but violates the IRSA principal contract — failure #4;
an instance type that passes XRD validation but is outside the account
whitelist — admission/Kyverno, not schema). 

**Fix:** Scope §4.3 bad-param T4 to **only** the negatives that require the live
cloud/identity to falsify (principal-contract names, account-whitelist
enforcement, cross-field semantic constraints). Schema-shape negatives stay in
chainsaw (cheap, hermetic). Cite §15 to explicitly *not* duplicate chainsaw
admission negatives at T4. Otherwise the plan burns ephemeral-account cost
re-proving what kind already proves.

### M2. Missing negative cases my persona expects — admission/RBAC bypass and secret exposure (whole plan)
The negative catalog (§4.3, §8) covers bad-param, precondition, and negative-IAM.
It **omits** three classes that are squarely in scope for a least-privilege
adversary and directly implicated by the system's design:
- **Admission/RBAC bypass:** can a workload in a spoke-tenant namespace create a
  claim that provisions cloud resources it shouldn't (privilege escalation via
  the platform abstraction)? The `platform-spoke AppProject` / IngressClass
  blocker (CONTEXT) shows cluster-scoped resources cross AppProject boundaries;
  there is no T4-negative that a tenant *cannot* instantiate an XRD outside its
  allowed set, nor that Kyverno `Enforce` (not just Audit) blocks it. Note
  `policies/audit/*` is **Audit** mode (verified in test 11's comment: "If the
  policy were Enforce…") — so the namespace-allowlist guard the plan leans on may
  not actually *block* anything. The plan must test the guard's **mode**.
- **Secret exposure surface from T4 itself (the brief's own question).** §4.2
  PlatformSecret T4 "put value → ESO materializes." The plan never says the
  test value is a **non-sensitive marker** and that the K8s Secret / ASM secret /
  pod logs / run logs are asserted **not** to leak the value into the PR summary
  comment (§10 publishes a lot). `wait-for-claim.sh` auto-dumps conditions+events
  on failure (verified) and the plan extends auto-dump to "the failing resource's
  `describe` … inline in the run log" (§10) — a Secret/ESO failure dump can spill
  secret material into CI logs. This is a real new attack surface the plan
  introduces and does not mitigate.
- **The restricted role's own credential leak (§9).** Routes "assume-role into
  the restricted role ARN" and "run as the controller SA" both put usable
  controller credentials into a CI/job context. The plan never addresses session
  scoping, duration, or that the assumed-role session must not be logged.

**Fix:** Add to §4.3/§8: (a) a tenant-isolation T4-negative (claim outside
allowed XRD set is **rejected by an Enforce policy**, asserting the named
rejection — and a separate test that the relevant `policies/` are Enforce, not
Audit, where blocking is required); (b) a logging-hygiene rule in §10 that T4
secret tests use synthetic markers and that all auto-dumps run through a
**redactor** for `data:`/`SecretString`/`Authorization` before they reach the PR
comment or run log; (c) §9 must specify minimal session duration + no-echo for
assumed credentials.

### M3. T2 (restricted creds against the stub) is acknowledged as possibly-false-comfort but still in the plan (§2, §9, open Q #2)
From my seat this is worse than the plan admits. A stub that returns success for
calls the *real* IAM would deny gives you a **green negative test that proves
nothing** — the most dangerous artifact in a security suite, because it reads as
coverage. The plan rightly flags the open question but keeps T2 in the taxonomy
and rollout as a "fast pre-filter."

**Fix:** Make T2 **conditional on a one-time fidelity proof**: before T2 is
allowed to count toward coverage, demonstrate the stub denies at least one known
out-of-policy action that the real role denies (a calibration test). If the stub
can't be made to honor a restricted policy, T2 is deleted, not shipped as
"low-fidelity." A security pre-filter that can't deny is not a pre-filter.

### M4. Cleanup-as-assertion can mask a leak as a "code" failure, and the orphan sweeper is itself privileged (§6)
§6 makes cleanup a tested assertion (good) and bans `|| true` (good, matches
AGENTS.md §6.19). But the **orphan sweeper** (§6, "deletes any
`test.k8-platform/live=true` resources older than N hours") is a broad
delete-by-tag actor. On a shared/ephemeral account, a label collision or a
mistagged production-ish resource means the sweeper deletes real things. The plan
gives the sweeper destructive power with only a label as a guard and defers
completeness to a `[K8S-SPECIALIST]`.

**Fix:** Sweeper must (a) be scoped to a dedicated test resource-prefix AND the
live label AND an age floor, all three required; (b) dry-run + emit the
to-be-deleted set to the run log before deleting; (c) never run against an
account whose `sts get-caller-identity` isn't the expected ephemeral test
account (precondition reuse from §3.1). A delete-by-single-tag sweeper is a
foot-gun on an account that also hosts the mgmt cluster.

### M5. Coverage matrix (§8) overclaims for #1, #3, #4 (§8 table)
- Row 1 claims T4 catches "missing IAM permissions … *at authoring time*." It
  does **not** — T4 is a *live* tier that runs on bring-up, not on push. Only the
  coverage-manifest unit test runs at authoring time, and it catches "no test
  exists," not "permission missing." The matrix conflates "authoring-time guard
  added" with "the live test." This overclaim matters: a reader believes a push
  will catch a missing grant; it won't until a live bring-up runs.
- Row 3 ("safe value is required") is a real authoring-time unit assertion —
  fine — but the *live* half ("trust path resolves") is what actually catches the
  blocked-trust-mechanism class, and that's bring-up-time only.
- Row 4's "live action succeeds" proves the name matches; it does **not** prove
  the name is *exclusively* correct (an over-broad trust policy could let the
  wrong principal also succeed). Pair with a negative (the wrong principal is
  denied) or the row overclaims.

**Fix:** Split the §8 matrix's "Tier" and "Authoring-time guard" columns honestly
— state for each row what is caught on *push* vs. on *bring-up*, and add the
paired negatives (C2/M5 row 4).

---

## MINOR findings

### m1. "Read-only `Describe*` with admin key for T3" (§13.3) widens the CI key's blast radius
The plan assumes the admin CI key does all T3 reads. That keeps a broad admin
credential in CI. Prefer a dedicated read-only verifier role for T3; at minimum
note that the admin key is a standing risk and should be the *narrowest* key that
can `Describe*` the resource set, not literal admin.

### m2. Skip-budget threshold + grace window left as open Q #6 — that's the exact knob that becomes the silent-green loophole
A tunable skip budget with a grace window is where "temporarily allow skips"
becomes permanent. Specify the floor now: **zero skips tolerated for any resource
the phase declares it built**; the budget only applies to genuinely-absent
optional components, and each tolerated skip needs a `docs/open-issues.md` entry
(reuse §7's quarantine discipline). Don't ship the knob without the floor.

### m3. Quota fail-closed (§5.2) is good but uses the broad key to query quota
Querying remaining EC2 quota and refusing to over-provision is correct. Ensure
the quota check itself fails closed if the *quota API call* is denied/errors —
otherwise a permissions gap on `servicequotas:Get*` silently disables the
guardrail (the same silent-no-op class as failure #4).

### m4. Idempotency double-run lane (§6, §12 Phase F) should include a negative double-apply
Re-running the bundle proves create-if-absent. Add: applying the *same* claim
twice must not silently create two cloud resources (or must be rejected) — a
real-cloud idempotency bug that the hermetic tiers can't see.

### m5. PR summary comment publishes coverage delta + switch state (§10) — ensure it can't be the leak vector for M2(b)
Tie-in to M2: the summary comment is the most-public artifact; it must be the
*last* place any T4 secret/credential material could appear. Add an explicit
"summary comment is redacted-only" rule.

---

## What the plan got RIGHT — the synthesis MUST preserve these

1. **The core diagnosis and the "real cloud × restricted identity" cell as THE
   gap (§0, §2).** This is correct and is the whole point; do not let synthesis
   dilute it back toward better mocks (§15 already guards this — keep it).
2. **Restricted identity is non-negotiable for T4; admin hid #1–#4 (§9).** Keep
   the in-cluster verifier-job-as-the-controller-SA as the *preferred*
   mechanism — it is the only one with production-identical credential path.
3. **On-by-default + reason-required disable + skip accounting + coverage-manifest
   unit test (§3.2).** The three-guard structure is the right shape for
   "never reads green when disabled" — it just needs the holes in C4 closed.
4. **Reuse of `wait-for-claim.sh` as the single canonical wait, ban on bespoke
   `grep True` loops, ban on `|| true` cleanup masking (§6, §7).** Aligns with
   AGENTS.md §6.19/§6.24; preserve verbatim.
5. **Slow resources after-the-fact only; never recreate a cluster/DB per test
   (§4.1, §5).** Correct cost posture for an ephemeral account; preserve.
6. **Negative/precondition testing treated as first-class, not an afterthought
   (§4.3).** The *intent* is right; my findings sharpen the *assertions*, they do
   not remove the tier.
7. **Coverage as a unit-tested invariant so absence-of-a-test is CI-red (§3.2
   guard 3).** Strongest anti-rot idea in the plan — preserve and strengthen
   (C4) by deriving the expected set from Terraform/Composition, not hand-list.
8. **Auto-dump + environment-vs-code disambiguation up front (§10, §3.1 step 1).**
   Keep — with the M2(b) redaction layer added so the dump can't leak secrets.

---

## The single most important thing

**Add a least-privilege upper-bound tier (C1) and make every negative assert the
specific deny signal (C2/C3).** Without it, this plan's positive-only,
add-a-grant-on-AccessDenied loop will steadily widen an already-`eks:*`/`Resource:"*"`
Crossplane role and stamp it "verified least-privilege" — turning a test overhaul
into a privilege-creep engine. The negatives must prove the *guard fired*, not
that a resource is absent.
