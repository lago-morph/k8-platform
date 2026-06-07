# Adversarial Review — PLAN-A (Claude lead)

**Reviewer persona:** security & least-privilege adversary + negative-test stickler.
**Scope:** `planning/test-overhaul/plans/PLAN-A-claude-lead.md`, read in full. Repo
skimmed for grounding (`tests/chainsaw/run.sh`, `tests/unit/test_iam_required_actions.sh`,
`tests/unit/test_chainsaw_realaws_gated.sh`, `.claude/skills/crossplane-claim-verify/SKILL.md`,
`scripts/wait-for-claim.sh`, `.github/workflows/chainsaw.yml`).

The plan's diagnosis is correct and important: I verified the central claim against the
code. `tests/chainsaw/run.sh` lines ~231-293 build a Crossplane `ClusterProviderConfig`
whose `credentials.source: Secret` points at a k8s secret populated from
`secrets.AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — i.e. the **account-admin GitHub
Actions keys**, not the restricted Crossplane IRSA role. So every chainsaw provisioning
test today runs with strictly more privilege than production. That is exactly the hole
that hid the auto-012 IAM blockers. The plan names this. Good.

But the plan is a strategy sketch, and from my persona it is dangerously optimistic in
several load-bearing places. Findings below, ranked.

---

## CRITICAL

### C1. "Run under the real IRSA role" is asserted but never mechanized — and the easy path silently keeps admin creds
**Plan §1 L2, §2, §5 (the IAM row), §6.** The entire value proposition rests on Crossplane
reconciling under the restricted IRSA role. But the plan never says **how** a test forces
that. Today's mechanism (`run.sh`) wires a `ClusterProviderConfig` with
`source: Secret` + static admin keys. There are two distinct execution contexts and the
plan conflates them:

- **In CI/kind (L1, and any chainsaw-on-kind):** there is no IRSA. There is no OIDC
  provider trusting a kind serviceaccount. The pods cannot assume the Crossplane role.
  So "run L2 under real IRSA" is **impossible in the kind harness** — it can only happen
  on the live mgmt EKS cluster where the provider pod's SA is annotated with the role ARN
  and `source: InjectedIdentity` (or `Upbound`/IRSA) is set on the ProviderConfig.
- **On the live mgmt cluster:** the provider already runs under IRSA — but only if the
  test does **not** install a static-cred ProviderConfig over the top.

**How it bites THIS system:** the obvious, low-friction implementation is to reuse
`run.sh`'s existing cred-injection against a real cluster. That would run L2 with admin
keys on a real cluster and the suite would go green while proving **nothing** about the
restricted role — re-creating the exact blind spot auto-012 paid for, now with a green
checkmark on top. A least-privilege adversary's nightmare: a test named
"verify-under-real-IRSA" that quietly uses admin.

**Fix:** The plan MUST add an explicit, asserted invariant: every L2/L3 provisioning test
asserts the active ProviderConfig is the IRSA/`InjectedIdentity` one AND that **no
static-credential ProviderConfig or AWS_ACCESS_KEY_ID is present in the provider's
environment** before it trusts a result. Add a positive identity check — e.g. the test
captures the caller identity Crossplane actually used (CloudTrail `userIdentity.arn` for a
provisioned resource, or `aws sts get-caller-identity` from a pod using the same SA) and
asserts it equals the Crossplane IRSA role ARN, not the admin key's principal. Without
this assertion the "real IRSA" claim is unfalsifiable and will rot. Amend §2 and §6 to
name the ProviderConfig mechanism (`source: InjectedIdentity`, SA annotation) explicitly,
and add an L0 lint that fails if any live-cluster test path sets `AWS_ACCESS_KEY_ID` for
the provider.

### C2. The permission-completeness probe (§4, the "single highest-value addition") will drive permission BLOAT, not least privilege — as written
**Plan §4 bullet 2, §5 IAM row.** A probe that "exercises each MR kind's full lifecycle
(create/observe/update/delete/tag) under the real IRSA role" is described as the catch-all
for the IAM class. From my persona this is the most dangerous item in the plan, because of
how the feedback loop closes. When the probe fails with AccessDenied, the path of least
resistance is **add the grant until it passes**. There is no countervailing pressure in
the plan that says "the grant you add must be the *minimal* one, scoped by resource ARN
and condition." A green probe is satisfied equally by a least-privilege policy and by
`iam:*`/`rds:*`/`*:*`. The plan even lists `rds:*` as a *blocker that the probe catches* —
but the fix the probe incentivizes is to grant `rds:*`, which is itself the
least-privilege violation. The probe rewards breadth.

**How it bites THIS system:** auto-012's own fix list included "missing all `rds:*`."
A completeness probe makes it trivial and tempting to keep `rds:*` forever, because
narrowing it risks turning the probe red. Over a few sessions the Crossplane role
accretes wildcards and the platform's blast radius grows — the opposite of the stated
security posture. The probe becomes a ratchet that only loosens.

**Fix:** Pair the completeness probe with a **least-privilege / no-wildcard assertion** and
a deny-by-default counter-test:
1. An L0/L3 policy lint that **fails on broad wildcards** in the Crossplane IRSA policy
   (`Action: "*"`, `service:*` for high-risk services like `iam:*`, `rds:*`, `*:Delete*`
   without resource scoping). The existing `test_iam_required_actions.sh` only checks
   *presence* (and explicitly *accepts* `route53:*` wildcards — see its header). The new
   test must check the *ceiling*, not just the floor.
2. The completeness probe must assert the lifecycle works **with the committed policy**,
   not "with whatever grants make it pass." Tie the probe to the exact policy document
   under test so widening the policy to pass the probe is a visible diff a reviewer sees.
3. Add an explicit negative IAM test (see M2): assert the role **cannot** do things it
   should not (e.g. `iam:DeleteRole *`, `rds:DeleteDBInstance` on out-of-scope ARNs).
   Least privilege is proven by what fails, not only by what succeeds. The plan has zero
   "the role is correctly *denied* X" tests — it is all positive-grant.

### C3. L2b instantiate-and-verify creates real attack surface and a secret-exposure path the plan does not address
**Plan §1 L2b, §3, §5, §7.** "The test *creates* a real instance (IAM role, OIDC
provider, S3, secret, ESO ExternalSecret, ...)" under the real account, then tears it
down. From my persona several concrete hazards are unmanaged:

- **Secret material in logs/state.** L2b "ESO ExternalSecret" and "secret" round-trips
  read real Secrets Manager values into the cluster and (per the claim-verify skill's own
  Phase 4 example) `kubectl get secret ... -o jsonpath='{.data}'` and **base64-decode and
  compare** them. If the test echoes the decoded value, or it lands in chainsaw stdout
  (which the team routinely downloads via `ext-github` per AGENTS.md §6.8/§10), the secret
  is now in CI logs and the model's context. The plan's own §6 makes claim-verify
  *mandatory* — and that skill's documented recipe decodes secret data. The plan must
  forbid printing decoded secret values and assert on a **hash/length/known-non-secret
  canary**, never the plaintext.
- **Real IAM roles / OIDC providers created by a test = privilege-escalation surface.**
  An L2b test that creates an IAM role with a trust policy, on the shared ephemeral
  account, briefly creates an assumable principal. If the trust policy fixture is sloppy
  (`Principal: "*"`, or a broad `sts:AssumeRoleWithWebIdentity` without `aud`/`sub`
  conditions) the test itself instantiates a confused-deputy. There is no requirement that
  L2b fixtures be least-privilege or that the test assert the trust scope.
- **Teardown is the only thing standing between "ephemeral" and "leaked standing
  resource."** §7 says "per-run-ID prefixing + a guaranteed cleanup trap." Good, but a
  cleanup trap that runs `... || true`-style best-effort (the pattern AGENTS.md §6.19
  explicitly bans) on an IAM role/OIDC provider leaves a real principal behind on an
  account that is *supposed* to be torn down but, between sessions, is live. Leaked OIDC
  providers + leftover roles are an attack surface.

**Fix:** Amend §3/§7 with explicit L2b safety rules: (a) never emit secret plaintext —
assert on digest/canary; (b) L2b IAM/OIDC fixtures must be least-privilege and the test
must assert the created principal's trust scope is bounded (no `Principal:"*"`, `aud`/`sub`
conditions present); (c) cleanup of security-relevant resources (IAM role, OIDC provider,
ASM secret) must be **verified deleted** (poll for NotFound) and fail loudly if not — not
best-effort. Add a sweep test that fails if any prior run-ID-prefixed IAM/OIDC/secret
resource still exists at the start of a run (orphan detector).

---

## MAJOR

### M1. "disabled/all-skipped must never read green" is a stated requirement the plan only half-mechanizes
**Plan §2 (skip-guard), requirement (2).** The skip-guard "asserts the disable flag is
unset on protected branches." That covers the *global* `PLATFORM_VERIFY=off`. It does
**not** cover the failure mode where the suite runs but every L2/L3 case is individually
no-op: e.g. the live cluster is unreachable so every behavioral test hits an early
`return 0`/skip, or `SKIP_L2=1` is set per-layer (which the plan itself introduces in §2),
or a test's precondition probe ("is there a cluster?") is false and the test exits 0. The
user requirement is explicit: *all-skipped must never read green*. A flag-presence check
does not satisfy it.

**How it bites:** on a fresh rotated account where the mgmt cluster build half-failed, the
behavioral layer could skip everything and report green because the global flag is unset.
That is precisely the "disabled reads green" the user forbade.

**Fix:** Add a **positive-execution assertion / coverage floor**: the runner must emit a
machine-readable manifest of "tests that actually executed a real assertion" and the
skip-guard asserts that count is ≥ an expected floor per layer (and that 0-executed is a
hard FAIL, not green). A skip must be an explicit, counted, justified state — never the
absence of a failure. Make `SKIP_L2=1` on a protected branch a guard failure too, not
just `PLATFORM_VERIFY=off`.

### M2. Negative/precondition tests risk proving "resource is absent" instead of "the GUARD fired"
**Plan §4 (precondition bullet), §5.** The plan *says* "assert the GUARD fires" for
Keycloak (stays NotReady without DB) — good framing. But several rows reduce in practice
to "assert the bad thing didn't happen," which passes for the wrong reason:

- **Keycloak-DB gate.** "Deployment stays NotReady/crashloops when the DB secret is
  absent." A pod that is `NotReady` because it is *still pulling its image*, or because an
  *unrelated* initContainer failed, also satisfies "NotReady." The test would pass without
  proving the **DB precondition** is what blocked it. The guard is proven only if the test
  asserts the *specific* failure cause — e.g. the pod logs/events show DB-connection
  refusal, or (better) a Kyverno/admission/initContainer health-gate explicitly rejects
  the workload when the DB secret is missing. The plan should specify that the negative
  assertion matches the *reason*, not just the *state*.
- **external-dns "writes no records."** Asserting absence of a DNS record proves nothing
  about the auth guard — the record could be absent because the test simply didn't request
  one, or because propagation hasn't happened yet. The plan's parenthetical "surfaces an
  auth error" is the real assertion; the "writes no records" half is the weak one and
  should be demoted/removed.
- **XRD negative tests.** §4 "apply claims with missing-required / out-of-pattern fields →
  rejected." Must assert rejection happens at the **right layer with the right reason**
  (schema/admission rejection message), not merely that the claim never became Ready —
  because a claim that is silently `Pending` forever also "never became Ready" and would
  pass a sloppy assertion while the contract is actually unenforced.

**Fix:** For every L3 case, require the assertion to match the **cause/reason** (denial
message, condition reason, log signal), and to first prove the *positive* path works in
the same test fixture (apply a *valid* claim → Ready; then the *invalid* one → rejected),
so "rejected" can't be a false positive caused by a broken-everything environment.

### M3. The coverage matrix (§5) overclaims — several cells assert the symptom, not the root cause
**Plan §5.** From my persona the matrix is the part most likely to give false confidence.
Specific overclaims:

- **Row "ArgoCD controller SA no IRSA → L2a (assert BOTH SAs annotated)."** Asserting the
  *annotation string is present* is a lint, not a behavioral test — it is the same class of
  "the manifest *says* it" that the plan's own §0 derides. The annotation can be present
  and *wrong* (typo'd role ARN, role that doesn't exist, trust policy that doesn't trust
  this SA). The real proof is the controller pod actually assuming the role
  (`sts:AssumeRoleWithWebIdentity` succeeds → spoke registration works). The matrix should
  cite the live assume-role/registration check, not the annotation presence.
  (The repo already has `scripts/irsa_trust_validator.py` and
  `tests/integration/08_irsa_sts_round_trip.sh` — the plan should build on those for a
  *behavioral* assertion, and the matrix should say so.)
- **Row "subnet tags → L2a (assert tags) + L4 (NLB provisions)."** "Assert tags" is again
  a read-back lint. Only the "NLB actually provisions" half is behavioral. Fine to keep
  both, but the matrix presents the tag-assert as independent coverage when it is not.
- **Row "EKS authenticationMode → L2a + L4 (AccessEntry create fails)."** This one is
  honest. Keep it as the template for the others.

**Fix:** Re-label each matrix cell as **lint** vs **behavioral**, and require at least one
*behavioral* (root-cause) assertion per blocker. A presence-lint may accompany a
behavioral test but must never be the sole entry — otherwise the matrix reproduces the
exact lint-as-test conflation §0 set out to kill.

### M4. After-the-fact verification of standing resources is read-only — it cannot catch the *create-path permission* failures that dominated auto-012
**Plan §1 L2a, §3.** L2a "asserts the real thing exists and is correctly configured" on
resources that **bring-up already created with admin/Terraform creds** (the mgmt+spoke
EKS, the bootstrap stack). But auto-012's blockers were overwhelmingly **create-time IRSA
permission** failures. If the standing resource was created by Terraform/admin (not by
Crossplane-under-IRSA), L2a will find it correctly shaped and pass — while the
Crossplane-IRSA create path that a *spoke* or a *user claim* would exercise is never tested.

**How it bites:** EKS spoke clusters and AWS resources are provisioned by Crossplane under
IRSA in production. If the *test* path provisions the standing instance via Terraform/admin
and only L2a-verifies it, the IRSA create permissions are never exercised for the expensive
resources — and "EKS ~20min, verify after-the-fact only" (§3) explicitly chooses the path
that skips the IRSA create test for the highest-value resource. The plan partially
acknowledges this with the L2b "instantiate-on-purpose" for cheap resources, but for EKS
(the resource auto-012's authenticationMode + access-entry blockers lived in) it is L2a-only.

**Fix:** State explicitly which standing resources are created by **Crossplane-under-IRSA**
vs by Terraform/admin, and ensure the IRSA *create-path* is exercised at least once for
each MR kind even when the standing instance is admin-created. For EKS specifically: even
if you only build one cluster, build it (or at least one nodegroup/access-entry/addon
sub-resource) *through Crossplane under IRSA* so the create permissions are on the tested
path — otherwise the most expensive blocker class stays untested by design. At minimum,
add an IRSA `eks:*` create-path probe (dry-run / minimal sub-resource) so the permission
set is exercised without a throwaway 20-min cluster.

### M5. Couple-to-change is asserted as discipline, not enforced as a gate
**Plan §2 (coupling discipline), §8.** "Authoring a create-step REQUIRES adding/extending
its L2/L3 test in the same change." This is a human-discipline statement (it restates
AGENTS.md §6.1). Nothing in the plan *mechanically* fails CI when a new XRD/Composition/MR
kind lands without a matching L2/L3 test or claim-verify recipe. AGENTS.md's history is
full of disciplines that drifted until a guard was added (§6.16: 17 of 39 unit tests had
drifted out of the CI list). A least-privilege adversary assumes discipline decays.

**Fix:** Add a concrete coupling gate: an L0 test that enumerates every XRD/Composition
under `crossplane/` and fails if any lacks (a) a render-fixture (already gated), (b) a
`crossplane-claim-verify` `cloud-verification.md` recipe, and (c) at least one L3 negative
case. This converts the discipline into a check, which is the only form the plan's own §0
philosophy respects.

---

## MINOR

### m1. "Real-cloud latency flakiness → bounded waits + retries, never `|| true`" — good, but retries can mask intermittent AccessDenied
**Plan §9.** Retrying a create that intermittently AccessDenies (eventual-consistency on a
just-attached policy) can paper over a genuinely missing-then-present grant, hiding a real
least-privilege gap behind "it passed on retry 3." Specify that retries are for *resource
not-yet-ready* conditions only and that **authorization errors are non-retryable / fail
fast**. (`scripts/wait-for-claim.sh` already exits 1 unconditionally on timeout and bans
`grep -q True` — build the negative-path waits on the same primitive, and classify
AccessDenied as terminal.)

### m2. Disable-switch governance is listed as an open question, not answered
**Plan §9 last bullet.** "Who may set `PLATFORM_VERIFY=off` and the audit trail" is left
open. From my persona this is the single highest-risk human control in the design — the
off-switch for all behavioral security verification. Leaving it open means the first person
under deadline pressure decides it ad hoc. Answer it in the plan: require the flag only via
an audited, reviewed change (not an env var a CI operator can set unreviewed), with the
skip-guard refusing it on protected branches (ties to M1).

### m3. Kyverno/admission-bypass and RBAC-bypass negatives are entirely absent
**Plan §4, §5.** The platform runs Kyverno as a guardrail (CLAUDE.md context). The plan's
negative tests cover XRD schema, IAM, and workload preconditions — but **nothing** asserts
that a Kyverno policy actually *blocks* a non-compliant resource (admission-bypass), or
that a spoke/AppProject RBAC boundary actually *denies* a cross-tenant action. These are
core negative cases for this system. Add: (a) apply a resource that violates each
enforcing Kyverno policy → assert *denied at admission* with the policy's message; (b)
attempt a cross-AppProject / cross-namespace action that RBAC should deny → assert denied.
Without these the "negative test rigor" claim has a hole exactly where this platform's
guardrails live.

### m4. L1/kind chainsaw keeps admin creds — make that explicit so nobody re-promotes it to "verification"
**Plan §1 L1, §6 ("keep kind chainsaw strictly as L1").** Good that it's demoted. But
`run.sh` *still* installs admin-cred ProviderConfig for kind. Add a one-line note that L1
is render/admission-only and its provisioning results carry **no** security/permission
weight precisely because it runs with admin creds — so a future reader doesn't cite a green
L1 as IRSA evidence (the C1 trap in miniature).

---

## What the plan got RIGHT — the synthesis MUST preserve these

1. **The core diagnosis and the IRSA-execution premise.** Verified true against
   `run.sh`: provisioning tests run with admin GitHub-Actions keys, not the restricted
   role. Making "Crossplane reconciles under the real IRSA role" the center of L2/L3 is the
   correct and essential fix. (Preserve §0, §1-L2.) **— but only if C1's mechanization +
   identity-assertion is added; the premise is worthless unmechanized.**
2. **The honest taxonomy (L0 lint / L1 render / L2 behavioral / L3 negative / L4 e2e) and
   the rename `tests/unit/`→`tests/lint/`.** Naming a lint a lint is the single most
   valuable cultural fix; it directly attacks the conflation that hid the blockers. (§1, §8 P1.)
3. **"On by default, explicitly disable-able, never silently green" + the skip-guard
   concept.** The mechanism needs strengthening (M1), but the principle and the
   protected-branch guard are exactly right and must survive. (§2.)
4. **Slow-vs-cheap split: amortize the one ~20-min EKS into bring-up (L2a), instantiate
   cheap resources for real (L2b).** Cost-aware and correct given the ephemeral account.
   (§3, §7.) **— subject to M4: the EKS *create-path* permissions still need one IRSA
   exercise.**
5. **Coupling verification to the change, not to a nightly.** (§2, §8.) Right principle;
   M5 just asks to make it a gate.
6. **Reusing existing assets** — `crossplane-claim-verify`, `wait-for-claim.sh`,
   per-run-ID prefix + cleanup trap, expanding `e2e-verify` — rather than inventing a new
   harness. (§6, §7.) Pragmatic and aligned with the repo.
7. **The framing "assert the GUARD fires" for preconditions** (Keycloak/ingress/external-dns).
   The *intent* is exactly right (M2 only sharpens it to assert the *reason*). Preserve the
   framing; do not let synthesis water it back down to "assert resource absent."
