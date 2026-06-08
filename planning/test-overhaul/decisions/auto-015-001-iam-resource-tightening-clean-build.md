# auto-015-001 — Narrow the Crossplane provider IAM `Resource:"*"` now that a clean bring-up exists

> Decision brief (autonomous-run protocol: two adversarial rounds, ≥3 real
> reviewers each). Supersedes the *deferral* in auto-014-002 — the blocking
> condition has cleared. OI-2026-06-08-1; FINAL-PLAN §3.3/§14.3.
> **Status: Round 1 — awaiting first adversarial wave.**

## Question

auto-014-002 declined to tighten the live Crossplane provider role's IAM
`Resource:"*"` **for one reason only**: no clean bring-up was available from the
sandbox to validate that a narrowed policy still provisions (§6.35), so the change
was unverifiable and could silently break the next reconcile. **That condition has
now cleared** — this run is performing a full cold-start bring-up on the new
account `176646220910` (base ✅, management in progress, platform spoke to follow),
which is exactly the teardown-rebuild validation window auto-014-002 named as the
gate. The task brief also explicitly authorizes the narrowing. So: should auto-015
narrow the IAM statement now (with the bring-up as the validator), ship the paired
deny test, and add the scope-regression guard — or keep deferring?

## What is actually on the table (grounded in `terraform/management/irsa.tf`)

The `aws_iam_policy.crossplane_aws` "IAM" statement (irsa.tf:65-93) grants every
IAM action against `Resource = "*"`. The auto-014-002 hawk + `scripts/derived-arn-
inventory.sh` established that the role/OIDC ARNs the Compositions create are fully
derivable:

| Action group | Roles/providers Crossplane creates | Safe narrowed Resource |
|---|---|---|
| `iam:CreateRole/DeleteRole/Attach/Detach/Put/Delete/Update/Get/List*RolePolic*/Tag/Untag/PassRole` | `k8-platform-cluster-<name>`, `k8-platform-nodegroup-<name>`, `k8-platform-<cluster>-external-dns` | `arn:aws:iam::<acct>:role/k8-platform-*` |
| `iam:Create/Delete/Get/Tag/UntagOpenIDConnectProvider` | one IRSA OIDC provider per spoke | `arn:aws:iam::<acct>:oidc-provider/*` |

Everything else stays `"*"` by deliberate, documented design: `eks:*`, EC2
networking, `rds:*` (auto-named `terraform-<rand>`), ACM (opaque post-issuance
ARNs) — none are resource-scopeable by API shape, and the `Describe*` verbs aren't
resource-scopeable at all. The Secrets Manager statement is **already** scoped to
`secret:k8-platform/*` (irsa.tf:123) — precedent that prefix-scoping is the house
style here.

## Alternatives

1. **Narrow IAM (role + OIDC) now, validate on the bring-up, ship the deny test +
   scope-regression guard (my Round-1 call).** Split the "IAM" statement into a
   role-scoped statement (`role/k8-platform-*`) and an OIDC-scoped statement
   (`oidc-provider/*`); leave EKS/EC2/RDS/ACM at `*`. Validate by (a) the management
   `apply-and-verify` re-applying the policy and (b) confirming the platform spoke
   still provisions (its Crossplane-created roles/OIDC all match the prefix). Add a
   deny-test fixture (a non-`k8-platform-*` role create is denied) and a
   scope-regression unit guard asserting the narrowed Resources stay narrow.
2. **Keep deferring (auto-014-002's posture).** Lowest blast radius, but the
   blocking condition it cited is gone, the owner authorized the change, and "defer
   forever" is the silent-debt this overhaul exists to kill.
3. **Narrow aggressively (also scope RDS/EKS/ACM to derived lists).** Rejected
   up-front: those ARNs are genuinely non-derivable (random suffixes / opaque), so a
   narrowed list WOULD silently break the next bring-up — the exact §6.35 hazard.

## Round-1 decision (my best call)

**Alternative 1.** The one fact that made deferral correct in auto-014-002 (no
clean build to validate against) is no longer true. The narrowing is to a derived,
prefix-stable ARN set (every role the Compositions create is `k8-platform-*`; the
SM statement already proves prefix-scoping works here), it is validated by this
run's actual cold-start bring-up (not by simulation alone), and it ships with both
a deny test that fires against a static policy condition and a regression guard so
a *future* silent re-widening or premature over-narrowing is caught. EKS/EC2/RDS/
ACM stay `"*"` — narrowing them is the unsafe part and is explicitly out of scope.

## Reasoning

- **Validatable now:** the bring-up provisions a real spoke whose Crossplane-created
  IAM roles + OIDC provider must all reconcile under the narrowed policy — a live
  proof, not a guess. `iam:SimulatePrincipalPolicy` is a cheap *pre-check* (added to
  the impl) but does NOT replace the bring-up (it can't catch an unanticipated ARN).
- **Tightly bounded blast radius:** only IAM role/OIDC resources are scoped; the
  non-derivable services are untouched. The prefix `k8-platform-*` is enforced by the
  cluster-name var the Compositions template from.
- **The deny test can fire:** `iam:CreateRole` for `arn:aws:iam::<acct>:role/not-ours`
  is denied by the static `role/k8-platform-*` Resource — a negative that genuinely
  fires (FINAL-PLAN §7), unlike the deferred-state "test that can't fire."
- **Regression-guarded:** `test_iam_required_actions.sh` checks ACTIONS only and
  would NOT notice a Resource change; a new guard asserts the role/OIDC statements
  stay prefix-scoped (catches both a silent re-widening to `*` AND a premature
  over-narrowing of the other services).

## Downstream impact

OI-2026-06-08-1 moves from DEFERRED to RESOLVED. P5's negative tier gains a real
IAM deny test. The live provider policy changes (one terraform PR), validated on the
bring-up before the PR is called done; if validation fails (an unexpected
non-prefixed role create is denied), revert the policy hunk and the kind goes back
to `"*"` with the failure recorded.

## Round-1 if-user-overrides rewind point

The change lands as a single terraform hunk in `irsa.tf` (the "IAM" statement split)
+ a deny-test fixture + a guard unit test. Revert that commit to restore the single
`Resource:"*"` IAM statement. Until validated on the bring-up, the work is marked
**"pending clean-build verification"** (§6.35), never "done".
