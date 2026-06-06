# auto-011 — Scope envelope (unattended run, 2026-06-06 → 07)

Run trigger: user delegated an extended unattended run to **continue the
k8s-platform build** on the INHERITED live account `596430611165` (us-east-1).
Stated tasks, in order: (1) get phase-2 chainsaw green on PR #159 and re-run
`chainsaw-verify`; (2) **Phase 3 LIVE** per
`decisions/auto-009-phase3-live-completion-runbook.md`; (3) **Phase 5 LIVE**
(keycloak-db RDS); (4) merge PR #159.

This envelope is the run's fallback contract per the `autonomous-run` skill,
committed as the first file of the run for rewindability.

---

## 0. Reality reconciliation (state at run start differs from the prompt)

Verified live at run start (sandbox creds valid; `whereami.sh` →
account `596430611165`, us-east-1; EKS `k8-platform-mgmt` **ACTIVE** v1.35,
3 nodes, 3 EC2 running; ArgoCD UI **HTTP 200**):

- **PR #159 is ALREADY MERGED** (merged by `jonathanmanton` 2026-06-06T22:13Z
  into `main`; merge commit `c8128cb`; head branch `…-7oqVK` deleted). So task
  **(1)** (get #159 green) and task **(4)** (merge #159) are **already done** —
  the user merged it themselves. ArgoCD tracks `main` and is synced to `c8128cb`.
- This sandbox is **fresh/ephemeral**: `aws`/`argocd`/`kubectl`/`helm` were NOT
  installed (the handoff's "tools installed" note was the prior sandbox).
  Installed `aws` v2 + `argocd` v3 this run. kube-API stays **private-CA
  blocked** from the sandbox (handoff) → all kube ops via `argocd` CLI / CI /
  AWS CLI.
- **First live blocker found:** ArgoCD `crossplane-resources` app is OutOfSync
  with `SyncError` — the `k8-platform` AppProject `clusterResourceWhitelist`
  does not permit `rbac.authorization.k8s.io/ClusterRole(Binding)`, so the
  ESO-RBAC manifest (`crossplane/rbac/01-crossplane-externalsecrets.yaml`,
  merged in #159) cannot apply. This blocks the XRDs + Compositions, which
  phase-3 depends on. Fix = whitelist those two kinds in the AppProject.

So the **real remaining work is Phase 3 LIVE + Phase 5 LIVE**, gated behind a
GitOps unblock.

## 1. What I plan to do

1. **Unblock `crossplane-resources`**: add `ClusterRole`/`ClusterRoleBinding`
   (group `rbac.authorization.k8s.io`) to the `k8-platform` AppProject
   `clusterResourceWhitelist`; merge to `main`; let bootstrap (auto-sync) +
   crossplane-resources (auto-sync) converge so the XRDs + Compositions apply.
2. **Phase 3 LIVE** per the auto-009 runbook: manually sync
   `platform-cluster-claim` → platform EKS + `*.platform.<domain>` ACM cert
   (~20 min); **build the `XSpokeAccess` Composition** (OIDC provider +
   external-dns IRSA + ArgoCD AccessEntry — new code, render-fixtures +
   kubeconform + adversarial review); register the `platform-spoke` cluster
   Secret; overlay ephemeral values; converge spoke apps; verify
   `https://hello.platform.596430611165.realhandsonlabs.net` → 200 w/ valid ACM
   chain.
3. **Phase 5 LIVE**: sync the `keycloak-db` XDatabase XR; verify the RDS
   instance + connection Secret; confirm Keycloak consumes it. Fallback:
   validate the RDS flow via a real-AWS chainsaw run (`CHAINSAW_INCLUDE_REALAWS=1`)
   if the spoke isn't up in time.
4. **Keep `ai/handoff.md` current**; produce the morning summary + full
   self-retrospective at run end.

## 2. What I plan to NOT do

- **No phase 6 (workload1)** — out of scope; leave its apps inert.
- **No teardown / no destroy** of any live phase-0/1 resource.
- **No rebuild of phases 0/1** — they are applied + verified live (handoff).
- **No direct `kubectl`/out-of-band live mutation** — GitOps only (kube-API is
  blocked anyway); every cluster change lands via a merged manifest + ArgoCD.

## 3. Scale estimate

3–7 PRs (AppProject unblock; XSpokeAccess composition; spoke registration /
values overlay; phase-5 wiring if needed; handoff+summary+retro). 2 rounds × ≥3
real adversarial subagents for the load-bearing XSpokeAccess design brief. Run
duration bounded by live provisioning waits (platform EKS ~20 min, RDS ~15 min).

## 4. First decision points

- **DP-1 — Merge GitOps fixes to `main` myself to drive live ArgoCD.**
  Decision: **yes.** Completing phases 3/5 LIVE is the explicit goal, ArgoCD
  tracks `main`, and the kube-API is blocked so there is no out-of-band path.
  The user already merged #159 themselves. Each change is a standalone
  ready-for-review PR with per-commit rewind points; I subscribe to each.
  Rewind: revert the GitOps commit → ArgoCD auto-prunes; plus targeted AWS
  cleanup for anything already provisioned (documented per-PR).
  Alternative (leave all PRs unmerged for morning review) → phases 3/5 cannot
  complete this run, contradicting the explicit task.
- **DP-2 — XSpokeAccess composition design** (OIDC thumbprint constant; IRSA
  trust-policy `sub`+`aud`; AccessEntry principal/policy). Load-bearing →
  gets a two-round decision brief with real adversarial review
  (`decisions/auto-011-xspokeaccess-design.md`).
- **DP-3 — Phase-5 live vs chainsaw fallback.** Decision: attempt live RDS via
  the XR once the spoke exists; fall back to a real-AWS chainsaw run if phase-3
  runs long. Flag the chosen path in the morning summary.

## 5. What I'll surface in the morning summary

The merge order; each live resource provisioned (with AWS ARNs/ids) and its
rewind/cleanup path; the XSpokeAccess design decision + review outcome; phase-5
path taken; any verification that had to be deferred to CI; open issues.

## 6. Stop conditions

Stop (with summary + retro) on: context-budget pressure (~70%), a hard live
failure I cannot diagnose after reasonable iteration (e.g. provider quota /
IRSA dead-end), auth/egress loss to ArgoCD or AWS, or completion of phases 3+5.
NOT stop conditions: a long provisioning wait (poll), an ambiguous live result
(diagnose + brief), or "a phase closed" (start the next).
