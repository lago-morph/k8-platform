# auto-007 run summary — phases 3-6 long run (2026-06-05)

**Mandate:** finish phase 3, do as much of phases 4/5/6 as possible, building live
on a fresh AWS account. Throughput mode (AGENTS §6.6); decisions via brief + 2
adversarial rounds (autonomous-run skill).

---

## 1. TL;DR

- **Live build advanced two phases:** phase 0 (base) and phase 1 (management) are
  **VERIFIED green on the fresh account 730335382332** (runs 27035432871,
  27035617598). EKS `k8-platform-mgmt` is ACTIVE with ArgoCD + Crossplane +
  providers + ESO + Kyverno + IRSA. A `management verify` (27037148562)
  re-confirmed ArgoCD HTTPS-200 from CI.
- **Phase 3 spoke + phases 4/5/6 are authored as tested, CI-verifiable GitOps PRs**
  (5 stacked PRs). In a GitOps repo the committed, reviewed manifests + tests ARE
  the deliverable (AGENTS §6.22); ArgoCD/Crossplane converge them.
- **The live platform-cluster provision is BLOCKED by environmental constraints**
  (not code): this sandbox cannot reach ArgoCD (proxied egress 503s it), I cannot
  create a CI sync workflow (the push token lacks `workflow` scope; the MCP App
  returns 404 on workflow paths), and kubectl is blocked by the EKS private CA.
  The complete live-completion path is captured in
  `decisions/auto-009-phase3-live-completion-runbook.md`. **This is the #1
  morning-review item.**
- **Design rigor:** the spoke GitOps delivery design (`decisions/auto-008`) was put
  through **2 adversarial rounds / 5 real subagent reviewers**, which caught
  blockers (OIDC thumbprint, separate XSpokeAccess Composition, dual-ExternalDNS
  TXT corruption, no spoke ArgoCD auth) before any code shipped.
- **Sandbox creds had a leading-space injection bug** (key 21→20, secret 41→40
  chars); stripped to make AWS CLI work. **CI's GitHub Actions creds are fine**
  (the base apply proved it).

## 2. Suggested merge order

The phase-3 line is a stack; phases 4/5/6 are siblings off the spoke foundation.

1. **#144** `claude/long-run-phases-3-6-7icMB` → main — trunk: scope envelope +
   auto-008/009 briefs + this summary + open-issues updates. (merge first)
2. **#145** `feat/phase3-spoke-foundation` → #144 — phase-3 spoke GitOps foundation
   (AppProject, spoke apps, values, hub ExternalDNS fix, 6 tests). Auto-rebases to
   main once #144 merges.
3. Then the three siblings (each off #145; **#147 and #148 both edit
   `argocd/projects/platform-spoke.yaml` sourceRepos — expect a trivial 3-way
   merge conflict on the 2nd**):
   - **#146** `feat/phase6-workload1-cluster` — workload1 cluster + spoke stack.
   - **#147** `feat/phase4-observability-scaffolding` — obs stack (has the hub-Alloy
     AppProject open question).
   - **#148** `feat/phase5-keycloak-auth` — Keycloak (has the DB open question).

All five are independently CI-gated (unit + kubeconform + terraform-validate). No
live AWS resource is created by merging any of them (the spoke apps stay inert
until the platform cluster exists + is registered).

## 3. PRs opened

| PR | Branch | Title | Base | Rewind |
|---|---|---|---|---|
| #144 | claude/long-run-phases-3-6-7icMB | trunk: scope envelope + run docs | main | revert chain |
| #145 | feat/phase3-spoke-foundation | phase-3 spoke GitOps foundation | #144 | `b71bc54` |
| #146 | feat/phase6-workload1-cluster | phase-6 workload1 cluster + spoke | #145 | branch |
| #147 | feat/phase4-observability-scaffolding | phase-4 observability | #145 | branch |
| #148 | feat/phase5-keycloak-auth | phase-5 Keycloak auth | #145 | branch |

## 4. Decision briefs

| Brief | Subject | Rounds |
|---|---|---|
| auto-007-scope-envelope | run scope/boundaries | n/a |
| auto-008-spoke-gitops-delivery | how spokes get add-ons via GitOps | R1 (3 reviewers) + R2 (3 reviewers) — FINAL |
| auto-009-phase3-live-completion-runbook | exact live steps + MR manifests to finish phase 3 | runbook |

## 5. Chain status

- **Live:** phase 0 ✅, phase 1 ✅, phase 2 chainsaw dispatched (run on `534a0ce` —
  check conclusion), phase 3 cluster ⏳ blocked (see morning items).
- **Code:** phase-3 spoke foundation ✅ (CI-verifiable); phases 4/5/6 scaffolding ✅
  (CI-verifiable); live-coupled spoke infra (XSpokeAccess) specified in auto-009,
  not yet authored as manifests (deliberately — reviewers showed it needs live
  iteration).

## 6. Morning-review items

1. **Unblock the live platform-cluster sync (highest priority).** Pick one:
   (a) re-run from a sandbox/context that can reach `argocd.management.<domain>`,
   (b) add the `argocd-app-sync` workflow to main (its full YAML +
   manual-add instructions are in `docs/runbooks/argocd-sync-from-ci.md` — I
   couldn't push it: no `workflow` scope), then dispatch it for
   `platform-cluster-claim`, or (c) merge a one-time change enabling a CI sync.
   Then follow `decisions/auto-009-…` end-to-end. Recommendation: (b) — it's the
   reusable §10.1 mechanism for every future sync.
2. **Phase-4 hub-Alloy AppProject (#147).** Alloy's destination is the hub, which
   fits neither AppProject. Recommendation: a new `hub-addons` AppProject (this
   repo + grafana repo, Alloy kinds). Parked as `.yaml.todo`; needs your call.
3. **Phase-5 Keycloak DB (#148).** External `keycloak-db` Secret expected; backend
   (RDS-via-Crossplane vs in-cluster Postgres) undecided. Recommendation:
   Crossplane-managed small Postgres (matches "production-like"); ephemeral fallback
   if RDS quota bites. Needs a brief.
4. **Stale handoff guidance corrected.** `ai/handoff.md` previously claimed "the
   sandbox has permissive egress; call ArgoCD directly from the sandbox" — FALSE in
   this sandbox. Updated on #145. The §10.1 CI-driven sync is the durable path.

## 7. What I deliberately did NOT do

- **Did not author the XSpokeAccess Composition as live manifests.** Both R2
  reviewers showed it has too many live-dependent unknowns (OIDC thumbprint, exact
  MR field shapes, EnvironmentConfig account-id wiring, provider-kubernetes) to
  author blind with confidence. Captured as the auto-009 runbook for live execution.
- **Did not flip `platform-cluster-claim` to auto-sync** to force a build — that
  violates the manual-sync safety invariant (an everyday push must never provision
  a real EKS cluster).
- **Did not run the live spoke registration / hello verify** — gated on the
  platform cluster existing, which is blocked (item 1).
- **Did not rename the v1-era `*-claim` artifacts** (handoff follow-up #5) —
  orthogonal, out of scope.

## 8. Rewind points

| SHA / PR | Undoes |
|---|---|
| #144 revert | the entire run (envelope + all briefs + summary) |
| #145 `b71bc54` | phase-3 spoke foundation |
| #146/#147/#148 branches | phase 6 / 4 / 5 scaffolding respectively |
| `terraform/management/helm.tf` hunk in #145 | hub ExternalDNS domain-filter narrowing |

## 9. Session metadata

- Branch chain at end: trunk #144 → #145 → {#146, #147, #148}.
- Subagents: 5 adversarial reviewers (auto-008) + 3 authoring (phases 4/5/6) + 1
  Explore (pattern mapping) = 9.
- Live runs: 27035432871 (base✅), 27035617598 (mgmt✅), 27037148562 (mgmt
  verify✅), chainsaw on `534a0ce` (phase 2), management verify confirmed ArgoCD up.
- Account: 730335382332 (fresh, only Route53 zone pre-existed).
- Tools installed in sandbox: aws, helm, kubectl, argocd, kubeconform, terraform.
