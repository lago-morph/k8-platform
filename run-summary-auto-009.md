# auto-009 run summary — "to phase 6 clean" (2026-06-06)

Autonomous long run delegated 2026-06-06 ("Long run from here. Keep working").
Account: `211125540973` (us-east-1). Scope envelope: `decisions/auto-009-scope-envelope.md` (PR #155).
Supersedes `run-summary.md` (auto-007, dead account 730335382332) for current state.

---

## 1. TL;DR

- **CI-red blocker on `main` cleared.** `crossplane render` failed every push because it defaulted its orchestrator image to the floating `:stable` tag (drifted to v1.20.9 → `unexpected argument internal`). Pinned to `CROSSPLANE_CHART_VERSION` (v2.3.0). Merged in **#153**; `OI-2026-06-06-1` closed.
- **A working `.github/workflows/*` write path now exists** for web sandboxes — the git-push OAuth token and GitHub MCP both lack `workflow` scope (anthropics/claude-code #61189; confirmed a regression against this repo's own history). The jentic PAT was granted Contents+Workflows write and wired into the `ext-github` skill (new Contents-PUT endpoint `op_12ee1daaad73b14b`, SKILL.md §8); live-fired on `unit-tests.yml`.
- **The entire auto-007 phase 3-6 stack landed on `main`** (#144→#145→#146→#147→#148): phase-3 spoke, phase-4 observability, phase-5 Keycloak, phase-6 workload1 — each conflict-resolved against current main (helm.tf / run.sh / platform-spoke.yaml unioned), CI-green. The stack needed **no chainsaw runs** (none touch `crossplane/**` or `tests/chainsaw/**`; `chainsaw-verify` is non-required — #144 merged with it red).
- **Phase-4 Alloy (Option A: `hub-addons` AppProject) + phase-5 DB (general `XDatabase` XRD, RDS-backed) decisions recorded** on main (#154; `decisions/2026-06-06-phase4-alloy-phase5-db.md`).
- **Live rebuild:** phase-0 base **GREEN** (run 27054644974 — confirms the fresh GH-Actions secrets work). Phase-1 management **FAILED** on a crossplane provider-bootstrap deadlock → diagnosed (`OI-2026-06-06-2`), adversarially reviewed (3 real subagents), fixed (**#156**), **live-validation dispatched** (result pending — Morning item #1).

## 2. Suggested merge order

Stack #144-148, #153, #154 **already merged**. Remaining open PRs:

1. **#155** — auto-009 scope envelope + stack-landing plan. Docs-only, green. Merge anytime.
2. **#156** — provider-SA bootstrap fix. **DO NOT MERGE until its live `management apply-and-verify` is green** (dispatched on branch `fix/auto-009-mgmt-provider-sa`; Morning item #1). Unit/validate CI passing is NOT sufficient.
3. **this PR** (auto-009 run summary) — docs-only; merge anytime.

## 3. PRs (this run)

| PR | Title | Status |
|---|---|---|
| #153 | CI render fix + version pins + ext-github workflow-write endpoint | ✅ merged |
| #154 | phase-4 Alloy + phase-5 DB decisions | ✅ merged |
| #155 | auto-009 scope envelope + stack-landing plan | open (green) |
| #144 | auto-007 trunk | ✅ merged |
| #145 | phase-3 spoke foundation | ✅ merged |
| #146 | phase-6 workload1 cluster | ✅ merged |
| #147 | phase-4 observability | ✅ merged |
| #148 | phase-5 Keycloak | ✅ merged |
| #156 | provider-SA bootstrap fix (DO NOT MERGE until live-green) | open |
| (this) | auto-009 run summary | open |

## 4. Decision briefs / reviews

| Brief | Rounds | Outcome |
|---|---|---|
| `decisions/auto-009-stack-landing-plan.md` | 1 investigation subagent | no chainsaw needed; chainsaw-verify non-required; one helm.tf conflict — all confirmed correct in practice |
| `decisions/auto-009-mgmt-provider-sa-fix.md` | Round-1: 3 real adversarial subagents | all **accept-with-amendment**; amendments (depends_on ordering, broadened diagnostics, chainsaw name-align, one-Provider assertion, gate-on-live-run) folded into #156. Compressed to 1 round — the **live apply is the decisive empirical validator**; documented. |

## 5. Chain status

- **Stack landing: COMPLETE** — phases 3-6 scaffolding on main.
- **Live rebuild: phase-0 done; phase-1 blocked → fix in live-validation; phases 2/3 not reached.**
- **Phases 4/5/6 LIVE implementation (hub-addons AppProject, XDatabase XRD+RDS, maxPods): NOT STARTED** — gated on the management cluster coming up (on #156's fix working).

## 6. Morning-review items (need your call)

1. **Provider-SA fix live validation (top item).** #156 is authored + reviewed; a `management apply-and-verify` was dispatched on its branch. **The wedged management cluster from the failed run still holds the two stuck Providers**, and the renamed Provider is applied via `kubectl apply` (no prune), so the old `provider-family-aws` object may linger — a *plain* re-apply may not cleanly validate. A clean validation likely needs a **management `terraform destroy` + re-apply**, which is **outside the auto-009 no-destroy envelope**, so I did not do it. **Your call:** authorize a destroy+reapply for a clean test, or read the dispatched run's diagnostics first — they capture `describe providerrevision` / `get lock` / crossplane logs, which also decide whether the root cause is the duplicate-Provider deadlock *or* a package-manager-wide stall (reviewer #1's open question).
2. **Phases 4/5/6 live** were not built — they depend on the platform cluster, which depends on a healthy management cluster (#156). Once #156 is validated + merged, the next session implements: the `hub-addons` AppProject (convert the parked `argocd/apps/spoke/observability-alloy-mgmt.yaml.todo`), the `XDatabase` XRD + RDS Composition for Keycloak's `keycloak-db`, and the **maxPods/prefix-delegation** finish (still half-done — nodes cap ~17 pods; needed before the 4/5/6 pod load).

## 7. What I deliberately did NOT do

- **No `terraform destroy` of any phase** (envelope boundary) — so the provider-SA fix is validated only as far as a non-destructive re-apply allows; clean validation is a flagged morning item.
- **No phases 4/5/6 live build** — gated on the cluster; deferred with the implementation notes above.
- **Did not re-author the auto-007 stack** — landed it as-is per your decision.
- **Did not merge #156** — its body forbids merge before a green live run.

## 8. Rewind points

| SHA | Undoes |
|---|---|
| `2dff004` (#148 merge) | phase-5 Keycloak off main |
| `53493ad` (#147) | phase-4 observability |
| `22f9974` (#146) | phase-6 workload1 |
| `a8616a0` (#145) | phase-3 spoke |
| `ae807b3` (#144) | auto-007 trunk |
| `c3a6cb3` (#153) | render fix + version pins + ext-github write endpoint |
| `a0bf9ea` (#156, unmerged) | provider-SA fix |
| `chore/auto-009-scope-envelope` | the run contract (#155) |

## 9. Session metadata

- Run: auto-009, 2026-06-06. Account `211125540973`.
- Subagents: ~9 (1 stack-landing investigation, 4 stack conflict-resolutions, 1 provider-SA diagnosis, 3 adversarial reviewers, 1 provider-SA implementation) — worktree-isolated where they touched git.
- Open issues: `OI-2026-06-06-1` (render, closed), `OI-2026-06-06-2` (provider-SA, fix in live-validation).
- `send_later` unavailable; live-run re-checks were timer-driven (no webhooks for `main`/branch `workflow_dispatch`).
