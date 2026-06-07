# Adversarial Review — PLAN-A (Claude lead)

**Reviewer persona:** skeptical SRE / production-ops. Lens: real-cloud latency &
transient failure, flakiness, isolation/cleanup leaks (= money on an ephemeral
account), wall-clock + $ per run, the ~20-min EKS create, parallelism/rate
limits, blast radius against the LIVE cluster developers depend on, and whether
"on by default" survives a long occasionally-red suite or just gets switched off.

Grounding done in-repo (cited where load-bearing):
- `.github/workflows/terraform-test.yml` is **one monolithic job** (apply →
  e2e-verify → optional destroy, fail-fast). There is **no separate spoke
  bring-up job**; `terraform/` contains only `base/` and `management/`. Spoke
  EKS is provisioned by **Crossplane reconciliation**, not by a terraform job.
- `[management] e2e-verify` (lines 315–384) already does much of "L2a":
  EKS ACTIVE, ≥1 Ready node, Running pods in 5 namespaces, argocd-server SA IRSA
  annotation, ArgoCD ingress host. `[management] argocd-url` is
  `continue-on-error: true`.
- `tests/integration/run.sh` + `lib/test-lib.sh` already implement RUN_ID,
  `add_cleanup`/`trap run_cleanup EXIT`, `KEEP=1`, and exit-code 2 = SKIP.
- `scripts/wait-for-claim.sh` polls Ready, `set -uo pipefail`, unconditional
  `exit 1` on timeout (no `-e`, no `|| true`).
- `crossplane-claim-verify` skill exists and waits Synced/Ready + cloud check.

The plan is directionally correct (L2-live-under-real-IRSA is the right core,
and the IRSA permission-completeness probe is genuinely the highest-value idea).
But as an operational artifact it is dangerously thin on the things that decide
whether this survives reality. Findings below, ranked.

---

## CRITICAL

### C1 — "Every cluster bring-up runs it" has no hook for the SPOKE bring-up; the spoke is exactly where 6 of 8 blockers lived
Plan §2 says the verifier runs "at the end of every apply-and-verify / cluster
bring-up" and §9 answers "where the dev cluster comes from" with "the mgmt
cluster we always build first." But the **spoke** EKS is not built by a
terraform job — it is reconciled by Crossplane from an XR with **no job boundary
to hang an "end-of-bring-up" hook on**. There is no `terraform/spoke`. The plan's
single entrypoint wired "into apply-and-verify" (§2, §8 P1) attaches to the
mgmt-cluster job and will **never fire for spoke creation**. Per the coverage
matrix (§5), the spoke is where authenticationMode, the AppProject IngressClass,
subnet tags, and the ArgoCD controller-SA blocker actually bite.

*How it bites:* the headline promise ("live verification runs EVERY cluster
bring-up") is structurally false for the cluster type that caused the incident.
A spoke comes up green (Crossplane Synced/Ready) while the access-entry / NLB /
sync failures are still latent, exactly as in auto-012.

*Fix:* the plan must define the spoke verification trigger explicitly. Either
(a) a Kyverno/controller-driven post-reconcile hook that runs L2a against each
new spoke when its EKS XR goes Ready, or (b) the L4 hub→spoke flow is **promoted
out of P4 into the on-by-default core** and made the spoke's bring-up gate, with
its own wait+verify keyed off the XR. Amend §2, §5, §8 to name the spoke trigger
mechanism. This is the single biggest hole.

### C2 — Fail-fast monolithic job + on-by-default L2/L4 = the verifier becomes the thing that gets switched off
terraform-test.yml is one job; e2e-verify failing **fails the whole run** and (by
gate logic) blocks the session's "phase verified." Bolting L2b instantiate/teardown
+ L3 negative + L4 e2e into that same fail-fast path means **any one flaky live
assertion reds the entire bring-up**, including the parts that succeeded. On an
ephemeral account with real-cloud latency this WILL go red intermittently. §2's
own escape hatch (`PLATFORM_VERIFY=off`, `SKIP_L2=1`) is precisely the lever a
frustrated operator pulls at 2am — and §6.24 of AGENTS.md forbids weakening a
check to get green, so the operator is cornered into either a real fix or the
documented-but-discouraged skip. The plan acknowledges the lever exists but does
**nothing** to make the suite reliable enough that the lever stays unpulled.

*How it bites:* "on by default" survives about two red weeks before someone sets
the env var "just for this rebuild" and never unsets it. The skip-guard (§2)
only protects *protected branches*; it does nothing for the operator running a
manual `workflow_dispatch` rebuild, which is how this repo actually applies
(terraform-test.yml is `workflow_dispatch`-only).

*Fix:* (1) Separate the live behavioral suite into its **own job/steps with
per-layer outcomes** so a flaky L4 does not erase a green L2a apply — report
each layer's result independently and gate "phase verified" on the aggregate,
not on fail-fast ordering. (2) Define a **flake budget + mandatory retry policy
with bounded backoff** for every live assertion (the plan says "bounded waits +
retries" in §9 but sets no numbers and no quarantine path). (3) The skip-guard
must also assert the flag on `workflow_dispatch` runs, not just protected
branches. Amend §2 and §7.

### C3 — Cleanup/isolation is hand-waved for the resource classes that actually leak money, and there is no orphan sweep
§7 and §9 say "per-run-ID prefixing + a guaranteed cleanup trap (the chainsaw
pattern)." That trap is an `EXIT` trap **inside a single shell** (confirmed in
`test-lib.sh`). It does **not** survive: a CI runner killed mid-run (the most
common real cause of orphans), a `SIGKILL`, an OOM, or the job being cancelled —
all of which happen. L2b proposes creating real IAM roles, OIDC providers, S3
buckets, Secrets Manager secrets, Route53 records, **ArgoCD cluster
registrations** per run. On a rotated/ephemeral account these orphans cost money
and, worse, **collide**: Secrets Manager has a 7–30 day mandatory recovery
window (a re-run with the same prefix hits `ScheduledForDeletion`), OIDC
providers and IAM roles are account-global and name-collide across parallel runs,
Route53 records left behind poison the next external-dns test.

*How it bites:* the account fills with `test-<runid>-*` IAM roles / orphaned
secrets in deletion-pending; parallel L2b runs (which §7 *encourages*) collide
on global names; the ephemeral-account teardown the plan leans on (§7 "ephemeral
is an asset") is the ONLY thing actually cleaning up — which means cleanup is not
really tested, just deferred to account rotation.

*Fix:* the plan needs a dedicated **orphan-sweep / reaper** section: a
tag-based (`test.k8-platform/ephemeral=true` + run-id + creation-timestamp)
pre-run AND post-run sweep that deletes anything older than N hours regardless of
whether the owning job's trap fired. Specify `force-delete-without-recovery` for
Secrets Manager test secrets. Specify per-run-id **namespacing of global
resources** (IAM role names, OIDC) and a concurrency guard so two L2b runs can't
race the same name. Amend §7 and §9 (the §9 "isolation" bullet is one line; it
needs to be a design).

### C4 — Blast radius: L2b/L3/L4 run against the LIVE mgmt cluster developers depend on
§7 "reuse the standing mgmt cluster" + §3 "no throwaway EKS per test" means L2b
instantiate-and-verify, L3 negative tests, and L4 e2e all execute **against the
one mgmt cluster that ArgoCD/Crossplane/everything runs on**. L3 explicitly
wants to assert failure modes — "external-dns surfaces an auth error and writes
no records," "Keycloak crashloops without its DB," "ingress does not serve 200
without a cert." Running negative/precondition tests that deliberately break or
mis-configure components **on the shared live control plane** risks:
ArgoCD cluster-registration churn from L2b, Route53 record creation/deletion
storms from external-dns tests, Kyverno admission noise, and a half-torn-down
negative test leaving the real external-dns or ingress in a degraded state.

*How it bites:* a developer's spoke sync fails because an L2b ArgoCD
cluster-registration test was mid-teardown; external-dns thrash deletes a real
record; a negative Keycloak test leaves a crashlooping pod that trips an alert.

*Fix:* the plan must declare an **isolation boundary** for destructive/negative
tests — a dedicated test namespace with its own NetworkPolicy, separate ArgoCD
AppProject scoped to test resources, and a rule that L3 negative tests
manipulate **purpose-built throwaway workloads** (a fake "Keycloak-shaped"
deployment), never the real shared add-ons. Amend §4 and §7. The plan currently
treats "reuse the standing cluster" purely as a cost win and ignores the
production-safety cost.

---

## MAJOR

### M1 — The IRSA permission-completeness probe (the best idea) is under-specified and will rot
§4 calls it "the single highest-value addition" — agreed. But "exercises each MR
kind's full lifecycle (create/observe/update/delete/tag) under the real
crossplane IRSA role" is a research project, not a test spec. Concretely: who
enumerates "each MR kind"? It must be **derived from the installed provider CRDs
at runtime**, or new MR kinds (and their new IAM verbs) silently escape the probe
— the exact auto-012 class. And "exercise lifecycle" via real Crossplane means
~minutes per kind × many kinds × create+delete = significant wall-clock and the
very orphan risk in C3.

*Fix:* specify the probe as (1) enumerate MR kinds dynamically from
`kubectl get crds -l` provider labels; (2) for cheap kinds, drive one real
MR per kind under the IRSA role and assert no `AccessDenied` in events; (3) for
expensive kinds (EKS, RDS), **do not instantiate** — instead use AWS IAM policy
simulation (`iam simulate-principal-policy`) against the IRSA role for the
required action set, which is fast, free, and orphan-free. The plan conflates
these and would either be too slow or skip the expensive kinds entirely (where
the rds:* gap lived). Amend §4 and the §5 row for the IAM blocker.

### M2 — "Cannot instantiate with improper params → rejected" assumes admission rejects; XRD v2 + Crossplane often ACCEPTS and fails async
§4/§3-negative assumes bad claims are *rejected at admission* ("assert rejected
by schema/admission"). For required-field/pattern violations, true. But for
**semantic** preconditions (the plan's own examples: "Keycloak must not start
without its DB," incomplete-but-schema-valid params), Crossplane **accepts the
XR** and fails during reconciliation — there is no synchronous rejection to
assert. AGENTS.md §6.8 documents exactly this: the v2 admission webhook has
handler logic beyond the schema, and some things only fail at apply/reconcile.

*How it bites:* a negative test written as "expect kubectl apply to fail" passes
trivially when Crossplane accepts the claim, giving false green. The plan's L3
"contract is enforceable" claim overstates what admission can catch.

*Fix:* split L3 into **synchronous-reject** (schema/admission — assert apply
exit≠0) vs **async-fail** (assert the XR reaches a *terminal* `Synced=False` /
`Ready=False` with a specific reason within a bounded time, and that no cloud
resource was created). The async case needs a **timeout-vs-still-pending**
disambiguation or it's just a flaky wait. Amend §4 and §1 (L3 definition).

### M3 — No wall-clock / $ budget, no concurrency model, no rate-limit handling — despite the persona's core concern
§7 is titled "Cost / time controls" but contains zero numbers: no per-layer time
budget, no total-suite wall-clock target, no $ ceiling, no statement of how many
L2b tests run in parallel or what the AWS API rate-limit strategy is.
"Parallelize L2b" (§7) directly conflicts with C3's global-name collisions and
with AWS API throttling (IAM, Route53, Secrets Manager all throttle). EKS create
is ~20 min; the plan amortizes that into bring-up (good) but says nothing about
the **added** wall-clock of L2b+L3+L4 on top of an already ~20-min job, which
determines whether anyone tolerates it on by default.

*Fix:* add explicit budgets: target total added wall-clock (e.g. "<10 min over
bare bring-up"), a parallelism cap with a semaphore on global-name resources, and
an exponential-backoff/retry wrapper for throttle-prone AWS calls (`Throttling`,
`Rate exceeded`). State the $ estimate per run. Amend §7.

### M4 — "disabled/all-skipped must never read green" is asserted but the skip mechanism is the same exit-2=SKIP that already exists and DOES read green
Requirement (2) is explicit: all-skipped must not be green. But the existing
integration harness uses **exit 2 = SKIP** and `run.sh` returns 0 if only
pass+skip (confirmed in `run.sh`: it exits 1 only on FAIL). The plan reuses this
ecosystem (§6, §7) without changing it. If L2 preconditions aren't met (no
cluster creds, IRSA not assumable), tests SKIP and the suite is **green** — the
exact failure mode requirement (2) forbids.

*How it bites:* a rotated account with stale GH secrets (AGENTS.md §8.2) makes
every live test SKIP for lack of auth; suite reads green; "phase verified" is a
lie. This is auto-012 reincarnated as a skip instead of a missing field.

*Fix:* the plan must specify a **minimum-coverage floor**: the runner asserts an
expected count of L2/L3/L4 tests actually EXECUTED (not skipped) and fails if
executed < floor. A skip must be a distinct non-green outcome on protected runs.
The skip-guard (§2) only checks the disable *flag*; it does not catch
mass-skip-from-broken-preconditions. Amend §2 and §1.

### M5 — Reconcile latency / "Ready" is not "correct"; L2a after-the-fact can pass on a stale or partially-converged resource
§3 L2a asserts "EKS: ACTIVE, nodegroup ACTIVE, authenticationMode, access
entries, OIDC, subnet tags." But Crossplane `Synced/Ready` and EKS `ACTIVE` can
be true while the *desired update hasn't reconciled yet* (e.g.
authenticationMode change is pending, access entries are mid-apply). The plan's
verifier reads current cloud state once; on a freshly-changed composition it can
observe the **old** value and still pass, or observe a transient.

*Fix:* L2a assertions on mutable fields must verify **observed == desired AND the
XR's last-reconcile is newer than the change**, with a bounded wait for
convergence, not a single read. Amend §3.

### M6 — chainsaw "re-point at a real cluster" collides with the repo's heavy-CI discipline and the kind/real-cloud auth model
§6 proposes re-pointing chainsaw (or kuttl) at a real cluster under real IRSA.
But AGENTS.md §6.7/§6.8 puts chainsaw under a strict `workflow_dispatch`-only
heavy-CI contract specifically because real provisioning is slow/expensive, and
the chainsaw provider auth model is documented as fragile on rotated accounts
(§8.2 — 245s timeouts when runner secrets are stale). "Re-point chainsaw at real
cluster + real IRSA" inherits all of that and adds it to the on-every-bring-up
path. The plan treats tooling choice as a footnote.

*Fix:* state explicitly that the on-by-default live suite is **not** chainsaw —
keep chainsaw as L1 kind only (the plan half-says this) and build L2/L4 on the
existing integration harness (which already has cluster auth via
`aws eks update-kubeconfig`, RUN_ID, cleanup). Don't introduce kuttl as a third
harness. Amend §6.

---

## MINOR

### m1 — "never `|| true`" (§9) is correct and aligns with AGENTS §6.19; but the plan must also forbid the SKIP-as-green path (see M4) — currently it only forbids the silent-pass on cleanup.

### m2 — §8 rollout puts L4 (the flow with 6/8 blockers) LAST (P4). Given C1, the spoke flow is the highest-value coverage and is deferred the longest. Re-order: spoke L4 should ride in P1/P2, not P4.

### m3 — §5 coverage matrix lists each blocker → one or two layers but never states the **negative** assertion proving the test fails on buggy code (AGENTS §6.2 red-first discipline). Each matrix row should cite the red-first proof, or it's the same "test that passes against the bug" trap §6.2 warns about.

### m4 — Disable-switch governance (§9 open question) is left open. For an on-by-default control this must be *decided* in the plan: who may set it, that it auto-expires, and that it emits an audit log line. An open question here is a loophole.

### m5 — §3 medium/RDS "opt-in ephemeral L2b behind a flag" — a flag that's off by default contradicts requirement (4) "both after-the-fact AND instantiate-on-purpose" for everything cheap enough. RDS at ~5–10 min may simply be in the L2a-only "expensive" bucket; say so plainly rather than a flag nobody flips.

### m6 — The plan never addresses **test-induced load on the shared Crossplane provider/reconcile queue**: L2b creating many MRs competes with real reconciliation on the same provider pods, which can slow real provisioning for developers. Note it as a known cost.

---

## What PLAN-A got RIGHT — synthesis MUST preserve

1. **The core thesis: behavioral verification on a REAL cluster with Crossplane
   under the REAL restricted IRSA role, on by default, coupled to bring-up.**
   This is the actual fix for the auto-012 class. Do not let synthesis water
   this back down to "more lints."
2. **The honesty rename (lint ≠ test) and the L0–L4 taxonomy** — naming the
   layers honestly is what stops a green lint masquerading as verification.
3. **The IRSA permission-completeness probe as the highest-value single
   addition** (with M1's specification fixes) — it catches the entire IAM class
   at authoring time.
4. **Coupling discipline: authoring a create-step REQUIRES its L2/L3 test in the
   same change; "done" == green** (§2). This matches AGENTS §6.1/§6.2 and is the
   cultural mechanism that keeps coverage from rotting.
5. **The skip-guard concept** (on-by-default can't silently regress) — keep it,
   but extend it per C2/M4 (workflow_dispatch + mass-skip floor).
6. **Reuse the standing mgmt cluster / amortize the one ~20-min EKS into real
   bring-up, no throwaway EKS per test** (§3, §7) — correct cost stance; just
   add the C4 isolation boundary.
7. **"Never `|| true`," bounded waits + retries** (§9) — aligns with the repo's
   hard-won discipline (AGENTS §6.19); preserve and quantify (M3).
8. **Making `crossplane-claim-verify` the mandatory L2 verifier** (§6) — reuses
   an existing, correct asset rather than reinventing it.

**Single most important thing to preserve:** the real-cluster / real-IRSA,
on-by-default, coupled-to-bring-up core (#1). Everything else is mechanism around
it — but that core is the only thing that would have caught auto-012, and it is
the thing most likely to be eroded in synthesis under cost/flakiness pressure.
