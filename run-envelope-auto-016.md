# Scope envelope — auto-016 (unattended run)

**Run start:** 2026-06-08 · **Account:** fresh/empty (`whereami` shows no EKS, no
zone, no Crossplane) · **Branch trunk:** `claude/k8s-platform-auto-016-35v9sl` ·
**Discipline:** autonomous-run (stacked PRs, decision briefs with 2 adversarial
rounds, morning summary + retrospective at end).

This run continues the k8-platform test-overhaul on a brand-new AWS account.
Everything live starts RED until the substrate is brought up. All auto-015 work
(PRs #201–#208) is merged to `main`, including the IAM `Resource:*` narrowing, so
a fresh bring-up applies the already-narrowed Crossplane provider policy from the
start.

---

## 1. What I plan to do

- Bring up the substrate from committed `main`: terraform base + management via CI
  `apply-and-verify`, then the platform **spoke** cluster via ArgoCD GitOps; verify
  hub + spoke reach Ready under the **narrowed** IAM policy (re-validates auto-015 OI-1).
- Manually sync `spoke-access` (XSpokeAccess, manual-sync) with the spoke's
  oidcIssuer overlaid → spoke OIDC provider + external-dns Role + inline RolePolicy
  + the EKS AccessEntry; then sync the spoke **app stack**
  (ingress-nginx → external-dns → keycloak → hello).
- Confirm the live gate end-to-end (STEP 0): producer GREEN on the 10-kind
  `LIVE_EXPECT_FULL`; a trivial `crossplane/**` PR's `live-evidence-verify` flips GREEN.
- Flip the last 2 SKIP kinds (`secretsmanager Secret` + `ExternalSecret`) once
  Keycloak's `XPlatformSecret` provisions; add each to `LIVE_EXPECT_FULL`.
- Live-validate Track B in MUTATING mode (P4 instantiate-and-verify, P5 negatives,
  P3 reaper dry-run + account-mutex).
- OI-2026-06-08-2: build a HARD bounded-poll public-NLB curl e2e (hub→spoke) once
  `hello.platform.<domain>` resolves — no self-gating SKIP stub.
- OI-2026-06-08-1 follow-up: narrow RDS + EC2 IAM, each gated on the provision that
  exercises it, proven on the live CREATE path (not simulate-principal-policy);
  hold as sentinel-gated draft until validated.

## 2. What I plan to NOT do

- No new AssumeRole principal, no IAM trust widening, no probe pod, no provider-SA
  token mount (ADR-0006 NON-GOALs). Verifier/reaper role stays zero-wildcard.
- No teardown of any lower phase; no destroy of the substrate I bring up.
- `LIVE_MODE=mutating` fail-closed stays **off** by default; instantiate/negative
  tiers run only under `LIVE_PROFILE=full`.
- No EKS action-scope narrowing of `eks:*` (separate concern; ARNs opaque).

## 3. Scale estimate

Target 8–15 stacked PRs (substrate-validation evidence, the 2 SKIP-flip additions,
the OI-2 e2e check, the RDS+EC2 narrowing pair, Track-B live evidence, run summary).
~10–25 subagents across decision-brief reviews + cluster-independent authoring during
EKS waits. Duration: multi-hour (two EKS bring-ups dominate the wall clock).

## 4. First decision points

1. **RDS/EC2 narrowing shape** — best call: RDS `db:<xr-name>` + a `ManagedBy`
   tag-condition (Describe* stays `*`); EC2 `ec2:Vpc` condition. Alternative: leave
   RDS/EC2 at `*`. Rewind: revert the narrowing PR. (Decision brief + 2 rounds.)
2. **OI-2 e2e gating surface** — best call: a HARD bounded-poll (≥300s) public-NLB
   curl returning 200 + expected body, paired with a hub-side ArgoCD Synced/Healthy
   assert. Alternative: SKIP stub (rejected by the brief). Rewind: revert the check PR.

## 5. Morning-summary items

- Live bring-up evidence (hub/spoke Ready; narrowed-policy reconcile green).
- The 2 SKIP→FULL flips and the producer 10→12 kind expansion.
- RDS/EC2 narrowing PRs (sentinel-gated drafts until CREATE-path proven).
- Track-B mutating evidence (P4/P5/P3-dry-run).
- Any kind that correctly stays RED (declared-but-unprovisioned — not green-washed).

## 6. Stop conditions

Stop only on: context-budget approaching exhaustion (write summary+retro first);
hard-failed dependency (auth/GitHub/AWS creds); 30-PR cap; explicit user interrupt.
A sub-phase closing is **not** a stop — start the next. Substrate bring-up failures
get diagnosed + logged to `docs/open-issues.md`, not silently skipped.
