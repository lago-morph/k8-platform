# auto-010 — Scope envelope (unattended run, 2026-06-06)

Run trigger: user delegated an extended unattended run — "make k8 nodes allow
many more pods, validate the entire phase 0-3 build, then complete phases 4-5
and validate their builds." Fresh AWS account (verified live: account
`596430611165`, region us-east-1, Route53 zone present, **no** EKS cluster /
tfstate bucket / running EC2 — completely empty). Creds valid in both the
sandbox and CI.

This envelope is the run's fallback contract per the `autonomous-run` skill.
It is committed as the first file of the run so the user can rewind to
"before the run began."

---

## 1. What I plan to do

1. **Finish maxPods / prefix-delegation** so nodes allow ~110 pods instead of
   ~17. The vpc-cni prefix-delegation addon is already in `eks.tf`; the missing
   half is the kubelet `maxPods` bump. On a *fresh* build the nodes are created
   with the new setting (no risky live recycle). Verify by decoding the launch
   template user-data in the CI plan (must be nodeadm/AL2023 format with
   `maxPods: 110`, NOT AL2 `bootstrap.sh`).
2. **Validate the phase 0-3 build on the fresh account** via CI
   (`terraform-test.yml`): base → management (carries the maxPods change + the
   merged provider-bootstrap fix) → phase-2 chainsaw → phase-3 platform-cluster
   XR provision and spoke bring-up per `decisions/auto-009-phase3-live-completion-runbook.md`.
3. **Complete phase 4 (observability)**: the `hub-addons` ArgoCD AppProject +
   Grafana Alloy on the hub (convert `observability-alloy-mgmt.yaml.todo`), per
   the recorded Option-A decision. Author the matching tests.
4. **Complete phase 5 (auth)**: a general `XDatabase` XRD + an RDS-backed
   Composition for Keycloak's `keycloak-db`, per the recorded decision; wire
   Keycloak to consume the abstraction. Author render-fixtures + chainsaw +
   unit tests.
5. **Validate the phase 4 and phase 5 builds** (chainsaw for new XRDs/Compositions,
   live ArgoCD sync where the cluster is up).
6. **Keep `ai/handoff.md` current** after every state change, and produce the
   required morning summary + full self-retrospective at run end.

## 2. What I plan to NOT do

- **Phase 6 (workload1).** Scaffolding is already on main; the user scoped this
  run to phases 0-5. I will not build phase 6 live.
- **No teardown of any phase** unless an apply explicitly requires a phase-N-only
  recycle to fix drift (§5 invariant: never destroy a lower phase).
- **No re-litigation of the phase-4/5 design decisions** already recorded in
  `decisions/2026-06-06-phase4-alloy-phase5-db.md` (Alloy = Option A;
  Keycloak DB = general XDatabase, RDS impl).
- **No changes to the locked-down `k8-platform` ArgoCD project** beyond what
  Option A requires (the new `hub-addons` project is additive).

## 3. Scale estimate

- **~6-10 reviewable chunks** (maxPods, phase-3 provider-kubernetes, phase-3
  XSpokeAccess composition, phase-3 spoke registration/overlay, phase-4, phase-5
  XDatabase, phase-5 Keycloak wiring, morning summary). See decision point #1 on
  whether these land as stacked PRs or commits on the designated branch.
- **Subagents:** adversarial test-plan reviewers (AGENTS §6.4) at each
  test-drafting point — 2-3 per phase, run in parallel.
- **Duration:** several hours, dominated by CI wall-clock (mgmt apply ~15 min,
  chainsaw ~15 min, platform-cluster provision ~20 min, plus re-applies).

## 4. First decision points

**DP-1 — Branch strategy (structural; affects the whole run).** The harness
instructs me to develop on `claude/k8-pods-phase-validation-7oqVK` and "never
push to a different branch without explicit permission." That conflicts with
the autonomous-run default of many stacked PRs off `main`.
- **My default (compliance-safe):** do all work on
  `claude/k8-pods-phase-validation-7oqVK`, push only to it, open **one** PR to
  `main`, and use per-commit SHAs as rewind points (the skill treats
  brief+commit+SHA as a valid rewind unit). Each chunk is a clearly-described
  commit.
- **Alternative (if you grant it):** classic stacked PRs (child branches off
  the designated branch, each its own PR). More granular review; requires
  pushing additional branches.
- **Rewind:** either way, every chunk is an isolated commit; revert by SHA.

**DP-2 — maxPods value & mechanism.** Default: `ami_type =
AL2023_x86_64_STANDARD` + `cloudinit_pre_nodeadm` NodeConfig with
`kubelet.config.maxPods: 110`. Verified by decoding the CI-plan launch-template
user-data before any apply (the documented trap is the module emitting AL2
`bootstrap.sh`). Alternative: 58 (the prefix-delegation max-pods-calculator
value for t3.medium) — I'll use 110 (the EKS soft cap for small instances, and
what the existing addon comment targets). Rewind: the eks.tf node-group commit.

**DP-3 — Phase-3 spoke depth.** The runbook (auto-009) has 6 steps ending at
`https://hello.platform.<domain>` 200. Default: execute it fully. If the
platform-cluster provision or a spoke step hard-blocks (>3 strikes), I log it to
`docs/open-issues.md`, leave phases 0-2 verified, and continue to phases 4-5
(which only need the hub). Rewind: per-commit.

**DP-4 — Phase-4/5 "validate" depth.** Default: chainsaw + render-fixtures for
new XRDs/Compositions (author-time gates), plus live ArgoCD sync where the
relevant cluster is up. RDS provision (phase 5) is ~10-15 min live; if the
account/quota blocks it, I validate via chainsaw + render and log the live gap.

## 5. What I'll surface in the morning summary

- maxPods user-data decode evidence (the safety gate) + the management apply run URL.
- Phase 0-3 validation run URLs and per-phase verified/blocked status.
- Any bug found + the regression test added (TDD per AGENTS §6.2).
- Phase 4 and phase 5 PRs/commits, with chainsaw + live-sync evidence.
- Suggested merge order, rewind table (SHA → what it undoes), morning-review items.
- Anything I deliberately deferred (e.g. phase 6, any live step blocked by quota).

## 6. Stop conditions

**Stop early and write the handoff** if: AWS creds go invalid mid-run
(`InvalidClientTokenId`); the GitHub Actions dispatch path fails on all profiles;
context budget approaches ~70% (write summary+retro first); or a destructive
op outside scope would be required. **Do NOT stop** for: a sub-phase closing, an
ambiguous subagent result, or a decision that has a defensible default — those
get a decision and continue. A phase-3 live block does not stop the run; I
pivot to phases 4-5 and record the block.

---

*Posted to the user at run start. Proceeding with the section-4 defaults after a
brief wait, per the unattended-run contract.*
