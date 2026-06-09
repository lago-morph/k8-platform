# Run summary — auto-016 (unattended)

## The short version

**What this run set out to do.** Stand the whole platform back up from scratch on a
brand-new, empty AWS account, and use the new "did it actually work?" test machinery
to prove the substrate reconciles cleanly under the security-narrowed Crossplane
permissions we shipped last session — then close out the remaining open items (a
real hub→spoke end-to-end test, two more permission narrowings, flipping the last
skipped checks on).

**Where the night would have gone if everything broke our way.** Hub + spoke
clusters up green, the spoke app stack serving `hello.platform.<domain>` over its
public load balancer, the live evidence gate flipping green honestly, and the two
extra permission narrowings (database + networking) merged after a real resource was
watched being created under them.

**What changed the plan.** Bringing up a spoke on a *fresh* account — with the
already-narrowed permissions applied *from the start* — surfaced a chain of latent
gaps that prior runs had only ever papered over live and never fixed durably. The
biggest was a genuine **fail-closed regression in last session's permission
narrowing**: it broke EKS worker-node creation, so the spoke came up with **zero
nodes**. That's exactly the class of bug this whole test overhaul exists to catch,
and catching it is arguably the most valuable outcome of the night. Past that, three
more recurring "never durably fixed" gaps (a firewall rule, subnet tags, and the
placeholder-overlay-vs-GitOps conflict) each had to be unblocked by hand, and the
last one is a real architectural wall that blocks the hello end-to-end test until
it's fixed properly.

**What's next, in order.** (1) Merge the regression fix. (2) Ship durable fixes for
the three recurring gaps so a fresh account stops re-paying this cost. (3) With the
overlay gap fixed, finish the hello e2e validation and flip on the last checks.

---

## What's live / what got built

The substrate came **all the way up** under the narrowed permissions, and the
identity-layer narrowing from last session was **re-proven on a fresh account's
create path** — that was the run's primary success criterion.

| Piece | State | How we know |
|---|---|---|
| Base (VPC / Route53 / Cognito) | ✅ up | terraform apply-and-verify green |
| Hub EKS `k8-platform-mgmt` | ✅ up, 3 nodes, full stack | apply-and-verify green; 9 Crossplane providers Healthy |
| Spoke EKS `k8-platform-services` | ✅ ACTIVE, 2 nodes | live (after the node-role fix) |
| **Identity narrowing (OI-1) on create path** | ✅ **re-validated** | OIDC provider, 3 Roles, RolePolicy, 2 AccessEntries, 2 AccessPolicyAssociations all `Ready=True` under the narrowed policy |
| Spoke registered with hub ArgoCD | ✅ (live bootstrap) | cluster Secret created; ArgoCD connects |
| Database-permission narrowing | ✅ applied live | clean plan diff; ongoing reconcile green under it |
| Spoke app stack (ingress-nginx/external-dns/hello) | ⚠️ partially up | pods Running; **blocked** on the overlay gap below |

### The headline finding — a real fail-closed regression

Last session narrowed `iam:GetRole` to our own role prefix. But when Crossplane
creates the spoke's worker-node group, EKS validates a **service-linked role** via
`iam:GetRole` on an AWS-owned path that the narrowing excluded. Result on a
fresh-from-the-start bring-up: node group creation **failed closed**, spoke had no
nodes, whole app stack stuck. Last session never hit this because it only validated
the narrowing on a *different* create path (cluster access), and its node group was
created *before* the narrowing applied. **Fixed** by granting `iam:GetRole` +
`CreateServiceLinkedRole` scoped to the EKS service-linked-role path only; proven
live (node group went ACTIVE immediately after).

### Three recurring gaps that bit again (live-fixed, durable fixes still owed)

Each was unblocked by hand this run (we hold full admin on the account), but none has
a durable code fix yet — so the *next* fresh account re-pays the cost:

- **Hub→spoke firewall rule** — the spoke's API firewall didn't admit the hub's
  nodes on 443, so ArgoCD couldn't reach the spoke. Added the rule live.
- **Load-balancer subnet tags** — the shared subnets weren't tagged for the spoke,
  so its load balancer couldn't be placed. Tagged them live.
- **Placeholder overlays vs GitOps self-heal** — the spoke apps carry placeholder
  values (domain, cert ARN) meant to be "overlaid at registration," but the
  app-of-apps self-heals them back to the placeholders. This is the wall that blocks
  the hello e2e: the load balancer never gets a valid cert because the overlay won't
  stick. Needs the real fix (cluster-facts ConfigMap), not another hand-overlay.

---

## Suggested merge order

1. **#213 — node-role regression fix** (independent; the most important to land — it
   makes a fresh-account spoke bring-up work under the narrowed policy). Safe to merge first.
2. **#211 — database (RDS) permission narrowing** (draft; flip to ready once you're
   comfortable with the ongoing-reconcile proof, or after a pristine create-path recheck).
3. **#212 — networking (EC2) permission narrowing** (draft; stacked on #211). See the
   "decision to confirm" below — one reviewer recommended deferring this entirely.
4. **#210 — hub→spoke hello e2e check** (the check is authored and correct; mark ready
   once the overlay gap is fixed and it's been run green against a live spoke).
5. **#209 — trunk/scope envelope** and this summary (housekeeping).

---

## PRs opened

| PR | What it does (plain words) | Merge risk |
|----|----|----|
| #209 | Trunk + scope envelope for the run | none |
| #210 | Hard hub→spoke hello e2e check (no self-gating skip stub) | low — additive test; pending live validation |
| #211 | Narrow the database (RDS) permissions; **draft** | low — sentinel-gated; lint 18/0 |
| #212 | Narrow the networking (EC2) permissions; **draft** | medium — see decision below; lint 23/0 |
| #213 | **Fix the node-role regression** (the zero-nodes bug) | low — proven live; lint 13/0 |

---

## Decisions you may want to confirm

- **Ship vs defer the EC2 narrowing (#212).** I shipped it as a draft. One of six
  reviewers argued to **defer it entirely**: the permission principal is already
  tightly trust-bounded, the networking narrowing only constrains 4 of the actions
  (the rest stay broad regardless), and the per-action condition-key subtleties carry
  a real fail-closed risk. My call: keep it a draft and let a future fresh-account
  spoke create-path be the judge. **To take the defer: close #212** (the RDS PR #211
  stands alone). Rewind: closing #212 leaves networking permissions unchanged.
- **RDS narrowing proof is "ongoing-reconcile", not pristine-create.** The database
  instance was created (during the initial bootstrap) *before* I applied the narrowed
  policy, so I couldn't watch a create under it — only that it keeps reconciling green
  under it. A pristine proof needs a destructive delete+recreate (deferred). Rewind:
  revert #211.

---

## What I deliberately did NOT do

- **Did not force the hello e2e green by pausing the app-of-apps.** I could have
  paused self-heal and hand-overlaid the domain + cert to get a 200, but that's a
  hand-modified build, so it wouldn't be a clean-build validation of #210 — and the
  underlying overlay gap would still be unfixed. Documented the blocker instead.
- **Did not flip the two remaining skipped checks** (secret + external-secret). They
  need Keycloak running, which needs the same overlay path that's blocked.
- **Did not run the live mutating Track B tiers** (P4/P5) or the live evidence-gate
  round-trip — both want the app stack fully converged first.
- **Did not author the durable fixes** for the three recurring gaps (firewall rule,
  subnet tags, overlay ConfigMap) — they're code changes touching the cluster
  Composition + base terraform and want their own reviewed PRs; logged as the next
  concrete steps.

---

## How to undo any of it

| To undo | Do this | What survives |
|---|---|---|
| The whole run | revert the trunk PR #209 and close the rest | nothing |
| The node-role fix | revert #213 | live policy reverts to broad on next mgmt apply (also unblocks) |
| The RDS narrowing | revert #211 | live policy reverts to broad on next mgmt apply |
| The EC2 narrowing | close #212 | RDS narrowing intact |
| The hello e2e check | revert #210 | everything else |
| The live hand-fixes (SG rule, subnet tags, SLR inline policy, spoke registration) | they vanish with the ephemeral account; no durable artifact to revert | — |

---

## Pointers / audit trail

- **Account:** `471112679140` (us-east-1), ephemeral.
- **Branch chain:** trunk `claude/k8s-platform-auto-016-35v9sl` (#209) →
  `claude/auto-016-oi2-hello-e2e` (#210), `claude/auto-016-rds-iam-narrowing` (#211) →
  `claude/auto-016-ec2-iam-narrowing` (#212), `claude/auto-016-eks-slr-getrole-fix`
  (#213), `claude/auto-016-run-summary` (this).
- **CI runs:** base apply-and-verify `27174339355` (green); mgmt apply-and-verify
  `27174531578` (green); mgmt apply on RDS branch `27176069142` (green, narrowed-policy diff).
- **Decision brief:** `planning/test-overhaul/decisions/auto-016-001-rds-ec2-iam-narrowing.md`
  (2 adversarial rounds, 6 real reviewers).
- **Open issues touched:** OI-2026-06-08-1 (RDS/EC2 narrowing + the new SLR
  regression), OI-2026-06-08-2 (hello e2e), OI-2026-06-07-2/-3/-4 (recurring gaps).
- **Live evidence of OI-1 re-validation:** XSpokeAccess composed MRs (OIDC provider,
  Roles, RolePolicy, AccessEntries, AccessPolicyAssociations) all `Ready=True` under
  the narrowed policy; spoke nodegroup ACTIVE after the SLR fix.
- **Run order reference:** `ai/handoff.md` auto-016 block.
