# auto-014-003 — Whether to attempt the conditional hub→spoke curl e2e

> Decision brief (autonomous-run protocol: two adversarial rounds, ≥3 real
> reviewers each). FINAL-PLAN §10 / §14.2 open owner choice.
> **Status: Round 1 — awaiting first adversarial wave.**

## Question

FINAL-PLAN §10 proposes, *conditionally*, a hub→spoke end-to-end check: after the
hub provisions the spoke, a CI/runner step reaches the spoke's public app ingress
(or kube-API) and `curl`s a real workload (e.g. the `hello` app) to prove the
whole GitOps path works end-to-end. §14.2 makes it conditional on (a) the runner
egress IP being in the spoke's public-access CIDR allowlist and (b) an EKS
AccessEntry/AssumeRole path for the CI identity. Should auto-014 build the curl
e2e now, or defer it?

## Live evidence gathered this run

- `kubectl` through the SSM relay reaches the **hub** (`k8-platform-mgmt`)
  read-only — verified (3 Ready nodes).
- The same relay path to the **spoke** (`k8-platform-services`) **FAILED** this
  run ("SSM tunnel did not open" / relay check returned non-pass). So spoke
  reachability from the sandbox is **not currently working** via the relay, and
  the runner's reachability to the spoke is unverified.

## Alternatives

1. **Defer the curl e2e; rely on hub-side config + after-the-fact (my call).**
   Verify the spoke via the after-the-fact AWS-describe checks (already authored:
   eks Cluster/NodeGroup/AccessEntry/etc. on `k8-platform-services`) and hub-side
   GitOps state, not a live curl. Add the curl e2e only once §14.2's two
   preconditions are confirmed.
2. **Build the curl e2e now, gated on a reachability precheck.** Author the step
   so it SKIPs cleanly when the runner cannot reach the spoke, PASSes when it can
   — a self-gating behavioral check that becomes live the moment the allowlist +
   AccessEntry admit the runner.
3. **Build it as a hard gate now.** Highest signal, but RED until the
   reachability preconditions are met — risks blocking on infra not yet in place.

## Round-1 decision (my best call)

**Defer (Alternative 1), but pre-stage Alternative 2's self-gating shape.** Spoke
reachability is demonstrably not working from here this run, and §14.2's
preconditions (CIDR allowlist + AccessEntry for the CI/runner identity) are
unconfirmed. A hard-gate curl e2e would be RED-by-infra; a no-op stub would be a
test that can't fire. The honest middle: defer the live curl, keep spoke coverage
on the AWS-describe after-checks, and record the curl e2e as a P5 item that ships
self-gating (SKIP-until-reachable) once the allowlist/AccessEntry are confirmed
(see brief auto-014-004).

## Reasoning

A curl e2e is only meaningful if the runner can actually reach the spoke; that is
unverified and currently failing. Deferring avoids a RED-by-infra gate while
keeping real spoke behavioral coverage via the describe checks. Coupled to
brief 004 (the allowlist is the precondition).

## Downstream impact

P5 ships spoke coverage via after-the-fact describe checks now; the curl e2e is a
documented follow-up contingent on brief 004's allowlist/AccessEntry confirmation.

## Round-1 if-user-overrides rewind point

No code/infra change under the Round-1 call. If the owner wants the curl e2e, it
lands as a self-gating P5 check; revert that check to undo.

---

## Round 2 (revised) — incorporating Round-1 adversarial findings

> Round 1 superseded. Reviewers (coverage-maximalist, infra-realist,
> determinism-skeptic) moved the decision: the infra-realist's correction is
> decisive — my Round-1 "defer + pre-stage a self-gating stub" was wrong.

**Revised decision: PURE-defer — do NOT pre-stage a self-gating SKIP stub.**

- **Why no stub (infra-realist):** a SKIP-until-reachable check in `checks/after/`
  re-introduces the exact "silent skip reads green" disease ADR-0006 kills. The
  all-skipped⇒RED floor is *suite-level*, not per-check, and a non-`COVERS` SKIP
  never triggers expect-full promotion — so the stub would sit SKIPping for months
  while the suite reads green. Deferring with an OI keeps the gap VISIBLE instead.
- **Pursue first (coverage-maximalist):** the spoke ingress-nginx is an
  internet-facing NLB; `hello.platform.<domain>` may be curl-reachable over public
  HTTPS with NO kube-API, NO relay, NO CIDR allowlist — which would make §14.2 and
  brief 004 moot for the e2e. Investigate this public-NLB path before assuming the
  curl needs spoke kube reachability.
- **When built (determinism-skeptic):** a curl against a fresh spoke races NLB
  warm-up + DNS TTL + ACM issuance + ingress reconcile + pod-ready. It MUST be a
  bounded poll (`wait_for`, ≥300s, 10–15s interval) on HTTP 200 *with the expected
  body*, reachability SKIP-gate kept SEPARATE from the service-ready poll, and ship
  as a HARD check (non-zero on reachable-but-failing), never a silent skip.

Committed this run: **`OI-2026-06-08-2`** records the gap + this plan. **Rewind:**
revert the OI entry (no code/infra effect).
