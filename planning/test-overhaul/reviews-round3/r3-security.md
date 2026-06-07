# Round-3 Adversarial Review — Security & Least-Privilege / Negative-Test Rigor

**Target:** `planning/test-overhaul/FINAL-PLAN.md` (revised final; round-1 + round-2
resolved; constraint corrections #1 and #2 applied).
**Persona:** least-privilege adversary + negative-test stickler.
**Method:** read the FINAL plan cold, end-to-end, then re-ground every load-bearing
security claim against the live tree this session — `terraform/management/irsa.tf`,
`.github/workflows/terraform-test.yml` (the build flow), the constraint-correction docs,
and my own round-2 review to confirm each resolution actually landed. Findings ranked
Critical / Major / Minor, each with a concrete fix.

The brief asks specifically: did corrections #1 (jentic-editable workflows) and #2
(build-coupled + dispatch-only) get applied **soundly**, and **did build-coupling
change the identity/permission story** — i.e. open a new security hole? Short answer:
the spine survives and most round-2 resolutions landed well, but **correction #2
introduced one genuine, unaddressed Critical**: the build-coupled trigger runs the
live suite under the **admin CI key**, and the plan never says so or constrains it.

---

## 0. What landed correctly (verified — finalization must NOT re-open these)

These were my round-2  asks or the spine; I confirmed each against the tree so I
don't re-litigate them:

- **The NON-GOAL spine survived verbatim and is reinforced** (§3.1, §3.2, §17.1).
  `irsa.tf:171-175` still trusts exactly `crossplane-system:upbound-provider-family-aws`;
  the plan creates no new AssumeRole principal, widens no trust, mounts no provider
  token, stands up no probe pod, and explicitly mandates rejecting any PR that tries.
  This is the single most important property and it is intact. **Do not lose it.**
- **My round-2 C1 (ceiling-with-teeth) landed.** §3.3 now *narrows* `eks:*`/`rds:*`
  to derived verb lists, caps annotated wildcards at K with mandatory `OI-`/ADR
  cross-link + expiry, and makes the un-exercised-grant tier **non-deferred** (async
  lane). The "annotate everything" rubber-stamp is mechanically foreclosed. Good.
- **My round-2 C2.2 (verifier identity is new blast radius) landed as §3.4** — an
  explicit allowlist artifact, ceiling-linted, reaper scoped tightly. (But see C1
  below: the *amount* of privilege the build-coupled model now needs is larger than
  §3.4 reckons, and §3.4 still doesn't name the actions — it lists them in prose.)
- **My round-2 M3 (ARN-match is the banned probe in a hat) landed as §3.2.** The
  caller-ARN check is demoted to an optional out-of-band CloudTrail/Access-Analyzer
  audit; the **load-bearing in-band gate is `source: IRSA` (exact string) + no
  static-cred AWS PC + no `AWS_ACCESS_KEY_ID` in the provider pod + provider Healthy**.
  Grounded: `providerconfig:41` is `source: IRSA`. The synthesized §14.1 "degrade to
  Synced+exists, drop the ARN" fallback is explicitly **forbidden**. This is exactly
  the inversion I asked for and it makes the identity gate falsifiable.
- **My round-2 M4 (external-dns) landed:** `irsa_trust_validator.py --all == 0
  MISMATCH` is now PRIMARY (§7, matrix #8); the brittle log-grep is corroborating.
- **My round-2 C3.1 (Keycloak Fail-webhook freeze) landed:** §7 makes the primary
  gate the app-local `wait-for-db` init-container, explicitly NOT a
  `failurePolicy:Fail` admission webhook; blanket Enforce+Fail mandate dropped.
- **My round-2 C3.2 (red-first meta-test as a gate) landed** as §7's last bullet +
  §15 checklist — every `negative`/`precondition` references a committed red-first
  artifact or the push fails.
- **My round-2 M1 (tenant isolation via AppProject, not Kyverno) landed** as §7 +
  matrix #6/#7 — deny-by-default by construction, Kyverno is the redundant layer.
- **Secret redaction (round-2 m3) landed and was widened** (§9.2): synthetic-only,
  digest/length/canary, redaction filter on every dump, **plus** account-id/ARN
  masking on the PR-summary path specifically. Grounded: the spill is real at
  `cloud-verification.md:45-51`.
- **Reaper friendly-fire (round-2 M2) landed well** (§8): account-mutex, age-floor
  ≥45 min, skip-active-lease-run-ids, **structural deny-list** account guard (not an
  allow-match that bricks on rotation — this correctly satisfies AGENTS §8.1), pinned
  exact label string (`k8-platform` vs `k8s-platform` confusion called out),
  run-id-on-XR-name primary teardown, remediate-and-RED after bounded poll.

The center holds. My round-3 findings are about (a) the **one new identity hole
correction #2 opened and did not close**, (b) a **few resolutions asserted but not
fully nailed down**, and (c) **negatives/missing controls my persona still wants**.

---

## CRITICAL

### C1 — Correction #2 moved the trigger into the build, but the build runs under the ADMIN CI key. The live suite — verifier, reaper, simulate, RGT-diff, all of it — now executes as the most-privileged principal on the account, and the plan never says so.

This is the round-3 headline and it is **exactly the "did the corrections open a
hole?" question the brief flags.**

The plan's identity story (§3.2) is airtight *for the Crossplane controller*: the
controller reconciles the throwaway XR under `source: IRSA`, so the create-path
permission is genuinely exercised under the restricted role. But **the suite that
drives, observes, reaps, and simulates around that controller does NOT run under
IRSA.** Correction #2 says the bring-up procedure invokes `tests/live/run.sh` as its
final phase. Grounded against the only build flow that exists:
`.github/workflows/terraform-test.yml:24` is where `apply-and-verify` lives, and
`:41-43` injects `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from repo secrets —
the **admin keys** AGENTS §0/§4 describe (the very "more privilege than production"
anti-pattern this overhaul exists to retire). The build-coupled `tests/live/run.sh`
therefore runs as that admin identity. So does:
- `simulate-principal-policy` (`iam:SimulatePrincipalPolicy`),
- the after-the-fact `Describe*`/`describe-cluster`/`describe-db-instances`,
- the **RGT-diff** side-effect oracle (`resourcegroupstaggingapi:GetResources`),
- the **reaper's cross-service deletes** (EKS/RDS/IAM/ASM/Route53),
- the account-mutex SSM/DynamoDB writes,
- CloudTrail/Access-Analyzer reads.

§3.4 *names the problem* ("move the over-privileged principal from Crossplane to the
CI key on the account that also hosts the mgmt cluster") and asks for an allowlist.
But correction #2 **made the problem worse and the plan didn't re-reckon it**: under
the old CI-trigger model you could at least imagine a narrow OIDC-federated CI role
scoped to `tests/live/`. Under the build-coupled model, the suite is wired into the
*same* `apply-and-verify` flow that needs admin to run `terraform apply` against base
+ management. There is enormous pressure to just let the whole thing inherit the
admin env block — and §4.1/§4.2/§18 describe the wiring without ever stating the
identity it runs under or forbidding admin inheritance.

Net effect on day one, unaddressed: the overhaul tests Crossplane's least-privilege
beautifully while the verifier/reaper — **which can now delete EKS/RDS/IAM across the
account that also hosts the management cluster** — runs as unconstrained admin. The
reaper's structural deny-list (§8) protects *which account* it points at, but not
*what privilege* it wields once pointed at the right one. That is the new blast
radius, and "build-coupled" is what concentrated it.

**Fix (must be in finalization):**
1. State explicitly, in §4.1 and §12, the identity each context runs under. The
   build-time live suite MUST NOT inherit the `terraform apply` admin env block.
2. Split the build flow: the `terraform apply` phase uses admin (unavoidable for
   bootstrap); the `tests/live/run.sh` phase **re-scopes to a dedicated
   verifier/reaper role** via an explicit credential swap (assume a separate
   least-privilege role, or run the suite in a separate job/identity), so the suite
   never holds `terraform apply`-grade power.
3. The §3.4 allowlist must be a **committed IAM policy file** (the artifact, not
   prose), the ceiling lint (§3.3) must cover it (already promised), and a static
   push lint must assert the build-flow live phase does NOT reference
   `secrets.AWS_ACCESS_KEY_ID` directly — i.e. that the suite cannot silently run as
   admin. This mirrors §4.2's "wired-and-on-by-default" static invariant; add a
   "runs-under-the-scoped-identity" static invariant alongside it.
4. The reaper's delete blast radius must be bounded by the role policy itself (deny
   on resources lacking the `live-verify` run-id tag), not only by the runtime
   three-predicate AND — defense in depth, since the runtime guard is the thing being
   tested and a bug in it under admin deletes real infrastructure.

Without this, correction #2's honest reading is: "we coupled verification to the
build, and the build is admin, so we coupled verification to admin." My persona
cannot pass the plan with that left implicit.

### C2 — `all-skipped ⇒ RED` is the load-bearing anti-regression invariant, but under the build-coupled model it is enforced *inside* `tests/live/run.sh` — and nothing structurally prevents the build flow from not-invoking it (or invoking it and ignoring its exit code) and still reporting the bring-up green.

Under the old CI model, "all-skipped ⇒ RED" was enforced by a CI check whose
red/green was visible on the PR. Correction #2 moved enforcement to build-time: §4.1
says "`all-skipped ⇒ RED` and the `expect-full` floor apply HERE [in the build]."
§4.2 adds a **static push lint** that the bring-up flow *invokes* `tests/live/run.sh`
as its final phase (grep the flow definition). Good — but that lint proves the
**invocation exists in the committed flow**, not that the build **propagates the
suite's exit code to the build's own pass/fail.** A bring-up flow that runs
`tests/live/run.sh || true`, or runs it and then reports "phase verified" off the
terraform apply result, satisfies the "is-wired" grep lint while making the
all-skipped-⇒-RED invariant a no-op. This is precisely the AGENTS §6.19
("never silence cleanup with `|| true`") failure class, applied to the most
important gate in the plan — and §6.19 exists *because this repo has done exactly
this before* (PR #129).

The plan's own §2 notes `tests/integration/run.sh:40-45` already exits 0 whenever
`FAIL==0`; the inversion lives in the new orchestrator's tabulation. But the
*orchestrator's* honest exit code only matters if the *build* is gated on it. The
static lint as specified (grep for the invocation) does not assert exit-code
propagation.

**Fix:**
1. Strengthen the §4.2 static invariant from "the flow *invokes* `tests/live/run.sh`"
   to "the flow invokes it AND the build's success is **gated on its exit code**" —
   i.e. the invocation must not be `|| true`, must not be backgrounded, and the
   build's final status must be a function of the suite's reserved exit codes (§4.4's
   `exit 3` = `expect-full` violation must fail the build, not just the script).
2. Add a meta-test: a fixture build-flow that invokes a stub `tests/live/run.sh`
   returning `exit 3` must produce a **failed** build; if the harness can't execute
   the real build flow statically, assert the wiring pattern lexically (no `|| true`,
   no `&`, exit code consumed) as a push lint. This is the build-coupled analogue of
   §4.4's existing `phase=test` tabulation suite — the plan tests the *orchestrator's*
   exit code but not the *build's consumption* of it.

This is Critical because it is the seam correction #2 created: the invariant's
enforcement point moved from a visible CI gate to an invocation inside a build flow
the plan does not fully control, and "is-wired" ≠ "is-gating."

---

## MAJOR

### M1 — The §3.4 verifier/reaper allowlist is still prose, not an enumerated artifact — and the exact action set has grown under the build-coupled + RGT-diff + account-mutex design beyond what §3.4 lists.

§3.4 says ship "an explicit allowlist … as a first-class artifact" but lists the
actions inline and partially: `iam:SimulatePrincipalPolicy`, `cloudtrail:LookupEvents`,
`accessanalyzer:*`, `servicequotas:Get*`, `resourcegroupstaggingapi:GetResources`,
"cross-service deletes." That set is now incomplete given the rest of the plan:
- account-mutex needs SSM (`ssm:GetParameter`/`PutParameter`) **or** DynamoDB
  (`dynamodb:GetItem`/`PutItem`/`DeleteItem`) — §8 leaves the choice open, so the
  allowlist can't be written until that's pinned.
- `accessanalyzer:*` is itself a wildcard — my persona will not accept a wildcard in
  the very artifact meant to demonstrate least-privilege (the §3.3 ceiling lint must
  red on it). Enumerate the two or three analyzer read verbs actually used.
- the reaper's "cross-service deletes" must be **enumerated per service**
  (`eks:DeleteCluster`/`DeleteNodegroup`, `rds:DeleteDBInstance`/`DeleteDBSubnetGroup`,
  `iam:DeleteRole`/`DeleteOpenIDConnectProvider`/`DeleteRolePolicy`,
  `secretsmanager:DeleteSecret`, `route53:ChangeResourceRecordSets`) and **tag- or
  path-conditioned** (delete only resources carrying the `live-verify` run-id tag) —
  otherwise the reaper allowlist is "delete anything," which on the shared mgmt
  account is the worst grant in the system.

**Fix:** pin SSM-vs-DynamoDB for the mutex; produce the allowlist as a committed
`.tf`/JSON policy with **zero wildcards** (each `accessanalyzer`/`servicequotas`
verb spelled out) and **tag-condition the reaper deletes**; make the §3.3 ceiling
lint's "no wildcard" rule apply to this file with the same K-cap (it should hit
K=0 here). This is the difference between §3.4 being a real deliverable and being a
TODO that ships as `*`.

### M2 — The `LIVE_MODE=mutating|readonly` safety split is good, but the dangerous default lives in the build flow, which the committable PR only half-controls — and the plan doesn't pin who passes `mutating`.

§4.1 makes `verify ⇒ readonly`, `apply-and-verify ⇒ mutating`, with a unit test that
`verify ⇒ readonly`. That unit test guards the **script's** interpretation of the
arg. It does **not** guard the **build flow's choice of which arg to pass** — and the
build-flow wiring is the jentic/operator half (§12 ledger row 1). A bring-up flow
that passes `mutating` on a `verify`-shaped operation, or that defaults to `mutating`
when the operation is ambiguous, provisions NLBs/IAM/secrets under the admin key
(C1) on what the operator thought was a read-only check. The plan's safety property
("an agent's frequent `verify` calls never provision") depends on the *caller*
passing the right mode, and the caller is exactly the half the static lint can't
fully see.

**Fix:** make the default **fail-closed**: `tests/live/run.sh` with **no
`LIVE_MODE`** must default to `readonly`, never `mutating` — so an under-specified
build-flow invocation degrades to safe, not to provisioning. Add a unit test:
"`tests/live/run.sh` with LIVE_MODE unset ⇒ readonly." Then the build flow must
*opt in* to `mutating` explicitly, and the §4.2 static wiring lint should assert that
the only place `mutating` appears is the `apply-and-verify` branch.

### M3 — Negative-test "guard fired" rigor is strong, but two of the highest-value negatives still ride on log-greps run under the broad identity, and the false-positive (guard-fired vs environment-broken) discriminator isn't pinned for them.

The §7 rule (named reason + positive control in the same fixture) is correct and the
red-first meta-gate (C3.2 from round-2) landed. But:
- **#8 external-dns** corroborating positive and **the confused-deputy family** still
  read "named auth error in pod logs" (§7, matrix #8). Under the build-coupled admin
  identity (C1), a *different* AccessDenied (e.g. the admin key itself throttled, or
  a transient STS error) can surface in logs and a loose grep can mis-credit it as
  "the guard fired." The §8 classifier separates `ENVIRONMENTAL-ROTATION`/`THROTTLE`
  from `AccessDenied-on-restricted-role`, which is the right machinery — but §7's
  log-grep negatives don't state they route through that classifier. A negative that
  passes on the *wrong* AccessDenied is the round-1 "proves absence not guard"
  critical re-entering through a brittle grep.
- The **IRSA confused-deputy** negative (wrong-`sub`/`aud`/issuer denied) is listed
  as an "added negative" but has no home in the matrix or phase plan and no positive
  control named.

**Fix:** require every log-based negative to assert the matched error is classified
as `AccessDenied-on-restricted-role` (not any-AccessDenied) by the §8 classifier, AND
to carry the same-fixture positive control. Give the confused-deputy negative a
matrix row and a phase (P5), with its positive control = the correctly-scoped
`sub`+`aud` trust succeeds. Prefer the **static** form (the §7 m2 fixture lint:
reject a trust policy lacking both `sub` and `aud` `StringEquals` or using
`Principal:"*"`) as PRIMARY, since it has no identity/log fragility at all.

### M4 — Blocker #6 (ArgoCD app-controller SA missing IRSA) is now correctly tested on both SAs, but the matrix credits a behavioral catch that depends on the unconfirmed spoke-API operator dependency — and the static fallback is weaker than the plan implies.

Grounded: `irsa.tf:21-29` trusts **both** `argocd:argocd-server` and
`argocd:argocd-application-controller` and attaches **no** policy (`role_policy_arns =
{}`). So the blocker-#6 shape is "the SA isn't annotated / the trust subject is
wrong," which `irsa_trust_validator.py` catches statically — but the matrix #6
PRE-FLIGHT only names `test_argocd_controller_irsa.sh` (annotation presence) and
routes the *real* behavioral proof (controller `AssumeRoleWithWebIdentity` succeeds /
spoke registration works) through the **§14-conditional spoke-API path**. With
`role_policy_arns = {}`, the controller's AssumeRole can *succeed* and the role still
grant nothing — so "AssumeRole success in CloudTrail" (the §5/§13 fallback proxy) is
a **weaker** signal here than for other blockers: it proves identity, not capability.

**Fix:** add `argocd:argocd-application-controller` to the `irsa_trust_validator.py
--all` sweep explicitly (confirm it's in the SA fleet the validator walks), and state
that for #6 the static trust+annotation check is PRIMARY (since the empty policy means
behavioral AssumeRole-success under-proves). If the controller is *supposed* to carry
a policy for spoke registration, the empty `role_policy_arns` is itself a finding to
flag to the owner — note it in §14 residual risks.

---

## MINOR

### m1 — §4.3 fail-closed-on-missing-oracle is correct, but the HEAD-SHA "static evidence marker" is a committed file an agent can hand-write. A green marker with no real build behind it re-opens the self-attestation hole §4.3 just closed (one level further up). Require the marker to be machine-emitted by `tests/live/run.sh` itself (carrying the suite's reserved exit-code summary + run-id), and add a lint that a marker's SHA matches a real suite-result structure, not free text.

### m2 — §3.2 gate item 2 checks "no `AWS_ACCESS_KEY_ID` in the provider pod env." Good — but given C1, the same check should also assert the **verifier/reaper** isn't running with a static-cred ProviderConfig or admin env when it performs its mutations. The "no static creds" property is asserted for the controller and silently dropped for the suite. Extend the no-static-creds assertion to the suite's own identity.

### m3 — §8 account-mutex lease TTL "< reaper age-floor" (so a dead holder self-expires) is right, but a lease that expires while a 20-min EKS build is still mid-flight lets a second run start and the reaper's age-floor (≥45 min) won't yet protect the first run's young resources. The TTL must be ≥ the longest single mutex-holding operation, not just < age-floor — state both bounds (age-floor > TTL ≥ slowest-held-op) or the two guards have a gap.

### m4 — §7 EKS `CONFIG_MAP` composition-text lint (matrix #1 PRE-FLIGHT) is grounded (`platform-cluster:320` hardcodes `API_AND_CONFIG_MAP`) and correctly *not* an admission negative. Minor: the lint asserts membership in `{API, API_AND_CONFIG_MAP}`, but the blocker was specifically `CONFIG_MAP`-only (no API). Assert the value **contains `API`**, not just "is in the allowed set," so a future hand-edit to bare `API_AND_CONFIG_MAP`→`CONFIG_MAP` can't slip a typo'd allowed-looking value through.

### m5 — §3.3 still describes `simulate-principal-policy` as needing correct `--resource-arns` per statement scope (k8-platform/* for ASM, hostedzone ARN for Route53Validation). Grounded against `irsa.tf:117,148`. Good — but the simulate caller needs `iam:SimulatePrincipalPolicy`, which belongs in the M1 allowlist; cross-reference it so the floor oracle doesn't silently re-require an un-enumerated grant on the verifier identity (the round-2 C2.2 trap, in miniature).

---

## What finalization must NOT lose (ranked)

1. **The §3.1/§3.2 NON-GOAL spine** — no new AssumeRole principal, no trust
   widening, no provider-SA token mount, no probe pod; identity proven by
   driving the real controller + the in-band `source: IRSA` + no-static-creds +
   Healthy gate. This is the security center and it survived. Any "make it easier"
   edit that reaches for a probe SA re-opens the exact bloat the overhaul exists for.
2. **A scoped identity for the suite itself (C1)** — the build-coupled trigger must
   not run the verifier/reaper as the `terraform apply` admin key. This is the one
   thing the corrections changed for the worse and must be fixed before P3/P4.
3. **`all-skipped ⇒ RED` gated on the suite's exit code at build-time (C2)** — wired
   ≠ gating; no `|| true`, exit code consumed by the build's pass/fail.
4. **Guard-fired negatives with the red-first meta-gate + same-fixture positive
   control, classified AccessDenied (not any-AccessDenied)** — never let a negative
   degrade to "asserts some failure" or pass on the wrong error.
5. **Synthetic-secret-only + redaction (incl. ARN/account-id masking on the PR
   summary)** on the v2-ported claim-verify decode path — the one concrete
   plaintext-spill vector in the repo.

## The one new systemic flaw correction #2 introduced

**Build-coupling solved the trigger problem and concentrated the identity problem.**
The plan's identity gate proves the *controller* runs under restricted IRSA — but the
*suite* that drives, observes, and reaps now runs inside `apply-and-verify`
(`terraform-test.yml:24,41-43`), which is the admin CI key against the account that
also hosts the management cluster. §3.4 named the risk under the old model; the
correction made it sharper and the plan didn't re-reckon it. Finalization must split
the build flow's identity — admin for `terraform apply`, a **zero-wildcard,
tag-conditioned verifier/reaper role** for `tests/live/run.sh` — and add a static
push lint that the live phase cannot inherit the admin env block. Otherwise the
overhaul's net least-privilege effect is to move the over-privileged principal from
Crossplane (now tested) to the build's verifier (now admin, now able to delete EKS/
RDS/IAM account-wide), which is a worse blast radius than the one it retired.
