# auto-014-004 — Spoke public-API CIDR / AccessEntry allowlist for CI + sandbox

> Decision brief (autonomous-run protocol: two adversarial rounds, ≥3 real
> reviewers each). FINAL-PLAN §10 / §14.2 open owner choice.
> **Status: Round 1 — awaiting first adversarial wave.**

## Question

For any runner/sandbox to reach the spoke (`k8-platform-services`) kube-API or app
ingress, two preconditions must hold (§14.2): (a) the caller's egress IP is in the
spoke's **public-access CIDR allowlist**, and (b) an **EKS AccessEntry /
AssumeRole** path authorizes the caller. Should auto-014 expand the spoke CIDR
allowlist + add an AccessEntry for the CI/sandbox identity now, or leave the spoke
reachable only via the hub-side path and after-the-fact AWS describes?

## Live evidence gathered this run

- Hub (`k8-platform-mgmt`) is reachable via the SSM relay; the relay admits the
  sandbox to the hub kube-API (read-only) and the hub `sandbox-access-entry`
  authorizes `user/cloud_user` (`AmazonEKSAdminViewPolicy`).
- The spoke relay path **FAILED** this run — the spoke either lacks the relay SG
  ingress / AccessEntry for the sandbox identity, or the spoke relay isn't
  established. So the spoke is **not currently reachable** from the sandbox the
  way the hub is.

## Alternatives

1. **Do NOT expand the allowlist/AccessEntry now (my Round-1 call).** Keep spoke
   verification on the after-the-fact AWS-describe checks (which need only the
   scoped AWS role, not kube reachability) and the hub-side GitOps state. Treat
   the spoke relay gap as an infra item for the owner, not something to widen
   network/identity exposure for autonomously.
2. **Add a spoke `sandbox-access-entry` + relay SG ingress (mirror the hub).**
   The platform-cluster Composition already renders these per cluster; if the
   spoke simply hasn't synced them, the fix is GitOps, not new exposure. Low risk
   IF it is genuinely a sync gap and not a deliberate spoke-isolation choice.
3. **Widen the spoke public CIDR allowlist to admit CI runner ranges.** Largest
   surface-area change; an explicit network-exposure decision the owner should
   make, not an autonomous run.

## Round-1 decision (my best call)

**Do NOT expand exposure autonomously (Alternative 1).** Widening a CIDR
allowlist or adding an AssumeRole/AccessEntry path is a network/identity exposure
decision squarely in owner territory, and it brushes against the ADR-0006
NON-GOAL spirit (no trust widening) even though an EKS AccessEntry is not an IAM
trust change. The spoke relay failure may be a deliberate isolation property of
the spoke, not a bug — I must not "fix" it by widening access. Keep spoke
coverage on the AWS-describe after-checks; surface the spoke-relay gap as a
morning item with the diagnostic (relay SG ingress / spoke AccessEntry for the
sandbox identity appears absent or unsynced).

## Reasoning

The after-the-fact describe checks already give real spoke behavioral coverage
(eks Cluster/NodeGroup/AccessEntry/AccessPolicyAssociation on the spoke all PASS)
without any new network/identity exposure. Expanding the allowlist is the kind of
irreversible-ish, blast-radius-bearing change the autonomous-run protocol says to
brief and default-conservative on. Gates brief 003 (no curl e2e without this).

## Downstream impact

Spoke is verified via AWS-describe after-checks only; the hub→spoke curl e2e
(brief 003) stays deferred. If the owner approves Alternative 2 (GitOps-only sync
of the spoke access-entry/SG ingress) that is low-risk and would unblock both the
spoke relay and the curl e2e.

## Round-1 if-user-overrides rewind point

No code/infra change under the Round-1 call. If the owner approves expanding
access, it lands as a terraform/Composition PR; revert that PR to restore the
current spoke isolation.

---

## Round 2 (revised) — incorporating Round-1 adversarial findings + a read-only diagnosis

> Round 1 superseded. Reviewers (exposure-hawk ACCEPT, GitOps-purist ACCEPT,
> reachability-advocate CHANGE-to-diagnose). The decline holds; per §6.18 I ran
> the safe read-only diagnosis the advocate asked for.

**Read-only diagnosis run this session (no exposure change):**
`aws eks list-access-entries --cluster-name k8-platform-services` →
`AWSServiceRoleForAmazonEKS`, `k8-platform-nodegroup-k8-platform-services`, and
**`user/cloud_user`**. The hub has the same shape. **So the spoke is NOT
deliberately isolated at the access-entry level — `cloud_user` already has a spoke
AccessEntry.** The earlier spoke-relay failure was therefore most likely
transient SSM-tunnel contention (two relay calls collided in one wave that run),
NOT a missing access path or a deliberate hold.

**Revised decision: still do NOT widen the CIDR allowlist or add a new
AccessEntry autonomously**, for three reinforcing reasons the reviewers sharpened:
1. The sandbox identity is read-only (`AmazonEKSAdminViewPolicy`) and **cannot**
   `kubectl apply` / `argocd sync` anyway; doing so would also violate §6.35
   (no manual changes; verify on a clean build).
2. The `XSpokeAccess` claim is `MANUAL-SYNC ONLY` by design — some spoke state is
   deliberately gated; an autonomous run must not override that gate.
3. An EKS AccessEntry is NOT an IAM trust change (so not literally an ADR-0006
   NON-GOAL) — but widening *network/identity reach* is owner territory regardless.

**Net:** no allowlist/AccessEntry change is needed for the after-the-fact spoke
coverage (which works under the scoped AWS role, no kube reachability). The spoke
IS reachable in principle (cloud_user access entry present); the relay flake is
transient. The hub→spoke curl e2e (brief 003) should pursue the public-NLB path,
which needs neither the CIDR allowlist nor an AccessEntry. **Rewind:** none — no
code/infra change.
