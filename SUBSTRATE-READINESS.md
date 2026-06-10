# SUBSTRATE-READINESS.md — the definition of "done" for the platform bring-up

This file exists because "done" kept meaning *"I made the live symptom go away with a
hand-fix"* instead of *"the committed code produces a working platform from nothing."*
Those are different, and conflating them is why the same gaps keep biting on every
fresh account.

This is a **gate, not a wish.** An item is DONE only when its **Clean-build evidence**
column holds a verifiable pointer. No pointer ⇒ the status is
`pending clean-build verification` — never "done", "fixed", "works", or "proven".

---

## Definition of done (the only one)

> A build from **committed `main`** — terraform phases 0→1 via CI `apply-and-verify`,
> then the spoke via **ArgoCD GitOps** synced from committed `main` — brings up
> **hub Ready + spoke Ready + `hello.platform.<domain>` → HTTP 200 (valid public cert)**,
> with **ZERO manual steps**.

The substrate is not done until that is true and captured with evidence below.

## What counts as a manual step (i.e. a FAILURE of the definition)

If a clean bring-up needs **any** of these, it is **not** done — the thing that
required the step is an open blocker, not a closed issue:

- An inline IAM policy / `aws iam put-role-policy` to make a controller work.
- `aws ec2 authorize-security-group-ingress` (hub→spoke or otherwise).
- `aws ec2 create-tags` on subnets.
- A hand `kubectl apply` / `kubectl create namespace` of anything ArgoCD/Crossplane
  should own.
- An `argocd app set` / `kubectl patch` overlay of a placeholder value.
- Pausing or `ignoreDifferences`-ing `bootstrap` to make an overlay stick.
- Hand-registering the spoke cluster Secret with ArgoCD.

## What counts as Clean-build evidence (the only thing that earns a checkmark)

- A **CI run ID** of `terraform-test.yml apply-and-verify` from the committed branch
  (the IAM/terraform layer), **AND**
- a **GitOps sync from committed `main`/the branch** (no out-of-band patches), **AND**
- the relevant **behavioral check passing on that build** (the live-suite check or a
  recorded `kubectl`/`curl` result).

A live hand-fix is **NOT** evidence. It validates the *mechanism*, never the *artifact*.

---

## The readiness checklist (current state: nothing earned yet)

| # | Item / known gap | Durable fix | Clean-build evidence | Status |
|---|---|---|---|---|
| 1 | EKS service-linked-role `iam:GetRole` (zero-node spoke) | PR #213 (committed `irsa.tf`) | **RETRACTED.** The earlier "VALIDATED" was a **selective nodegroup recreate inside an environment the agent had hand-modified all night** — a poke certified as a clean build (see `retrospective/2026-06-09-214-a.md`). It proves nothing. **No clean-build evidence exists.** | **pending clean-build verification** (the only valid proof is a from-scratch bring-up from committed source in an uncompromised environment) |
| 2 | Hub→spoke EKS-API SG 443 (OI-2026-06-07-4) | BUILT 2026-06-10 (`hub-eks-api-ingress` classic SecurityGroupRule in the platform-cluster Composition; mgmt node SG published via the cluster-network EnvironmentConfig). Unit lint + render golden committed with it. | — | **pending clean-build verification** |
| 3 | Shared ELB subnet tags (OI-2026-06-07-3) | **not built** (live `create-tags` only) | — | **blocker — durable fix not built** |
| 4 | Placeholder overlays vs bootstrap selfHeal (OI-2026-06-07-2, **ADR-0010** cluster-facts via cluster-Secret annotations + ApplicationSets — supersedes ADR-0005's ConfigMap corollary) | consumer half COMMITTED (the spoke apps are ApplicationSets templating the five-fact contract; no hand-overlay surface remains). Producer half = row 5 (now built). | — (needs the clean build) | **pending clean-build verification** |
| 5 | Spoke ArgoCD cluster-Secret durable form (OI-2026-06-07-1) | BUILT 2026-06-10 (ADR-0010 PR-2: provider-kubernetes Observe + writer Objects in the xspokeaccess Composition; also retires the spec.oidcIssuer overlay — a banned manual step). Unit contract lint + render golden + chainsaw scenario + live oracle (`spoke-cluster-secret-live.sh`) committed with it. | — | **pending clean-build verification** |
| 6 | RDS narrowing safe on the CREATE path (#211) | PR #211 (committed) | — (DB pre-existed; only ongoing-reconcile seen) | **pending clean-build verification** |
| 7 | EC2 narrowing safe on the CREATE path (#212) | PR #212 (committed) | — (never applied live) | **pending clean-build verification** |
| 8 | Hello hub→spoke e2e (OI-2026-06-08-2) | PR #210 (check authored) | — (never run) | **pending clean-build verification** |

**No row may flip to DONE without filling its evidence column.** The agent does not
get to assert these are fixed; you (or anyone) can audit each one by clicking the
run ID.

---

## The order of operations to actually finish (no test work until this is green)

1. Build the four missing durable fixes (#2–#5). #4 (cluster facts, ADR-0010) is
   the keystone — its consumer half is committed; #5 (the labeled registration
   Secret, ADR-0010 PR-2) is now what blocks hello.
2. Put #213 + #211 + #212 + #2–#5 on one integration branch.
3. **Tear down to a clean state (or take a fresh account) and rebuild from that branch
   with ZERO manual steps.** This is the part that has never been done. The point of a
   long unattended window is to *spend it here*, not to declare victory at the first
   green demo.
4. Fill in the evidence column from that clean build. Only now are these items done.
5. Then — and only then — resume the test-overhaul work (the SKIP-kind flips, the live
   evidence gate, Track B) on a substrate that actually works from nothing.

A fix that cannot be validated this way in the current session stays
`pending clean-build verification` and is carried as a **blocker**, not silently
deferred into the open-issues graveyard.
