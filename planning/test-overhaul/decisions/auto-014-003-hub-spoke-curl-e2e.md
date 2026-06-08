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
