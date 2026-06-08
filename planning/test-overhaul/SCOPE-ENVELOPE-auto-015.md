# Scope envelope — `auto-015` (test-overhaul continuation, new AWS account)

**Author.** Lead agent, autonomous-run session 2026-06-08.
**Status.** Awaiting user confirmation (implicit-confirm after a short wait — the
user is structurally absent for this delegated run; this envelope is the fallback
contract).

This document aligns intent before the unattended run begins: what it will
produce, what it will NOT touch, and how the first decision points are handled.
The morning user reviews against this envelope.

**Ground truth confirmed at run start:** new account `176646220910` (us-east-1),
**zero EKS clusters, zero EC2 instances** — a true cold-start. Every live/chainsaw
gate starts RED until a bring-up + producer dispatch. All auto-014 work is on
`main` (PRs #191–#200), so a CI `apply-and-verify` on `main` brings up the
substrate *with* the auto-014 verifier role + 13 behavioral checks already in it.

---

## What I plan to do

- **Bring up the full substrate** on the new account — terraform phases 0→1 (base
  VPC/Route53/Cognito + management EKS/ArgoCD/Crossplane) via CI `apply-and-verify`
  on `main` (clean build, §6.35), then the platform **spoke** cluster via ArgoCD
  GitOps; verify hub + spoke reach Ready.
- **Confirm the live gate end-to-end** — dispatch the live-verify producer; confirm
  GREEN on the 10-kind `LIVE_EXPECT_FULL`, and that a trivial `crossplane/**` PR's
  `live-evidence-verify` flips GREEN (no green-washing: a declared-but-unprovisioned
  kind correctly stays RED).
- **Flip the 4 currently-SKIP kinds** as the bring-up provisions them — manually sync
  `spoke-access` (→ spoke IRSA OIDC provider + external-dns inline RolePolicy become
  real), a real `XPlatformSecret` claim (→ secretsmanager Secret), and **fix
  `external-secret-live.sh` to cover the spoke reliably** (the auto-014 SKIP was a
  check gap, not a fact); add each kind to `LIVE_EXPECT_FULL` as it becomes real.
- **Resume Track B** driving the REAL Crossplane controller (GitOps Claim-apply / CI,
  not admin-AWS writes): wire **P3** (account-mutex + reaper) into `tests/live/run.sh`;
  build **P4** parametrized hermetic instantiate-and-verify on the two reviewer-approved
  hermetic kinds (`iam Role` + `secretsmanager Secret`); build **P5**
  (XRD/AppProject/RBAC/confused-deputy negatives that prove the guard fired, red-first;
  the app-level Keycloak-DB gate; the hub-side spoke GitOps watch).
- **OI-2026-06-08-1** — with a clean bring-up to validate against, narrow the provider
  IAM policy `Resource:"*"` to `role/k8-platform-*` + `oidc-provider/*` (leaving
  RDS/EKS/ACM at `*`), ship the paired deny test + the scope-regression guard, built
  from `scripts/derived-arn-inventory.sh`. Gated behind a fresh 2-round decision brief
  because it mutates the live provider role.
- **OI-2026-06-08-2** — once `hello.platform.<domain>` resolves, build a HARD
  bounded-poll public-NLB curl e2e (`wait_for` ≥300s, HTTP 200 + expected body), paired
  with a hub-side ArgoCD `spoke-hello` Synced/Healthy assertion. No self-gating SKIP stub.
- **Verify the Cognito/Keycloak/EKS OIDC federation** when implementing Iteration 5 —
  confirm it's Keycloak OIDC-brokering to Cognito + `aws_eks_identity_provider_config`
  for the API server; if any flow makes AWS IAM/STS trust Cognito directly without an
  `aws_iam_openid_connect_provider` for the Cognito issuer, treat that as a bug.

## What I plan to NOT do

- **NOT widen the ADR-0006 NON-GOALs:** no probe pod, no new AssumeRole principal, no
  IAM trust widening, no provider-SA token mount. The verifier/reaper role stays
  zero-wildcard.
- **NOT turn on `LIVE_MODE=mutating` by default** (fail-closed off); instantiate /
  negative tiers run only under `LIVE_PROFILE=full`.
- **NOT widen the spoke public-CIDR allowlist or add new EKS AccessEntries** — auto-014-004
  settled this as owner territory; the after-the-fact describe checks cover the spoke
  without new network/identity exposure.
- **NOT commit any "next-session prompt" file** (§6.38) — durable state goes to
  `ai/handoff.md` / `docs/open-issues.md`; any kickoff prompt is printed in chat.

## Scale estimate

- **Target PR count:** ~16–22 stacked PRs (envelope, the 4-SKIP flips + check fix, P3
  wiring, P4 harness, P5 negatives × a few, OI-1 brief+impl, OI-2 e2e, Iteration-5 OIDC
  finding, live-evidence/handoff updates, morning summary).
- **Subagent count estimate:** ~30–45 (Track-B authoring fan-out + ≥2 rounds × ≥3 real
  adversarial reviewers on the IAM-tightening brief and any other genuine forks).
- **Expected duration:** a long run — three serial EKS provisions (base, management,
  spoke) at ~20–30 min each, overlapped with authoring the cluster-independent Track-B
  code during the waits.

## First decision points

1. **Tighten the live provider IAM `Resource:"*"` now (OI-2026-06-08-1)?** The auto-014-002
   brief deferred *only* because there was no clean bring-up to validate against — there
   now will be one, and the task authorizes the narrowing.
   - **Lead-agent current best:** YES — narrow IAM to `role/k8-platform-*` +
     `oidc-provider/*` (the hawk-validated safe subset), leave RDS/EKS/ACM at `*`, ship
     the deny test + scope-regression guard, **validate against the clean bring-up before
     calling it done** — gated behind a fresh 2-round decision brief.
   - **Alternative:** keep deferring (lowest blast radius, but leaves the owner item open).
   - **If you disagree:** revert the terraform + deny-test PR (restores `Resource:"*"`).
2. **Bring-up mechanism — CI vs local terraform.**
   - **Lead-agent current best:** CI `apply-and-verify` on `main` (clean build, §6.35;
     the gating substrate must land on an unmodified build).
   - **Alternative:** run terraform locally from the sandbox (faster, but a manual change
     that violates §6.35 for the gating bring-up).
   - **If you disagree:** n/a — no code artifact; a process choice.
3. **If the Iteration-5 OIDC check finds a missing `aws_iam_openid_connect_provider` for
   a Cognito issuer that AWS IAM/STS trusts directly.**
   - **Lead-agent current best:** file it as a bug (OI) + a decision brief if the fix
     touches live trust (NON-GOAL-adjacent); do not silently widen trust autonomously.
   - **Alternative:** fix inline without a brief.
   - **If you disagree:** revert the fix/OI PR.

## What I'll surface in the morning summary

- The **IAM `Resource:"*"` tightening** — even after clean-build validation, it is a
  live-policy change with real blast radius; flagged for explicit confirmation with the
  rewind path.
- Any **Cognito/Keycloak/EKS OIDC federation bug** found during Iteration-5 verification
  (e.g. a missing `aws_iam_openid_connect_provider`).
- Whether to **widen spoke access** if the public-NLB curl e2e path proves insufficient
  for OI-2 (kept deferred per auto-014-004 — owner territory).

## Stop conditions

- **Allowed stops:** context-budget approaching (~70% → write summary + full
  retrospective first), hard-failed dependency (auth / GitHub / subagent harness / a
  blocked bring-up that can't be unblocked autonomously), scope-envelope completion,
  30-PR cap, user-message-arrived interrupt.
- **Will NOT stop on:** sub-phase closure, ambiguous subagent results, or a decision that
  feels like user-judgment territory — those are handled by decision briefs with two
  rounds of real adversarial review, not by freezing.

---

## User response (filled in by user, or left blank for implicit-confirm)

- **Confirm as-written:** _(blank — implicit-confirm)_
- **Adjustments:** _(none received at run start)_
- **Implicit-confirm after wait:** yes (proceeding; the user is structurally absent for
  this delegated run).
