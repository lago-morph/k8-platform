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

---

## Round 2 (revised) — incorporating the first adversarial wave

> Round 1 superseded (text preserved above). Three real reviewers
> (blast-radius-regulator [opus], deny-test-and-guard-auditor, least-privilege-purist)
> all returned CHANGE. They converged: the IAM **design is sound** (the
> `k8-platform-*` prefix + PassRole analysis is airtight, verified against the
> Compositions), but three things were wrong — the **validation was asserted, not
> gated**; the **deny test + guard were lints, not firing tests**; and the **RDS
> "non-derivable" justification was stale**. The decision holds (narrow IAM) but is
> now correctly gated, given an honest test mechanism, and scoped against a corrected
> rationale.

**Revised decision: narrow IAM role→`role/k8-platform-*` and OIDC→`oidc-provider/*`
exactly as in Round 1 — but (a) gate the merge on real spoke validation, (b) ship the
deny test as a live `simulate-principal-policy` check, (c) ship the regression guard
as a both-directions structural assertion, and (d) correct the RDS rationale and file
RDS/EC2 tightening as a sharpened follow-up rather than doing it here.**

### (a) The validation gap is the load-bearing fix (blast-radius-regulator)

The narrowed IAM path is exercised **only by the spoke's Crossplane-created roles +
OIDC provider** — the hub roles are **Terraform**-created (operator creds), so a
hub-only bring-up exercises **zero** narrowed `iam:CreateRole`/`CreateOpenIDConnect
Provider` calls. So:

- The work is **"pending clean-build verification"** (§6.35) until the **spoke
  reconciles green under the narrowed policy** — concretely: the live
  `iam-oidc-provider-live.sh` check flips from its hard-coded SKIP to a real
  `crossplane-kind`-stamped OIDC-provider **PASS**, AND a spoke
  `k8-platform-services-external-dns` Role is observed created (its inline RolePolicy
  reconciled). Both happen when `spoke-access` is manually synced (the flip-4-SKIP
  step).
- **If the run hits a stop-condition before the spoke is up, the policy hunk MUST
  NOT merge to `main`.** It ships as a **held stacked PR** for the next session to
  validate-then-merge; `OI-2026-06-08-1` stays **DEFERRED**, not RESOLVED, and
  `docs/open-issues.md` is only flipped to RESOLVED after the spoke PASS is observed.

### (b) The deny test must FIRE, not grep (deny-test-and-guard-auditor)

A static assertion that the string `role/k8-platform-*` exists in `irsa.tf` is a lint
— and worse, `irsa.tf` renders the Resource via `jsonencode(...)` with
`${local.account_id}`, so source-grep never sees the rendered ARN. The honest,
firing deny test runs against the **rendered live policy**:

```
aws iam simulate-principal-policy \
  --policy-source-arn  <k8-platform-mgmt-crossplane role ARN> \
  --action-names       iam:CreateRole \
  --resource-arns      arn:aws:iam::<acct>:role/not-k8-platform-ours
# assert EvalDecision == "explicitDeny" (NOT a bare/implicit deny) AND a
# MatchedStatements entry names the narrowed IAM Sid — so the denial is the
# Resource scope, not an unrelated missing action (the wrong-reason-pass trap).
```

This lands as a **live negative check** (P5 negative tier / a dedicated
`checks/negative/iam-resource-scope-denied.sh`) under the scoped role — it needs only
`iam:SimulatePrincipalPolicy` (a read), no mutation. A positive control (a
`role/k8-platform-allowed` CreateRole returns `allowed`) guards against the policy
being denied for the wrong reason.

### (c) The regression guard, honestly framed (deny-test-and-guard-auditor)

Two distinct artifacts, not one vague "guard":
- The **firing behavioral proof** is the live simulator deny test in (b) + the
  bring-up validation in (a).
- The **source regression guard** is a structural unit assertion on `irsa.tf` that
  catches a **future human edit in either direction**: it asserts the role statement's
  Resource references `role/k8-platform-*`, the OIDC statement's references
  `oidc-provider/*`, AND the EKS/EC2/ACM statements' Resource stays `"*"` (so a
  *premature over-narrowing* of those is also caught). This is explicitly a
  source-of-truth guard (it watches the file a human edits), not a behavioral test —
  the behavior is proven by (a)+(b). If a richer check is wanted later, parse
  `terraform show -json` of a plan to assert the rendered (locals-resolved) document;
  noted as an enhancement, not required for this guard's job.

### (d) Correct the RDS rationale; file RDS/EC2 as a follow-up (least-privilege-purist)

The Round-1 "RDS auto-named `terraform-<rand>`, non-derivable" line is **stale and
must not fossilize**: `crossplane/compositions/xdatabase.yaml` patches
`crossplane.io/external-name` from the XR `metadata.name`, so the DB identifier — and
thus `arn:aws:rds:<region>:<acct>:db:<xr-name>` — is **operator-controlled and
derivable**, and every RDS resource is tagged `ManagedBy: crossplane`. So RDS *could*
be scoped (prefix `db:*`/`subgrp:*` + a `ManagedBy` tag-condition on the mutating
verbs; `Describe*` genuinely stays `*`). EC2 networking could likewise carry an
`ec2:Vpc` condition. **But each added narrowing expands the §6.35 validation surface
(a) guards** — narrowing RDS without a Keycloak-DB provision to validate it would
re-introduce the very gap this round just closed for IAM. So: **narrow IAM now
(validated by the spoke OIDC/role), and file the RDS prefix+tag and EC2 `ec2:Vpc`
tightenings as a sharpened `OI-2026-06-08-1` follow-up** with the corrected
derivability facts, each gated on the provision that exercises it. `eks:*` action-set
enumeration is a separate concern (action scope, not Resource scope) → its own OI.

### Round-2 rewind point + status

The policy hunk + the live deny check + the structural guard land on this branch;
revert the branch to restore `Resource:"*"`. **Status after Round 2: decision = narrow
IAM, GATED on spoke validation; awaiting the second adversarial wave on this revised
brief, then implementation + live validation.**
