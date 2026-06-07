# Round-2 Adversarial Review — Security & Least-Privilege / Negative-Test Rigor

**Target:** `planning/test-overhaul/synthesis/SYNTHESIZED-PLAN.md`
**Reviewer persona:** least-privilege adversary + negative-test stickler.
**Method:** read the synthesized plan cold and end-to-end, then ground every
load-bearing claim against the live repo (irsa.tf, the integration/chainsaw
orchestrators, the claim-verify skill, the Kyverno bundle, the dump helper, the
existing IAM-completeness test). Findings ranked Critical / Major / Minor.

---

## 0. What the plan got right (verified, so I don't re-litigate it)

These are real resolutions of round-1 criticals, confirmed against the repo —
finalization must NOT weaken any of them:

- **The "no probe SA" decision is correct and grounded.** `irsa.tf:171-175`
  trusts exactly `crossplane-system:upbound-provider-family-aws`. A probe pod
  genuinely cannot `AssumeRoleWithWebIdentity` into the Crossplane role; the
  plan's §2.1 NON-GOAL (no new principal, no trust widening, no token
  mount/copy) is the single most important security property in the document.
  **This is the thing finalization must not lose.**
- **The IRSA-negative-via-live-role-mutation rejection is correct.** Every
  blocker action (`iam:UpdateAssumeRolePolicy`, `iam:GetRolePolicy`,
  `iam:TagOpenIDConnectProvider`, the `rds:*` set) is already granted —
  verified at `irsa.tf:73-104`. You cannot produce a live AccessDenied without
  revoking-mid-test or a crippled twin; the plan rejects both (§2.3, §13). Good.
- **The Audit-mode finding is real.** All 12 policies under `policies/audit/`
  are `validationFailureAction: Audit`, including the security-relevant ones —
  `04-irsa-rolearn-format`, `10-spoke-no-cluster-admin-binding`,
  `11-appproject-no-wildcard-sourcerepos`. The plan's "an Audit policy guard
  blocks nothing; assert Enforce + failurePolicy:Fail" (§6) is correct and
  load-bearing.
- **The skip-reads-green diagnosis is real.** `tests/integration/run.sh:40-45`
  exits 0 whenever `FAIL==0`; rc=2 is a counted SKIP (line 28). On an env-absent
  / hub-only run everything skips and the suite is green. The §3 inverted-skip
  / executed-floor mechanism targets exactly this.
- **The ASM-tag-mismatch finding is real.** `tests/chainsaw/run.sh:76` documents
  the Composition tags secrets `k8-platform/<XR-uid>`, not `ASM_RUN_PREFIX`. The
  plan's "enumerate by the tag the controller actually applies, key teardown off
  the run-id on the XR name" (§7.2) is correct.
- **The IAM-completeness test is floor-only and wildcard-permissive.**
  `test_iam_required_actions.sh:62-78` *accepts* `service:*` (line 71) and
  prefix wildcards. The plan's "convert to a two-sided floor+ceiling contract"
  (§4.1) is accurate about the gap, and the test header's `route53:*` exemption
  the plan calls out does exist in spirit (the wildcard-acceptance is the
  exemption).
- **The secret-leak vector is correctly located.** The dump helper
  `k8s_dump_claim_timeout` (`scripts/_lib/k8s-helpers.sh:87-143`) dumps only
  conditions + events — it does NOT decode secret data, so it is *safer* than
  the plan implies. The real leak is `crossplane-claim-verify`'s
  `cloud-verification.md:46` (`jsonpath='{.data}' | jq 'map_values(@base64d)'`)
  and `:51` (`--query SecretString --output text`), plus `SKILL.md:100-101`.
  The plan's §7.3 synthetic-value + redaction-filter rule targets the right
  artifact.

The center of the plan holds. My findings are about **new seams the merge
opened**, **resolutions that are asserted but not actually closed**, and
**missing negatives my persona cares about**.

---

## CRITICAL

### C1 — The ceiling lint is defeated by the policy it must constrain: `eks:*` is in the floor fixture AND is a wildcard the ceiling must ban. The plan never resolves this contradiction.

§4.1 says the converted `test_iam_required_actions.sh` must assert "no action
outside a reviewed set (ceiling)" and "fails on broad wildcards … `service:*`
for high-risk `iam:*`/`rds:*`." But the live policy's **first statement is
`eks:*` on `Resource:"*"`** (`irsa.tf:42-45`). The blocker matrix row #1/#5 and
§2.3 simultaneously *depend* on EKS/RDS actions being effective. So the ceiling
lint has to either:
- ban `eks:*` (then the floor for EKS create-path — which the plan says
  `simulate-principal-policy` covers — has nothing to point at, and the EKS
  composition's real needs aren't enumerated anywhere), or
- annotate `eks:*` as `# lpe-justified:` — at which point the single most
  privilege-bloated grant in the whole policy becomes "reviewed least-privilege"
  by a one-line comment, which is **precisely the rubber-stamp the ratchet
  section (§4) exists to prevent.**

The plan waves at this with "each wildcard requires an inline `# lpe-justified:`
annotation" but never confronts that `eks:*` + account-wide `Resource:"*"` on
IAM/RDS/EC2 is the *starting state*, so the ceiling lint as specified will
either (a) be all-annotations-on-day-one (vacuous) or (b) red on the committed
HEAD with no path to green except annotation. A ceiling that is satisfied by
annotating every existing wildcard is not a ceiling.

**Fix (must be in finalization):**
1. The ceiling lint must **enumerate the exact `eks:`/`rds:`/`iam:` verbs the
   Compositions actually call** (derive from `crossplane/**` MR kinds +
   `forProvider`/`managementPolicies` usage, the same derivation §3.5 already
   mandates) and assert the policy is **scoped to that set** — i.e. the fix is
   to *narrow `eks:*` to the real verb list*, not to annotate it.
2. `# lpe-justified:` annotations must carry a **mandatory `OI-` or ADR
   cross-link AND an expiry** (mirror the SKIP_REGISTER discipline in §3.4),
   and the lint must **cap the number of annotated wildcards** (e.g. fail if >K)
   so "annotate everything" is mechanically impossible.
3. The "un-exercised grant" tier (§4.2) must run against `eks:*`/`rds:*`
   specifically — it is the only mechanism that makes the existing wildcards
   *cost something*. As written §4.2 is deferred to "CloudTrail/access-analyzer
   latency" residual-risk #5 with no commitment, so the only enforced
   counterweight is the annotation — see C1.2 above. **At least one of {narrow
   the wildcard, un-exercised-grant tier} must be a P1/P-non-deferred
   deliverable**, or the ratchet is unbounded in practice.

Without this, the merged plan's net effect on day one is: a suite that catches
*under*-permissioning (the blockers) with zero enforced brake on
*over*-permissioning — the exact asymmetry my persona warned produces "verified
least-privilege" `iam:*`.

### C2 — `simulate-principal-policy` is sold as the honest completeness oracle for IRSA blockers, but the plan never proves the simulation can *see a Deny that would actually fire* — and it silently inherits a new privilege requirement.

§2.3 / §4.3 lean on `aws iam simulate-principal-policy` against the real
Crossplane role as the push-time catcher for blockers #2-#5,#8 and the matrix's
"throughline." Two unaddressed problems:

1. **Fidelity is asserted, never calibrated.** `simulate-principal-policy`
   evaluates identity-policy + (optionally) resource-policy/SCP/boundary inputs
   *you pass in*. By default it does **not** pull live SCPs or
   permission-boundaries, and it cannot see a resource-policy it isn't given.
   The plan even acknowledges this in §4.3 ("an explicit Deny / SCP /
   permissions-boundary elsewhere can negate a present Allow, which a grep
   cannot see") — but then uses simulate as if it *does* see them. For the
   ephemeral test account there may be no SCPs today, but the plan ships a
   permanent gate whose green means "the role's *own* policy allows X," which is
   **the same thing the grep-based floor already proves** — it does not add the
   "effective for this principal" property the plan claims unless it's run with
   the live boundary/SCP context attached. This is a **coverage overclaim**: the
   matrix bills simulate as the faithful catcher for the IRSA blocker class, but
   without a contextual-deny calibration it's a fancier `test_iam_required_actions`.

   **Fix:** add a **one-time fidelity calibration** (mirroring the §13 T2
   rejection's own standard): inject a *known* explicit-Deny / boundary into the
   simulate call and assert simulate returns `explicitDeny`/`implicitDeny`. If
   it can't be made to reflect a real deny, the matrix must downgrade simulate
   from "faithfully caught" to "policy-text floor (does not prove effective)"
   and the only faithful catcher remains the live controller positive — which is
   bring-up-time, not push-time, weakening the "caught at push time" column for
   #2-#5.

2. **New privilege requirement, unenumerated.** `simulate-principal-policy`
   requires `iam:SimulatePrincipalPolicy` on the *calling* identity (the §14.8
   read-only CI verifier role the plan wants to narrow). Likewise §2.2 needs
   CloudTrail read (`cloudtrail:LookupEvents`), §4.2 needs CloudTrail or
   `accessanalyzer:*`, §7.1 quota needs `servicequotas:Get*`, §7.2 reaper needs
   `resourcegroupstaggingapi:GetResources` + delete perms across services.
   **None of these are enumerated**, and §14.8 simultaneously asks for "the
   narrowest-possible read-only verifier role." You cannot both narrow the
   verifier role AND silently require simulate/CloudTrail/access-analyzer/quota/
   tagging-API reads on it. Today it works only because the CI key is admin —
   which is the §0 anti-pattern (more privilege than prod) the plan is trying to
   retire.

   **Fix:** the plan must ship an **explicit allowlist of the verifier
   identity's required read actions** as a first-class artifact (it's a
   least-privilege deliverable, not an afterthought), and the ceiling lint
   (C1) must cover *that* role too — otherwise the overhaul hardens Crossplane's
   role while leaving an admin CI key as the real, unconstrained blast radius.
   This is the meta-irony my persona must flag: **the test infrastructure
   becomes the most over-privileged principal in the system.**

### C3 — The "guard fired" rule is stated but two of the highest-value negatives still can't distinguish guard-fired from environment-broken, and the meta-test that would prove it is optional.

§6's rule ("assert the specific cause + a positive control in the same fixture")
is exactly right and resolves the round-1 "proves absence not guard" critical
*in principle*. But the merge left two concrete contracts that violate the rule
the section itself sets:

1. **The Keycloak-without-DB primary gate is a Kyverno admit-gate that doesn't
   exist yet** (§6, P5). The plan makes the *primary* precondition proof a
   "scoped Kyverno admit-gate (Enforce)" — but every Kyverno policy in the repo
   is Audit (verified), and an Enforce admission policy that gates Keycloak on
   DB-presence is **net-new attack surface**: §6/§sre-C M4 correctly flag that a
   mis-scoped cluster-wide Enforce gate is a self-inflicted outage. The plan
   requires "its own negative proving it does not block healthy real workloads"
   — good — but it does **not** require proving the gate is **fail-open on
   Kyverno-unavailable** vs **fail-closed on DB-absent**. A `failurePolicy:Fail`
   webhook (which §6 mandates for Enforce!) means **Kyverno being down blocks
   ALL matching admissions** — turning a DB blip-adjacent policy into a
   cluster-wide deploy freeze. The plan demands `failurePolicy:Fail`
   *generally* (§6 IRSA-SA policy) without scoping that mandate away from the
   DB-gate, where Fail is dangerous.

   **Fix:** split the `failurePolicy` mandate: security-invariant policies
   (IRSA-SA-carries-role-arn, tenant-isolation) get `Fail`; the
   availability-adjacent DB-precondition gate gets `Ignore` + a separate
   detective check, OR is **not** an admission gate at all (use the
   init-container `wait-for-db` gate the plan lists as the *alternative* as the
   primary, since it's app-local and can't freeze the cluster). My persona will
   not accept "add an Enforce webhook with failurePolicy:Fail" as a precondition
   test when it imports a larger outage surface than the bug it guards.

2. **The meta-test (red-first on every negative) is described (§6 last bullet)
   but not made a gate.** "Each negative must FAIL if you grant the permission /
   remove the guard" is the *only* thing that distinguishes a real guard-fired
   negative from one that passes against a broken environment. AGENTS §6.2
   mandates red-first for bug fixes; the plan invokes it but does **not** wire a
   mechanical check that every test tagged `negative` has a recorded red-first
   artifact. Without that, "assert the specific reason" degrades over time into
   "assert some failure" — exactly the round-1 critical, re-entering through
   maintenance drift.

   **Fix:** the coverage-mapping test (§3.5) must additionally require every
   `negative`/`precondition` test to reference a **committed red-first evidence
   artifact** (the recorded failure against the guard-removed fixture), and fail
   the push if absent. Make the meta-test a gate, not a guideline.

---

## MAJOR

### M1 — Tenant-isolation and RBAC-bypass negatives are listed but un-budgeted, and depend on Enforce policies that don't exist — so the matrix can claim them while they're unshippable in the default bundle.

§6 adds "tenant-isolation (a spoke-tenant namespace cannot instantiate an XRD
outside its allowed set, blocked by an *Enforce* policy)" and "AppProject
deny-by-default" and "IRSA confused-deputy family." These are the right
negatives and my persona explicitly wanted them. But:
- They all require **Enforce** policies the repo doesn't have (it's all Audit),
  so they are gated behind the same risky Audit→Enforce flip as C3.
- They land in **P5** (last behavioral phase) while the matrix (§10) and §0
  philosophy present tenant-isolation as a covered contract. A contract that's
  real only in P5 should not read as covered earlier.

**Fix:** Either (a) ship the tenant-isolation / AppProject deny negatives as
**RBAC/AppProject-level enforcement** (which is already deny-by-default by
construction — an AppProject's `clusterResourceWhitelist`/`namespaceResourceWhitelist`
genuinely rejects, no Kyverno needed) so they don't depend on the Audit→Enforce
flip, or (b) explicitly mark them "not-yet-covered until P5" in the matrix so
the acceptance criterion doesn't overclaim. Prefer (a): the AppProject is the
*real* enforcement boundary for "a tenant can't instantiate an out-of-scope
XRD"; Kyverno is belt-and-suspenders. The plan should lead with the RBAC/AppProject
proof and treat the Enforce-Kyverno version as the redundant second layer.

### M2 — The reaper "runs FIRST and refuses unless the account is the expected ephemeral account" is good, but its delete scope can still nuke the mgmt cluster, and the safety predicate is under-specified.

§7.2: reaper deletes by "pinned label + run-id prefix + age floor (all three
required)" and "refuses to run unless `sts get-caller-identity` is the expected
ephemeral account." Two gaps my persona cares about:
1. **"Expected ephemeral account" has no definition** that survives §8.1
   (account IDs are ephemeral, must not be hardcoded). So the predicate is
   either hardcoded (violates §8.1) or "any account the CI key points at"
   (vacuous — the mgmt cluster lives on that same account). The plan needs a
   **positive allowlist signal that is itself ephemeral-safe** — e.g. a tag the
   bootstrap writes (`Environment=ephemeral-test`) that the reaper requires on
   the account/cluster, NOT the account ID.
2. **Run-id prefix + label + age** still matches a *legitimate in-flight
   concurrent run's* young resources only by the age floor; but a paused/suspended
   run (common per AGENTS §6.20) whose resources are now "old" will be reaped by
   a *different* run. The concurrency mutex (§7.1) is the intended guard but the
   plan doesn't state the reaper respects the active-run-id lease. **The reaper
   must skip run-ids present in the active-lease ConfigMap**, else a resumed run
   finds its resources reaped mid-flight (a self-inflicted false AccessDenied /
   NotFound that the §7.4 classifier may misread).

**Fix:** define "expected account" as a bootstrap-written tag, not an ID; make
the reaper consult the active-run lease and exclude live run-ids; keep dry-run +
emit-set + the three-predicate AND as specified.

### M3 — The "identity Crossplane actually used == expected IRSA role ARN" assertion (§2.2) is the falsifiability linchpin, and its two proposed sources are both weak; the plan half-admits this in residual-risk #1 but still builds P4 on it.

§2.2.2 wants the caller identity captured "from CloudTrail `userIdentity.arn`,
or from `aws sts get-caller-identity` run by a pod using the provider SA."
- CloudTrail has 5-15 min latency (residual-risk #1 admits flaky/slow) — too
  slow for an in-bundle gate.
- "a pod using the provider SA running `get-caller-identity`" is **the probe-SA
  pattern the plan banned in §2.1** wearing a hat: to make that pod assume the
  role you either (a) schedule it as the *actual* provider SA (then you're not
  measuring your test's identity, and you're co-tenanting a test workload on the
  provider's SA — a privilege/blast-radius problem), or (b) you can't, because
  the trust subject won't match. The plan's two sources are "too slow" and
  "the banned thing."

This means the strongest falsifiability claim — "we proved it ran as the IRSA
role, not the admin principal" — rests on CloudTrail-after-the-fact, and §2.2.1
(no static-cred ProviderConfig, no `AWS_ACCESS_KEY_ID` in the provider pod) is
actually the **load-bearing, reliable** assertion. The plan should **promote
§2.2.1 to the primary identity proof** (it's deterministic, push-or-bring-up
checkable, and directly catches the "reuse run.sh's admin-cred ProviderConfig"
low-friction wrong path) and **demote the ARN-match to a corroborating
after-the-fact CloudTrail lane** with an explicit "not a gate" label. As written
the plan lists them as co-equal "assert all of," which will either flake (gate
on CloudTrail) or quietly drop to the weaker check without saying so.

### M4 — external-dns negative still can't fire on the real blocker class without the banned mechanism, and the plan's "named auth error" source is unspecified.

§6 external-dns: "the real assertion is the named auth error on a subject/aud
mismatch." Blocker #8 was the external-dns **SA name ≠ trust subject**. To
produce a *named* `AccessDenied`/`AssumeRoleWithWebIdentity` failure you must
run external-dns (or something) under the mismatched SA — which is fine for
external-dns (its trust policy is its own, not Crossplane's), but the plan
doesn't say *where* the named error is read from. external-dns logs the assume
failure to its **pod logs**, not to a k8s object status, so the assertion is a
log-grep — fragile and version-dependent. The robust catcher is
`scripts/irsa_trust_validator.py --all == 0 MISMATCH` (matrix #8 PRE-FLIGHT,
exists) which is **static** and the actual day-one defense.

**Fix:** make `irsa_trust_validator.py` the **primary** #8 catcher (it directly
compares SA name vs trust subject — the exact blocker shape — with no live
assume), and treat the live "record appears / named auth error" as the
corroborating bring-up positive only. The plan already lists the validator but
ranks the brittle named-log-error as "the real assertion"; invert that.

---

## MINOR

### m1 — The `expect-full` floor's correctness is the whole anti-silent-regression story (residual #4) but is driven by the bring-up self-declaring its phase; a single negative test (declare expect-full, delete the resource, assert FAIL) is mentioned in §3.3 but not pinned to a file in the matrix. Pin it; it's the test that guards the guard.

### m2 — §7.3 "BRING-UP IAM/OIDC fixtures must be least-privilege; reject a probe role whose trust lacks both `sub` and `aud` StringEquals or uses `Principal:"*"`" is excellent and exactly my persona's ask — but it has no home in the phase plan or the coverage map. Add it as a unit lint over test fixtures (it's static and cheap), not just prose.

### m3 — The redaction filter (§7.3) strips `data:`/`stringData:`/`SecretString`/`Authorization`. ASM ARNs, OIDC issuer URLs, and IRSA role ARNs (all account-identifying per §8.1) are not in the strip list. They're not credentials, but the PR summary is "the most-public artifact" and account-scoped ARNs leaking there is a (minor) recon aid. Add account-id/ARN masking to the PR-summary path specifically.

### m4 — §6 says EKS `CONFIG_MAP`-only config "rejected at author time" (blocker #1 negative). Kyverno can't see EKS authnMode (the plan correctly says so for the AWS-side). The author-time rejection must therefore be a **TF/XRD lint** (assert the composition/module sets `API_AND_CONFIG_MAP`), and `test_eks_module_defaults.sh` exists as the natural home — name it in the matrix so this doesn't become an orphaned aspiration.

### m5 — §13 rejects T2 (restricted creds vs chainsaw stub) "unless a one-time fidelity calibration proves the stub denies a known out-of-policy action." Good standard — but the plan applies that fidelity-calibration rigor to T2 and **not** to `simulate-principal-policy` (C2.1), which gets the same "does this oracle actually deny?" doubt and a free pass. Apply the T2 standard to simulate.

---

## What finalization must NOT weaken (ranked)

1. **The §2.1 NON-GOAL** — no new AssumeRole principal, no trust-policy
   widening, no provider-SA token mount/copy. This is the security spine. Any
   "make the identity assertion easier" edit that reaches for a probe SA
   re-opens the exact bloat the overhaul exists to catch.
2. **A real, enforced brake on over-permissioning** (C1) — the floor without a
   working ceiling makes the suite a one-directional grant ratchet. Finalization
   must keep at least one mechanism that makes `eks:*`/`rds:*`/`iam:*` wildcards
   *cost something* and is not satisfiable by annotation.
3. **Guard-fired negatives with a mechanical red-first gate** (C3.2) and a
   positive control in the same fixture — never let a negative degrade to
   "asserts some failure."
4. **The executed-floor / `expect-full` promotion of skip→FAIL** — the only
   thing standing between this plan and the status-quo "skips read green."
5. **Synthetic-secret-only + redaction on the claim-verify decode path** — the
   one concrete plaintext-spill vector in the repo.

## The one new systemic flaw the merge introduced

The plan hardens the **Crossplane** identity beautifully and then quietly hands
the **test/verifier identity** an unbounded, unenumerated, admin-backed
permission set (simulate, CloudTrail, access-analyzer, quotas, tagging-API,
cross-service deletes for the reaper) while *also* asking for a "narrowest
read-only verifier role" (§14.8). Finalization must produce an **explicit,
ceiling-linted allowlist for the verifier/reaper identity** — otherwise the
overhaul's net least-privilege effect is to move the over-privileged principal
from Crossplane (now tested) to the CI key (now the biggest unchecked blast
radius on the account that also hosts the management cluster).
