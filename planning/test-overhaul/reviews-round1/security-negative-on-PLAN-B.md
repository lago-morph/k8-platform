# Adversarial review of PLAN-B (k8s-testing-expert)

**Reviewer persona:** security & least-privilege adversary + negative-test stickler.
**Question I keep asking:** does running tests under the real restricted IRSA role
drive *permission bloat*? Do instantiate-and-verify tests create *attack surface*
or *leak secrets*? Do the negative tests actually prove the **guard fires**, or
merely that a resource is absent? What negative cases are missing? Does the
coverage matrix **overclaim**?

I read the whole plan. I also grounded the central claims against the repo
(`terraform/management/irsa.tf`, the `crossplane-claim-verify` skill,
`tests/chainsaw/run.sh`, `tests/integration/*`, `docs/open-issues.md`). Findings
ranked Critical / Major / Minor, each with how it bites THIS system and a concrete
fix citing the plan's sections.

---

## CRITICAL

### C1. The central mechanism — "run L4 under the restricted Crossplane IRSA role" — is **structurally infeasible as written**, and the plan's own §11 "fix" quietly guts the requirement.

The plan's thesis (§0), §2's "single most important change", §4.1, §5.2, §7's "The
pattern", and PR-3 (§9) ALL hinge on a probe pod/SA assuming the *restricted
Crossplane IRSA role* so permission gaps surface. But the role's trust policy is
scoped to exactly one subject:

```
# terraform/management/irsa.tf:174
namespace_service_accounts = ["crossplane-system:upbound-provider-family-aws"]
```

A throwaway "probe SA" the plan wants to stand up (§4.1, §11 assumption 1,
§12 open-question 2) **cannot** `AssumeRoleWithWebIdentity` into that role —
the OIDC `sub` won't match. So the plan has three exits, and each is bad:

1. **Widen the trust policy to admit a probe SA** — *this is exactly the
   permission/policy bloat my persona is tasked to catch.* You'd be loosening a
   least-privilege trust boundary **to make a test pass**, creating a standing
   second principal that can wield all of `eks:*`, `iam:Create/DeleteRole`,
   `iam:PassRole`, `rds:*`, ASM read/write. That probe SA becomes a privilege-
   escalation primitive in the hub: anyone who can create a pod under that SA gets
   the Crossplane blast radius. **Unacceptable.**

2. **§11's escape hatch** — "If it can only be used by the Crossplane controller
   itself, L4-under-IRSA becomes 'apply the claim and let the real controller act'
   rather than a direct probe — still faithful." This is **not** "still faithful";
   it **collapses L4 into L4-via-the-real-controller**, which is just "apply a
   claim and watch it reconcile." That is fine and correct — but it means the
   plan's signature differentiator (a *direct* probe under IRSA) evaporates, and
   the §7 claim that L4 *directly* exercises the restricted identity is false for
   most rows. The plan should say so up front, not bury the climbdown in an
   assumption.

3. **Reuse the controller's SA token** — copying/mounting the provider SA's
   projected token into a probe pod is a **credential-exfiltration pattern** and
   would itself be the kind of thing a Kyverno/PSS policy must forbid.

**Fix (amend §0, §2, §4.1, §11, §12-Q2, and PR-3):** Make the *only* sanctioned
"under-IRSA" mechanism **option 2 — drive the real controller** (apply a real
claim / managed resource, observe `Synced`/`ReconcileError` reason). Delete the
"direct probe SA under the restricted role" idea entirely. Then the negative
permission tests (C2) become "apply a claim whose composition needs action X,
assert the MR goes `Synced=False` with `AccessDenied` naming X" — faithful,
zero new trust surface, no new principal. PR-3 must NOT widen
`irsa.tf` trust to add a probe subject; add an explicit **non-goal: "this overhaul
does not add any new AssumeRole principal."**

### C2. The IRSA-permission **negative tests will drive permission bloat in the wrong direction** — and as written they cannot tell "guard fired" from "composition never asked."

§5.2 bullet 3 / §7 rows 2–5,8: "apply a claim that needs an action the restricted
role lacks → assert the MR goes `Synced=False`/`ReconcileError` with AccessDenied."
Two problems, both squarely in my lane:

- **Bloat risk:** to *author* such a negative you must construct a claim whose
  composition path actually invokes the missing action. The blockers 2–5 were
  `iam:UpdateAssumeRolePolicy`, `iam:GetRolePolicy`, `iam:TagOpenIDConnectProvider`,
  `rds:*` — all now **already granted** (I read `irsa.tf:73,82,98-105`). To make a
  *standing* negative test that proves "the role lacking X fails closed," you'd
  have to either (a) temporarily *revoke* X from the live role (mutating the
  security boundary mid-test — dangerous on a shared ephemeral account, and a race
  against Terraform drift-correction), or (b) maintain a **parallel deliberately-
  crippled role**, which is a second IAM principal to keep in sync and itself an
  audit-noise/attack-surface item. The plan picks neither; it just says "assert
  AccessDenied," which is unimplementable without one of these. **This is the
  permission-bloat trap:** the test suite starts demanding extra IAM scaffolding
  (a crippled twin role + its trust policy) to exist *just to be denied*.

- **Guard-vs-absence ambiguity:** `Synced=False/ReconcileError` is also the steady
  state when a composition simply *hasn't reached* that managed resource yet, or
  when the provider pod is cold, or when an *unrelated* dependency failed. Asserting
  "not Synced" proves a resource is *absent/unhealthy*, **not** that the specific
  permission guard fired. My persona's core complaint: this is "assert the resource
  is absent" dressed up as "assert the guard fired."

**Fix (amend §5.2, §7):** (1) Drop live-role mutation entirely. (2) The faithful,
cheap home for "missing-permission fails closed" is **NOT a live AWS denial** —
it is a **simulation**: `aws iam simulate-principal-policy
--policy-source-arn <crossplane-role> --action-names iam:TagOpenIDConnectProvider
rds:CreateDBInstance ...` asserting `allowed` for the actions each composition
needs, AND `aws iam simulate-custom-policy` over a *hypothetically stripped* policy
asserting `implicitDeny` — no live resource, no role mutation, no crippled twin,
deterministic, and it proves the *exact* action↔grant contract for blockers 2–5,8.
(3) For the *behavioral* proof that fail-closed is loud, keep ONE positive
end-to-end (the real claim provisions), and make the negative assertion key on the
**verbatim `AccessDenied` substring naming the action** in the MR's `status.conditions[].message`,
not on bare `Synced=False`. If you cannot get an AccessDenied message without
revoking a grant, then this contract belongs at the simulate-policy layer, full
stop. State that explicitly in §7 rather than implying a live denial you can't
safely produce.

### C3. L4 throwaway IAM/secret resources on a **shared ephemeral account** are a real attack-surface and secret-leak vector that the plan underweights.

§4.1 creates throwaway **IAM probe roles**, **ASM secrets**, **ACM certs**,
**Route53 records** on every bring-up, run in CI on the shared account. My
concerns:

- **IAM probe role with a trust policy** (§4.1 bullet 1, "confirm the trust policy
  subject matches the SA") — to test blocker #8 you create a role that trusts an
  OIDC subject. If the trust policy is even slightly wrong (wildcard `sub`, missing
  `aud` condition), you've minted an **assumable-by-anyone** role on a live account
  for the lifetime of the test. The plan's cleanup trap (§6) is "best-effort"
  (chainsaw's trap is literally `best-effort delete`, per `run.sh`), so a crashed
  run **leaks an over-permissive role**. The §6 "leaked-resource sweep … reports
  leaks" only *reports* — it does not *remediate*, and a reported-but-not-deleted
  assumable IAM role is a finding, not a footnote.

- **ASM secret round-trip under IRSA** (§4.1 bullet 2) — `04_eso_secret_round_trip`
  / `11_platform_secret_e2e` write real secret material. Promoting them to run on
  *every bring-up* multiplies the windows in which test secret values sit in ASM
  and in pod env/logs. If any assertion dumps the secret on failure (a common
  debugging pattern, and `wait-for-claim.sh` does a "timeout dump"), the secret
  lands in CI logs. The plan never says "negative-test secret values must be
  non-sensitive synthetic tokens" or "failure dumps must redact `data`/`stringData`."

**Fix (amend §6 + add a §6 subsection):** (1) **Cleanup must remediate, not just
report** — the leaked-resource sweep must *delete* leaked run-id-prefixed IAM
roles/policies/ASM secrets and **fail the suite** if it cannot (consistent with
§6.19 no-`|| true`). A leaked assumable IAM role failing the build is correct;
silently reporting it is not. (2) Every L4 throwaway IAM role's trust policy MUST
be asserted to carry both `sub` *and* `aud` StringEquals conditions before the test
proceeds — a malformed-trust probe role must be **rejected by the test harness
itself**, not created. (3) Mandate **synthetic non-secret values** for all
secret-path tests and a **redaction filter** on every failure dump (no raw
`data:`/`stringData:` to stdout). (4) Add `aws iam simulate` (per C2) as the
*default* path so most of the IAM testing creates **zero** live roles.

---

## MAJOR

### M1. The negative/precondition tests mostly **assert absence, not guard-firing** — the exact anti-pattern my persona is told to hunt.

- **§5.3 Keycloak-DB gate:** "with the DB absent, assert the Keycloak pod stays
  Pending/CrashLoopBackOff … does not report Ready." A pod can be `Pending` for a
  *dozen* reasons (unschedulable, image pull, PVC unbound, quota). Asserting
  "not Ready" proves the pod is unhealthy — **not** that *the DB precondition gate*
  is what's holding it. That is "resource is absent" cosplaying as "guard fired."
  **Fix:** assert the *specific* gate: the init-container's name/exit reason or the
  readiness-probe failure message must name the DB dependency (e.g. container
  `wait-for-db` in `Waiting` with the DB host in its log/last-state), AND assert
  that when the DB *is* present the same pod reaches Ready (positive twin). Pin to
  the gate's identity, not to global unreadiness.

- **§5.1 XRD required-field rejection:** "asserts admission rejects it with the
  expected message." Good — but only if "expected message" is pinned. If the
  assertion is merely "apply fails / non-zero exit," a claim rejected for an
  *unrelated* reason (wrong namespace, CRD not installed, webhook down) passes the
  negative test green while the actual `required`/`enum` guard is broken. **Fix:**
  every negative-admission assertion MUST match the **specific** validation message
  substring (field name + violated constraint), and a paired positive (valid claim
  is *accepted*) must run so "rejects everything, including valid input" can't read
  green.

- **§5.2 RBAC negative** ("stripped SA cannot"): `auth can-i` returning `no` is
  also what you get if the SA/namespace is mistyped or doesn't exist. **Fix:**
  assert the positive (`yes` for the real SA + intended verb/resource) and the
  negative (`no` for the stripped SA) in the *same* matrix, and assert the stripped
  SA actually *exists* first — otherwise you're testing a typo.

### M2. **Missing negative cases** my persona must flag (admission/RBAC bypass + secret exposure).

The plan's negatives are XRD-required-field, RBAC can-i, IRSA-subject, and the
Keycloak gate. Absent and important for THIS system:

1. **Kyverno enforce *bypass* tests.** §5.4/§7 add `enforce` policies for "IRSA SA
   must carry role-arn" (#6) and "subnet must carry ELB tags" (#9). A policy is
   only as good as its match block. **Missing:** a negative that *attempts to
   create a violating resource and asserts the webhook BLOCKS it* (the whole point
   of `enforce`), plus a **bypass attempt**: create the violating resource via a
   path the policy's `match`/`exclude` might miss (different namespace, a kind the
   `match` over-narrows, `generate`/`mutate`-produced resources, server-side-apply,
   a subresource). A `kyverno test` unit pass (§5.4 L0) does **not** prove the live
   admission webhook is wired/enforcing — Kyverno can be in `Audit` or its webhook
   failurePolicy `Ignore`, both of which silently let violations through. **Add:**
   live "create-violation→expect-denied" + an assertion that the policy is
   `Enforce` and webhook `failurePolicy: Fail`.

2. **AppProject deny is under-tested (§7 #7).** The plan tests "permitted kind
   syncs; forbidden kind rejected." Missing the higher-value negatives:
   `sourceRepos` restriction (an Application pointing at an *un-allowlisted* repo
   must be refused), `destinations` (server/namespace) restriction, and
   cluster-resource *deny-by-default* (does the project's
   `clusterResourceWhitelist` reject a `ClusterRole`/`CRD` it shouldn't permit?).
   These are the AppProject's actual security contract; IngressClass is one cell.

3. **Secret-exposure negatives.** Nothing tests that (a) ESO does NOT write the
   secret to a place it shouldn't, (b) connection secrets aren't emitted on v2 XRs
   (AGENTS.md §6.8 says v2 *rejects* them — a negative test should assert no
   `connectionSecret` materializes), (c) Crossplane MR `status` / events don't echo
   secret values, (d) the test harness's own failure dumps redact secrets (C3).

4. **IRSA confused-deputy / token-audience negative.** Blocker #8 is subject
   mismatch; the adjacent class is **`aud` mismatch** (token minted for one
   audience presented to a role trusting another) and **wrong-OIDC-provider**
   (a token from a *different* cluster's issuer). A faithful #8 family asserts
   `AccessDenied` for wrong-`sub`, wrong-`aud`, AND wrong-issuer.

5. **EKS authn-mode regression both directions (#1).** §7 asserts mode *includes*
   API. Add the negative: a config that sets `CONFIG_MAP`-only must be **rejected**
   at author time (L0/L1), so the blocker can't silently reappear via a new
   composition.

### M3. The coverage matrix (§7) **overclaims** — several rows credit a catch the layer can't actually make.

- **#1 EKS authnMode "Kyverno audit":** Kyverno runs against *Kubernetes* objects
  in the hub. The EKS `accessConfig.authenticationMode` is an **AWS control-plane**
  attribute, not a hub k8s resource — Kyverno cannot see it. Either it's the EKS
  XR's `spec`/`status` (then say *that*), or drop the Kyverno claim. As written it
  overclaims.
- **#9 subnet ELB tags "Kyverno audit":** same category error — VPC subnet tags are
  AWS resources; Kyverno audits k8s resources. Unless you mean the `Subnet` *managed
  resource* object in the hub, Kyverno can't assert this. Clarify or drop.
- **#5 RDS "L4 negative claim under IRSA goes ReconcileError instead of silent-
  never":** per C2 this is unimplementable without revoking `rds:*` (now granted)
  or a crippled twin role. The matrix presents it as a clean catch; it is not.
- **#2–#5 "L0 action-presence lint (stopgap)":** `test_iam_required_actions.sh`
  greps the policy JSON for action strings. That proves the *string is present*,
  not that the *composition needs it* nor that it's *effective* (an explicit
  `Deny`, an SCP, or a permissions-boundary elsewhere can negate a present
  `Allow`). The honest tool for "is this action effective for this principal" is
  `aws iam simulate-principal-policy` (C2). Relabel the L0 grep as what it is
  (presence only) and add the simulate layer.

**Fix:** add a column to §7 stating, per row, the *precise* assertion and its
*environment*, and remove any layer that cannot physically observe the attribute.
A matrix that says "caught" when the cited layer is blind is worse than no matrix —
it manufactures false confidence, which is the very disease (OI-2026-06-07-6) this
plan exists to cure.

### M4. "Disabled / all-skipped must never read green" — the guard has **two holes**.

§3.2 is genuinely good (loud skip + expiring SKIP_REGISTER + CI skip-count gate).
But:

1. **All-auto-skip reads green.** §3.3 auto-skips (loudly, not in the register)
   when a precondition is "structurally absent" — e.g. "any kube-API check from the
   sandbox," "RDS verify when no spoke exists." A bring-up where the cluster comes
   up *degraded* (kube-API briefly unreachable, no spoke yet) could **auto-skip the
   entire live suite** and the run **still exits 0**. That is precisely "all-skipped
   reads green," which requirement 2 forbids. The skip-*counter* increments, but
   nothing asserts a **floor of checks actually executed**. **Fix:** the suite must
   **fail (non-zero)** if the count of *executed* checks for the present phase is
   below a declared minimum, OR if *every* check auto-skipped. Auto-skip is for
   *individual* not-applicable checks; a wholesale auto-skip is a red, not a green.

2. **Register-gate is bypassable by editing the register.** §3.2.3 fails the PR if
   skip-count rises *without a matching `SKIP_REGISTER.yaml` diff*. But a diff that
   *adds an entry* satisfies the gate — so anyone can disable a check by adding a
   register row with a future `expires`. That's the intended workflow, fine — but
   there's no upper bound. **Fix:** cap the register (a max number of simultaneously
   disabled checks, e.g. fail if > N entries active) and require the §6.18
   open-issues register cross-link for any disabled *security* check (IRSA, RBAC,
   Kyverno-enforce), so disabling a guardrail is visible at the security-review
   altitude, not just as a dated TODO.

---

## MINOR

### m1. §5.4 conflates `kyverno test` (L0) with enforcement proof.
Already covered in M2.1 but worth a standalone note: the plan lists Kyverno at L0
*and* "live audit" (L4) but never asserts **enforce mode is actually active**. A
policy authored `enforce` but deployed `audit` (or with `failurePolicy: Ignore`)
is a no-op. Add a one-line live assertion on `spec.validationFailureAction:
Enforce` + webhook `failurePolicy: Fail` for the two enforce policies (#6,#9).

### m2. §6 "consistency budget" poll-until-true can still mask a real fail.
For Route53/IAM eventual consistency the plan uses bounded poll-until-true. Good vs
blind retry — but a *too-generous* budget hides a genuinely-broken path as "slow."
Require each consistency budget to be **justified with the AWS-documented
propagation SLA** and reviewed, not picked ad hoc; and on budget-exhaustion the
failure message must say "guard may be broken OR propagation exceeded N s" so it's
triaged, not auto-retried-away.

### m3. §8.5 hub→spoke `curl https://hello.platform.<domain>` 200 — note the egress caveat.
AGENTS.md §6.27: sandbox egress is a strict-verifying MITM gateway; a private-CA or
SAN-mismatched endpoint 503s at the gateway, not the app. The plan must run this
curl **from CI/in-cluster**, never assert it from the sandbox, and must distinguish
a gateway 503 from an app failure (read the 503 body). Otherwise the e2e "200 check"
flakes for an environmental reason and gets retried-away or disabled (feeding M4).

### m4. §4.3 COST_TIERS mapping test is good but doesn't bound *cumulative* cost/time.
Per-resource tier mapping prevents "forgot to classify," but nothing caps the
*aggregate* L4 create/destroy churn per bring-up. On the ephemeral account the
context says cost+wall-clock matter. Add a suite-level assertion: total L4
create-verify-delete budget (count × tier) under a declared ceiling, failing if a
new cheap resource pushes the every-bring-up suite past it.

### m5. §9 PR-3 sequencing risk.
PR-3 is "restricted-IRSA harness" and is where the C1/C2 infeasibility lands. As
sequenced, PR-1/PR-2 ship the discipline + promoted probes, then PR-3 discovers it
can't do the central thing. **Fix:** resolve the assumption (§12-Q2) *before* PR-1,
via the §6.4 adversarial-subagent review the plan itself invokes — don't defer the
load-bearing feasibility question to "author time."

---

## What the plan got RIGHT — synthesis MUST preserve these

1. **The create-and-verify *coupling* (§0)** — verification bound to the change,
   not a nightly job. This is the correct diagnosis of OI-2026-06-07-6 and the one
   non-negotiable. Keep it.
2. **Demote static lints to *pre-flight*, never "the test" (§0, L0 in §2).** Exactly
   right; this is the disease's name.
3. **The skip discipline (§3.2): loud skip + expiring SKIP_REGISTER with
   owner/reason/expires + CI skip-count gate vs main.** Best part of the plan;
   directly answers requirement 2 (modulo the M4 holes — patch, don't discard).
4. **L4/L5 split by *cost*, with EKS/RDS as after-the-fact-only (§4).** Correct and
   matches requirements 3/4 and the account constraints.
5. **Reuse existing assets** (`crossplane-claim-verify`, `wait-for-claim.sh`,
   `irsa_trust_validator.py --all`, per-run-ID prefix + cleanup trap) **rather than
   rebuild** (§1, §6, §10). Right instinct; `irsa_trust_validator.py --all == 0
   MISMATCH` as a hard gate is the faithful fleet-wide guard for #8.
6. **Negative + precondition tests as first-class (§5), and the per-blocker
   traceability matrix shape (§7).** The *shape* is right and must survive — it just
   needs the M3 overclaim correction and the M1/M2 "prove the guard fired, pin the
   message" rigor.
7. **No blind retries; flakes → open-issues register (§6).** Aligns with §6.18/§6.24
   — keep.

---

## Bottom line

The plan's *philosophy* is correct and several mechanisms (skip register, cost-tier
split, asset reuse) should survive into synthesis intact. But its **signature
technical claim — direct L4 testing under the restricted Crossplane IRSA role — is
infeasible without either privilege/trust-policy bloat or token exfiltration**, and
the plan's quiet §11 climbdown masks that. The **permission negatives** as written
either demand a crippled-twin IAM role / live role-mutation (bloat) or prove
*absence* rather than *guard-firing*. The **coverage matrix overclaims** (Kyverno
"catching" AWS-side attributes; a live RDS denial that can't be safely produced).
Replace the "probe-SA-under-IRSA" idea with **drive-the-real-controller +
`aws iam simulate-principal-policy`**, pin every negative to a **specific guard
message**, make **cleanup remediate (not report)**, forbid **wholesale auto-skip
reading green**, and add **synthetic-secret + redaction** rules before any
secret-path test runs on every bring-up.
