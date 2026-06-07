# Round-2 Adversarial Review — SRE / Production-Operations Persona

**Target:** `planning/test-overhaul/synthesis/SYNTHESIZED-PLAN.md`
**Reviewer lens:** skeptical SRE — real-cloud latency/flakiness, false-fail rate,
isolation/cleanup leaks on an ephemeral billed account, total wall-clock and $ per
bring-up, the ~20-min EKS, parallelism/rate-limits, blast radius against the live
hub developers depend on, and whether "on by default" survives a long
occasionally-red suite.

**Method:** read the plan cold and fully, then grounded its load-bearing factual
claims against the repo (`tests/integration/run.sh`, `terraform/management/irsa.tf`,
`tests/chainsaw/run.sh`, `policies/audit/*`, `scripts/wait-for-claim.sh`,
`crossplane-claim-verify` skill, `crossplane/compositions/platform-cluster.yaml`).

## Grounding results (what actually checks out)

The plan's diagnosis is honest and its repo claims are accurate:

- `tests/integration/run.sh` **does** exit 0 whenever `FAIL==0`; rc=2 (SKIP) never
  fails. The plan's central "all-skipped reads green" premise is real (verified
  lines 26-45).
- IRSA trust subject **is** exactly one SA
  (`crossplane-system:upbound-provider-family-aws`, irsa.tf ~173) — the probe-SA
  rejection in §2.1/§13 is correct.
- The missing actions are **already granted** (irsa.tf 60-106: `iam:Tag*`,
  `iam:UpdateAssumeRolePolicy`, `iam:GetRolePolicy`, full `rds:*` set) — so §2.3's
  "can't produce a live AccessDenied without role-mutation/crippled-twin" is correct.
- All 12 Kyverno policies are `validationFailureAction: Audit`; **zero** Enforce —
  §6's "an Audit policy guard blocks nothing" is correct.
- `crossplane-claim-verify` **does** base64-decode secret `data` (`@base64d`) and
  dump `SecretString` — §7.3's redaction concern is real.
- chainsaw ASM secrets **are** tagged `k8-platform/<XR-uid>`, never a run-prefix —
  §7.2's leak-by-wrong-tag warning is real.
- EKS `authenticationMode: API_AND_CONFIG_MAP` **is** set in the composition — the
  blocker-#1 fix is in place; the plan only needs to defend it.

This is a serious, well-grounded plan. My findings are about whether its claimed
*resolutions operationally hold*, and what the merge of 3 plans + 9 reviews broke.

---

## CRITICAL

### C1. `simulate-principal-policy` cannot prove the gaps it is sold as proving — the policy is `Resource:"*"`
This is the most important finding and it strikes the plan's load-bearing
mechanism. §2.3, §4.3, §5 (EKS create-path), and the §10 matrix rows 2-5,8 all rest
on `aws iam simulate-principal-policy` as the *faithful, free* completeness proof
for the IRSA-permission blocker class — explicitly the thing that "would have caught
the `rds:*` and `iam:Tag*` gaps at push time" and the substitute for instantiating
EKS/RDS.

Grounding the real policy (irsa.tf): every high-value statement is
`Resource = "*"` — EKS (`eks:*`/`*`), IAM (`*`), RDS (`*`), EC2 (`*`), ACM (`*`).
`simulate-principal-policy` evaluates an action **against a resource ARN** and the
SCP/boundary/identity set. Two failure modes the plan never addresses:

1. **False-green on completeness.** With `Action: eks:*` + `Resource:"*"`,
   simulate returns `allowed` for essentially every `eks:` action whether or not the
   Composition needs it, whether or not it is even a real action. The check that is
   supposed to catch "missing `iam:TagOpenIDConnectProvider`" only catches it if the
   *enumeration of required actions is itself complete and correct* — and that
   enumeration is the exact thing auto-012 got wrong. simulate validates the policy
   against a list you hand it; it cannot tell you the list is missing an entry. The
   gap that bit production (an action nobody listed) is precisely the gap simulate is
   blind to. **The plan overstates simulate as catching the historical blockers; it
   would only catch them if someone had already thought to enumerate the action — in
   which case they'd have added the grant.** This is circular.
   - *How it bites:* P1 ships, the dashboard goes green, everyone believes the
     IRSA-permission class is now push-gated. The next missing-action blocker (a
     `pi:*` for RDS Performance Insights, an `ec2:CreateSecurityGroup` for a new
     networking path) is invisible exactly as auto-012 was, and the team has *more*
     false confidence than before.
   - *Fix:* the **real** completeness signal is the BRING-UP positive (drive the
     controller; a missing action surfaces as a real `AccessDenied`) plus the §4.2
     **CloudTrail-exercised-action diff** (the *granted-minus-exercised* set). Demote
     simulate from "the faithful completeness proof" to "a cheap sanity floor that
     the enumerated set is grantable." State explicitly in §2.3/§5 that simulate
     does **not** cover the unknown-missing-action case and that EKS/RDS create-path
     permission completeness is therefore **genuinely** only covered after-the-fact
     by the one real build's CloudTrail — accept that the expensive class has weaker
     coverage than the plan currently claims, rather than papering it with a tool
     that can't see the gap.

2. **The deny tests (§4.4) are under-specified to the point of being unfalsifiable
   on this policy.** "Assert the role cannot create a role outside the platform
   path" / "`rds:DeleteDBInstance` on an out-of-scope ARN" — but the policy grants
   `iam:CreateRole`/`rds:DeleteDBInstance` on `Resource:"*"`. simulate **will return
   `allowed`** for those out-of-scope ARNs, because the policy genuinely allows them.
   The deny test as written **fails against the current, intended policy** — it is
   asserting a least-privilege posture the policy does not have and the plan does not
   propose changing. So either P1 ships a red test (blocks the stack) or someone
   "fixes" it by weakening the assertion (the §6.24 anti-pattern).
   - *Fix:* the deny tests must come **bundled with the resource-scoping tightening
     they assume** (path-condition on `iam:CreateRole`, ARN-scope on RDS) as a
     single PR, or be dropped. A deny test that red-lights the current intended
     state is not a test, it's a TODO. Decide in finalization: are we tightening
     `Resource:"*"` (real work, real blast-radius on the live provider role) or not?
     If not, §4.4 is vapor.

### C2. The reaper "runs FIRST" + "refuse unless caller == ephemeral account" is a self-DoS against the only enforcement vehicle, and races concurrent runs
§7.2 mandates the tag+run-id+age reaper as **step 1 of every bundle**, and §3
makes the bundle run **on every `apply-and-verify`** by default. Compose these:

- **The reaper's age-floor vs the run-id is mutually exclusive in the common path.**
  A reaper keyed on `label + run-id-prefix + age-floor` (all three required, §7.2)
  deletes nothing for the *current* run (run-id is unique, nothing old matches) — so
  as step 1 it is a no-op that still costs N `resourcegroupstaggingapi` +
  `Describe`/`Delete` calls and STS verification on every single bring-up. To
  actually reap *orphans from prior runs* it must drop the current run-id and sweep
  by `label + age-floor` across **all** run-ids — at which point on a shared account
  it can delete **another in-flight run's** resources that happen to be older than
  the floor but still live (the concurrency interlock in §7.1 is a hub-k8s mutex; it
  does **not** gate AWS-side resources created by a parallel terraform-test on a
  *different* cluster against the *same* account). The plan's own §7.1 admits
  "expected concurrency: serialized per hub" — but the reaper operates per *account*,
  which is broader than per-hub.
  - *How it bites:* developer A's spoke bring-up is mid-flight (EKS at minute 12);
    developer B's hub `apply-and-verify` runs the reaper-first, sees A's run-id IAM
    role older than the age-floor, deletes it → A's EKS reconcile fails with
    AccessDenied → looks **exactly** like an IRSA blocker → false-fail, wasted
    20-min build, and the §7.4 classifier can't save it because it *is* a real
    AccessDenied, just self-inflicted by the sibling reaper.
  - *Fix:* the reaper must be **account-mutex'd, not just hub-mutex'd** (a lease on a
    well-known SSM param / DynamoDB item keyed on the account), and its age-floor
    must be **larger than the longest legitimate build** (EKS ~20min ⇒ floor ≥ 45min,
    not a generic "age floor"). State the floor as a concrete number tied to the
    slowest resource, and forbid the reaper from deleting any resource whose run-id
    is in the live active-run-id registry (§7.1) regardless of age. Without this,
    reaper-runs-first is a friendly-fire generator on the exact account the plan is
    trying to protect.

- **"Refuse to run unless `sts get-caller-identity` is the expected ephemeral
  account" (§7.2/security-C M4) bricks the suite on rotation.** The account rotates
  between sessions (§8.1). "Expected ephemeral account" is not a durable value
  (§8.1 forbids hardcoding it). So either the check reads the account from a
  committed file (which is stale the moment the account rotates → reaper refuses →
  step-1 abort → **whole bring-up bundle fails** every first run on a new account),
  or it reads it from the live API (in which case it always matches and the guard is
  a no-op providing no safety). The plan asserts this guard without resolving the
  ephemeral-account tension it documents elsewhere.
  - *Fix:* the guard must be a **structural** assertion ("the account is NOT the
    known production/management long-lived account" via a committed *deny*-list of
    forbidden account IDs, which IS durable) rather than an *allow*-match against an
    ephemeral ID. Frame it as "fail-closed if we're pointed at a protected account,"
    not "fail-closed unless we're pointed at the blessed one."

### C3. "On by default at the end of every `apply-and-verify`" has no implementable hook the plan can build, and the one it names contradicts §5's read-only rule
§3.1 and §8 hinge on the live bundle running "automatically at the end of every
`apply-and-verify`." Grounding: `apply-and-verify` is a **`terraform-test.yml`
workflow_dispatch action** (`compute-gates.sh`: `mp=true; ma=true; mv=true`), and the
plan's own §3.4/§13 hard constraint is **this environment cannot create or edit
`.github/workflows/*`**. So:

- The only place to "hook the end of apply-and-verify" is inside
  `terraform-test.yml`'s verify step — **a workflow file the plan says it cannot
  touch.** The plan routes the *enforcement gate* through `tests/unit/run.sh` to
  dodge this (§3.4, good), but it never resolves the same constraint for the
  **trigger**. "Runs at the end of every apply-and-verify" is therefore an
  **operator dependency disguised as a delivered mechanism** — identical to the
  "stranded enforcement" flaw the plan congratulates itself on fixing for the gate.
  - *How it bites:* P2 says "wire `run.sh` into `apply-and-verify`." The PR cannot
    do it (workflow edit). It either gets stranded waiting on an operator, or
    someone calls `tests/live/run.sh` from a script that the workflow *already*
    invokes — which must be identified now, not assumed. If no such already-invoked
    script exists, requirement #1 ("runs EVERY cluster bring-up, on by default")
    **is not deliverable in this environment** and that must be stated as the #1
    residual risk, not buried.
  - *Fix:* in finalization, name the **exact existing invoked script**
    (`terraform-test.yml` already runs an e2e-verify step — find what shell entry it
    calls and append there, the same lever §3.4 uses for the gate) OR declare the
    trigger an explicit operator handoff. Do not let "on by default" rest on a
    workflow edit the environment forbids.

- **`verify` vs `apply-and-verify` collision with §5's read-only rule.** §5 (sre-C
  M2) correctly says the mutating BRING-UP bucket runs only on `apply-and-verify`,
  not `verify`. But `compute-gates.sh` shows `verify` and `apply-and-verify` share
  the **same `mv=true` verify gate** — the verify step is one code path
  parameterized by action. The split "mutate only on apply-and-verify" therefore has
  to be enforced **inside `tests/live/run.sh` by reading the action**, and the plan
  never says how `run.sh` learns which action invoked it. If it can't tell, either
  `verify` provisions NLBs/IAM every agent call (the exact thing §5 forbids) or
  `apply-and-verify` skips them (requirement #4 unmet).
  - *Fix:* pass the action explicitly into `run.sh` (`LIVE_MODE=mutating|readonly`)
    and unit-test that `verify` ⇒ readonly. Make this a P1 invariant, not a P2
    detail.

---

## MAJOR

### M1. The "executed-floor / expect-full" anti-silent-regression core depends on a phase→resource map that does not exist and is the plan's own #4 residual risk — yet it gates requirement #2
§3.3 is the load-bearing anti-green mechanism: `expect-full` is set by "what the
bring-up intended (the `apply-and-verify` knows which phase it applied → sets
`expect-full` for that phase's resources)." But `apply-and-verify` is a terraform
action; **Crossplane spoke resources are not applied by terraform** (§8 admits "no
`terraform/spoke`"). So "which phase applied" for the *spoke* resources — where 6/8
blockers live — is not knowable from the terraform action at all. §8's resolution
("key off the spoke EKS XR reaching Ready") is circular: the floor exists to catch
the spoke XR *never becoming Ready / silently missing*; you can't key the
did-we-expect-it signal off the very Ready condition you're trying to verify.
- *How it bites:* a hub-only `apply-and-verify` legitimately skips spoke checks
  (phase-not-applied, green — correct). But a run that *should* have built a spoke
  and the spoke XR never got created at all (the silent-never-provisioned shape,
  blocker #5) ALSO presents as "no spoke XR Ready" ⇒ phase-not-applied ⇒ green. The
  mechanism cannot distinguish "no spoke requested" from "spoke requested but
  silently absent" without an **independent declaration of intent** that does not
  derive from the resource's own status.
- *Fix:* the intent signal must be an **explicit input** to the bundle (a committed
  desired-spoke-set, or an arg the dispatcher passes: `EXPECT_SPOKES=foo,bar`), diffed
  against observed. The plan must stop deriving intent from status. This is residual
  risk #4 — but it is not a residual *risk*, it is a **design hole in the central
  guarantee for requirement #2** and must be closed in the plan, not deferred to
  implementation.

### M2. False-fail SLO < 2% is set as a number with no baseline and no consequence wired to "on by default"
§11 ties on-by-default to a measured < 2% false-fail SLO — good instinct — but (a)
2% is asserted with zero baseline data on a suite that doesn't exist yet, and (b)
nothing in the plan says what happens when the SLO is **breached**. The whole premise
(persona brief) is "does on-by-default survive a long occasionally-red suite or get
switched off." A 2% target on a ~10-check live bundle means ~1 in 5 full bring-ups
shows a red — and a developer who sees red on their unrelated infra change *will*
reach for `LIVE_VERIFY=0`. The plan guards the *switch* (§3.2 master-switch is red
unless registered) but does not guard against the **social** disable: people stop
trusting and route around it.
- *Fix:* (1) state the SLO as "measured from day one, target ratcheted down from
  whatever P2 actually exhibits," not a pre-committed 2%. (2) Wire a **consequence**:
  SLO breach auto-quarantines the offending check (§11 has the quarantine mechanism —
  connect it) so a flaky check degrades to non-gating *automatically* rather than
  pressuring a human to kill the whole bundle. (3) Crucially separate
  **per-check** red from **bundle** red: one flaky DNS check must not red the whole
  bring-up; only an `expect-full` miss or a real AccessDenied does. The plan
  conflates these.

### M3. CloudTrail-based identity assertion and exercised-action diff share an unbounded-latency dependency the plan flags but builds on anyway
§2.2 (identity == expected ARN via CloudTrail `userIdentity.arn`) and §4.2
(exercised-action diff via CloudTrail) both depend on CloudTrail, whose delivery
latency is **routinely 5-15 minutes and occasionally longer**. §2.2 offers an
alternative (`aws sts get-caller-identity` from a pod using the provider SA) — but
that pod **is** the probe-SA the plan spent §2.1/§13 proving cannot assume the role.
A pod running as the provider SA *can* call STS (it has the token), but standing up
such a pod is exactly the "mount/copy the provider SA's projected token into a probe
pod" NON-GOAL in §2.1. So the two stated mechanisms for the identity assertion are:
CloudTrail (too slow for an in-bundle gate) or a pod the plan forbids.
- *How it bites:* the identity assertion either makes every bring-up wait 10+ min for
  CloudTrail (blows the §11 wall-clock ceiling, defeats "cheap sec-min") or silently
  degrades to "Synced + cloud-exists" (residual risk #1) — at which point "under real
  IRSA" is **un-asserted again**, the exact security-A C1 finding the plan claims to
  resolve.
- *Fix:* resolve the contradiction explicitly. The clean answer: read the identity
  from the **provisioned MR's own `status`/annotations** (the provider records the
  caller context on the managed resource without a probe pod and without CloudTrail),
  or accept the degraded assertion and **say so in §2.2** rather than claiming a
  falsifiable identity proof the bundle can't actually run in budget. Do not leave
  this as a residual risk; it determines whether CRITICAL-#1's resolution holds.

### M4. Quota fail-closed math is wrong for the resources the plan actually creates
§7.1 quota guard: `headroom = 9 - (mgmt + spoke + in-flight)`, cap concurrency to
`min(N, headroom)`. But §7.1 also (correctly) steers the default BRING-UP set to
**zero-instance** kinds (IAM/secret/DNS/cert). The EC2-quota-of-9 math applies to
EC2 instances / EKS nodegroups — which the default set deliberately doesn't create.
Meanwhile the resources the cheap set *does* create (IAM roles, OIDC providers, ACM
certs, ASM secrets) have their **own** account limits (IAM roles default 1000, OIDC
providers 100, ACM certs per-region, ASM secret name-recovery windows §7.2) that the
headroom formula ignores entirely. The plan guards the quota that won't be hit and
ignores the ones that will (notably ACM cert-per-region and the ASM 7-30d recovery
window on rapid re-runs, which §7.2 itself flags).
- *Fix:* drop the EC2-9 formula from the default-set path (it's only relevant to the
  forbidden instance-backed tests) and replace it with the **actual** limits of the
  cheap kinds, with `force-delete-without-recovery` for ASM (already noted) and a
  cert-reuse strategy so rapid red-CI loops don't exhaust ACM. State per-kind limits,
  not one EC2 number.

### M5. "Reaper remediates → non-empty leak set FAILS the run (RED)" will make transient AWS eventual-consistency a recurring false-fail
§7.2 (security-B C3): a non-empty leak set fails the run red. But teardown of
Crossplane-managed resources is **asynchronous and eventually-consistent** — a
`kubectl delete ns` / claim-delete returns before AWS has finished deprovisioning
(EKS deletion alone is minutes). If the post-teardown leak-scan runs immediately, it
will routinely find resources mid-deletion and red the run. The plan has a bounded-
poll helper (§11) for *provisioning* consistency but does not apply it to the
*teardown* leak-scan.
- *Fix:* the leak-scan must be a **bounded poll-until-empty** with a teardown budget
  (per resource class), and only red after the budget expires — and it must
  distinguish `DELETING`/`ScheduledForDeletion` state (in-progress, wait) from
  `ACTIVE` orphan (real leak, red). Without this, "leak ⇒ RED" is a false-fail
  factory that gets the suite disabled — the precise §12/persona failure mode.

### M6. Concurrency model is "serial per hub" but the plan never says serial across *what dispatches*, and agents dispatch in parallel by design
§7.1 says serialized per hub via a lease/ConfigMap or a GH Actions `concurrency:`
group. But (a) the GH `concurrency:` option requires editing a workflow (forbidden,
§3.4), leaving only the in-cluster lease; and (b) AGENTS §6.6 explicitly puts agents
in a **parallel stacked-PR throughput mode** where multiple `apply-and-verify`
dispatches against the same hub are routine. The in-cluster lease must therefore
handle: lease acquisition timeout (what does a bring-up do when another holds the
lease — block for 20 min? fail? skip-green?), lease staleness (holder SIGKILLed mid-
run, §6.20 sandbox-suspend), and lease ownership across the CI/cluster boundary. The
plan names the lease but specifies none of this, and "skip-green on lease-held" would
silently violate requirement #1.
- *Fix:* specify lease-held behavior as **block-with-timeout-then-FAIL** (never
  skip-green), specify lease TTL < the reaper age-floor so a dead holder's lease
  self-expires, and unit-test that a held lease does not produce a green skip.

### M7. The hub→spoke behavioral checks (#1, #6) are gated on CI reaching the spoke kube-API, which the plan's own residual risk #2 says may be impossible
The §10 matrix sells the *behavioral* upgrades (#1 "hub app-controller can
`kubectl get ns` on spoke"; #6 "controller pod actually AssumeRoleWithWebIdentity")
as the headline improvements over "manifest-says-X." Grounding (§6.26/§6.27): the
spoke kube-API is a **private CA, unreachable from the sandbox**, and residual risk
#2 admits CI may not be able to reach it either and "may be blocked." So the two
flagship behavioral assertions may be **undeliverable**, leaving exactly the
config-only (lint) checks the plan disparages. The matrix presents them as "both"
(push + bring-up) coverage with no asterisk.
- *Fix:* mark #1/#6 behavioral rows as **conditional on the spoke-API-from-CI
  operator dependency** in the matrix itself (not only in residual risk #2), and
  define the fallback assertion explicitly (e.g. AccessEntry row + the app-controller
  AssumeRole **success in CloudTrail** as a weaker-but-real behavioral proxy) so the
  acceptance criterion isn't silently downgraded to a lint during implementation.

---

## MINOR

### m1. `test_live_coverage.sh` is named as existing-pattern-extension but does not exist
§3.5/§10 reference `test_live_coverage.sh` and "extend the existing
`test_iam_required_actions.sh`." Grounded: `test_iam_required_actions.sh` exists,
`test_live_coverage.sh` does not. Fine (it's net-new), but the plan's phrasing in §10
("a unit test that every row names a test file that exists") is itself a test that
will red on day one because most named live tests don't exist yet. Sequence it: the
matrix-completeness meta-test lands **last** in each PR's slice, asserting only the
rows that PR delivered — else P1 ships red.

### m2. Wall-clock ceiling (§11) vs reaper-first (§7.2) vs CloudTrail-wait (§2.2) are three time budgets that aren't reconciled
A per-bundle hard ceiling, a reaper sweep at step 1, bounded provisioning polls, a
teardown poll (M5), and a possible CloudTrail wait (M3) all consume the same wall-
clock envelope. The plan sets a ceiling but never sums the floor. Provide a worked
example: reaper (~30s) + provision cheap MRs (~2-3min) + identity assert (?) +
teardown poll (~?) must fit under the ceiling with margin, or the ceiling itself
becomes a false-fail source. Publish the budget breakdown, not just the cap.

### m3. `force-delete-without-recovery` on ASM removes the recovery safety net on the same account that hosts real platform secrets
§7.2 mandates `force-delete-without-recovery` for test secrets so re-runs don't hit
`ScheduledForDeletion`. Correct for test secrets, but this is a foot-gun if the
name-matching is ever wrong (and §7.2 itself documents the repo mixes
`k8-platform`/`k8s-platform` prefixes). A force-delete with a prefix typo that
matches a real secret is unrecoverable. Gate force-delete behind the **run-id**
substring (not just the platform prefix) and assert the name contains the live run-id
before force-deleting — defense matching §7.2's own "pin the exact label" rule.

### m4. The plan is ~660 lines and will not survive as the operational spec
DevX collapsed six tiers to three buckets (good), but the synthesis itself is now the
ontology: 14 sections, cross-refs to 9 round-1 findings by ID, two tags, three skip
states, a register, a baseline file, an SLO, a quarantine lane. The persona's core
worry — "does on-by-default survive" — partly depends on whether an on-call engineer
at 2am can read the runbook. Extract a one-page operator contract (what runs, what
reds, how to legitimately skip, where the leak-scan output is) separate from this
rationale doc. Not a finding against correctness; a finding against durability.

---

## What must NOT be weakened during finalization

1. **The probe-SA rejection + the §2.1 NON-GOAL** (no new AssumeRole principal, no
   widened trust, no token-copy). This is the single correct architectural decision
   in the plan and the whole anti-bloat thesis depends on it. Every pressure point
   above (M3 identity assertion, the CloudTrail latency squeeze) will tempt someone
   to "just stand up a probe pod." Do not.
2. **`all-skipped ⇒ RED, by construction` + master-switch-guarded + the
   `expect-full` FAIL-on-missing semantics** (§3.2/§3.3). This is requirement #2 and
   the entire reason the overhaul exists. C3/M1 attack the *plumbing* of intent, not
   this invariant — fix the plumbing, never relax the invariant to "skip is green if
   we're not sure."
3. **The honest demotion this review forces** (C1): do not let finalization restore
   `simulate-principal-policy` to "the faithful completeness proof." The faithful
   proof is the real controller under real IRSA + CloudTrail-exercised diff; simulate
   is a floor. Weakening this back to "simulate covers it" re-creates auto-012's
   exact blind spot with a green light over it.
4. **Reaper/leak-scan must REMEDIATE-and-RED, never report-and-pass** — but only
   after the bounded teardown poll (M5) and account-mutex (C2). The remediate
   semantics is right; the timing/scoping must be fixed *without* downgrading to a
   footnote.

---

*Bottom line:* the plan's diagnosis and its central architectural call (drive the
real controller, reject the probe SA) are correct and well-grounded. But three of its
claimed resolutions rest on mechanisms that don't hold operationally: `simulate-
principal-policy` is blind to the unknown-missing-action gap on a `Resource:"*"`
policy (C1), the on-every-apply-and-verify trigger needs a workflow edit the
environment forbids (C3), and the reaper-runs-first is a friendly-fire generator on
the shared ephemeral account (C2). Fix those three before P4 is built on them.
