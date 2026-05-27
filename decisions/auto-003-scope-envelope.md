# Scope envelope — autonomous run 2026-05-27 (Crossplane v1→v2 migration TAIL, auto-003)

**Run start:** 2026-05-27
**Driving prompt:** `decisions/auto-003-prompt-for-next-session.md` (committed via PR #109)
**Plan:** `ai/crossplane-v1-v2-un-fuckify/40-final-plan.md` (PR #99, merged) — §11 DoD items 5, 6, 8, 9 remain
**Predecessor:** `decisions/auto-002-scope-envelope.md` (run that authored the migration code)
**Skill:** `autonomous-run`
**Authorization to act:** user is structurally absent for the duration. Per the
task prompt: "Treat this as an overnight/long-running task — load the
`autonomous-run` skill." Approval comes from chat after morning review of
the run-summary PR; no per-PR pause.

**Branch policy.** Designated session branch:
`claude/auto-003-next-session-2n5IK` (per user prompt). The envelope itself
commits here. Each subsequent chunk lives on its own branch stacked off the
previous tip per AGENTS.md §3.

---

## 1. State of the world at run start

Verified from `git log` and the artifacts in repo at run start:

| Item | State | Source |
|---|---|---|
| AWS account | **freshly rotated** per prompt; secrets updated in repo Settings | user-asserted; verified by Step 1 below |
| `ai/handoff.md` Environment State block | **STALE** per prompt — Phase 0/1 "applied" lines reflect OLD account | re-verify on Step 1 |
| PR #105 (Wave 2 hotfix `claude/v2-exec-hotfix-xrd-connsec` @ `6a47acf`) | **OPEN** | last chainsaw dispatch 26440276628 — `xrd-establishes` PASS in 9s, 3 platform-secret scenarios timed-out 245s on stale creds |
| PR #91 (`claude/auto-run-2026-05-25-phase-2-A4` @ `380fbfe`) | **OPEN, stale** | content was cherry-picked into PR #104 (merged commit `5044815` + follow-ups); branch is dead |
| PR #94 (`claude/auto-run-2026-05-25-phase-2-C4` @ `5f43f46`) | **CLOSED, NOT MERGED** | selective salvage owed: 5 enforcer tests + Bug 4 fixture + 3 deterministic external-secret goldens |
| Merged to main this migration | PRs #97, #98, #99, #100, #101, #102, #103, #104, #106, #107, #108 | per prompt §"Merged to main" |
| `AGENTS.md` §6.8, §6.9, §8.2 | **NEW (this migration)** — must be honored | per prompt §"Read first" |
| `docs/decisions/0001-kubeconform-not-sole-gate-for-v2-crd-changes.md` | merged | load-bearing ADR for §6.8 |

Pre-committed cross-segment decisions (provider v2.5.0; `kind: ClusterProviderConfig`;
`apiextensions.crossplane.io/v2`; `managementPolicies: [Observe, Create, Update, Delete]`;
XR-level connection secrets REMOVED in v2) — **NOT relitigated**, per
prompt §"Pre-committed cross-segment decisions — DO NOT relitigate".

---

## 2. What I plan to do

In execution order (per `decisions/auto-003-prompt-for-next-session.md` §Execution order):

1. **Step 1: Environmental precondition check** (per AGENTS.md §8.2) — `whereami.sh --json`, `aws sts get-caller-identity`, list phase-0 state bucket on the rotated account. STOP if any fail.
2. **Step 2: terraform-test phase=base apply-and-verify against main** (~3 min) — bootstraps state bucket on the rotated account.
3. **Step 3: terraform-test phase=management apply-and-verify against main** (~15 min) — load-bearing; installs v2.5.0 providers on the EKS cluster; exercises helm.tf Function v1 pre-delete + rollout-status + SA-name post-check. Expected partial failure (ArgoCD Degraded from `connectionSecretKeys` rejection on main XRD until PR #105 merges; tolerated per prompt).
4. **Step 4: chainsaw FULL against PR #105's branch SHA** (`6a47acfe…`) — the §6.8 live-admission verification gate. Pass criterion: all 4 real-AWS scenarios + smoke + meta-catch-fires green.
5. **Step 5: Merge PR #105** (method: **merge**, NOT squash — preserve the 2 hotfix commits for audit per prompt).
6. **Step 6: chainsaw FULL against post-#105 main** — the §11 DoD item #5 ("when that one passes, the migration succeeded").
7. **Step 7: Close PR #91** — content already in main via PR #104 (`5044815` cherry-pick). Close + comment, no merge.
8. **Step 8: Open SEG-4 PR-T2** (render-fixture goldens, branch `claude/v2-exec-seg4-pr-t2-render-goldens` off main). If `crossplane` CLI is missing in sandbox, document the blocker in PR body and defer — do NOT block the run.
9. **Step 9: Open SEG-4 PR-T3** (chainsaw asm-secret goldens + PR #94 selective salvage; branch `claude/seg-4-c4-reauthor` off main). Live chainsaw regen for 3 asm-secret goldens; in-place edit for 3 deterministic ext-secret goldens; cherry-pick 5 enforcer unit tests + Bug 4 fixture.
10. **Step 10: Update `ai/handoff.md`** (Phase 0+1 lines reflect rotated account; use Step-2/3 run URLs as evidence).
11. **Step 11: End-of-run protocol** — drain in-flight CI, commit clean, write `run-summary-2026-05-27.md` (date verified via `date -u`), auto-invoke `self-retrospective`, subscribe to all opened PRs, one-paragraph status message.

**Total estimated PRs: 4-6** (PR-T2, PR-T3, handoff update, run-summary, retrospective; PR #105 is merged via MCP so doesn't count as opened).

---

## 3. What I plan to NOT do

- **NOT touch `ai/crossplane-v1-v2-un-fuckify/*.md`.** Plan docs are frozen for traceability.
- **NOT relitigate pre-committed cross-segment decisions.** Provider tag, ProviderConfig kind, XRD apiVersion, managementPolicies, XR-conn-secrets removal — all settled.
- **NOT begin Phase 3 work.** ApplicationSet kubeconfig source repoint (XR-aggregated → MR-direct) is explicitly Phase 3 follow-up; out of scope.
- **NOT push to main directly.** Per AGENTS.md §3. PR-T2 and PR-T3 open ready-for-review.
- **NOT destroy live AWS resources** beyond what `terraform-test apply-and-verify` already exercises.
- **NOT skip §6.9** (fetch failure log via `ext-github` op `op_c08d23e5bd6966cb` BEFORE forming any hypothesis on a CI failure).
- **NOT skip §8.2** (re-check environmental preconditions on infra-shape errors before forming any code hypothesis).

---

## 4. Scale estimate

- **Target PR count:** 4-6 PRs (PR-T2 render goldens; PR-T3 chainsaw goldens + #94 salvage; handoff update; run-summary; retrospective; up to 1 decision-brief PR if Step 4 surfaces a non-environmental issue). Plus PR #105 merge (no new PR).
- **Subagent count estimate:** 0-6 (decision-brief adversarial reviews only if a Step-4 or Step-6 failure forks at user-input territory).
- **Expected wall-clock:** ~25-40 min CI time (3 + 15 + 10 + 10 min wall clock for the 4 dispatches) + authoring time for PR-T2/T3.

---

## 5. First decision points

Predicted at envelope time. Each gets a decision brief + 2 adversarial rounds if it materializes per `autonomous-run` skill protocol.

1. **D-Step4-failure-mode — chainsaw against PR #105 not green after rotation.**
   - **Lead-agent current best:** if the failure shape is again `Unready resources: asm-secret @ 245s`, the catch-block namespace-mismatch bug (flagged in prompt §Step 4: "catch reads `$NAMESPACE` = chainsaw's per-scenario namespace, but scenarios apply XRs in `namespace: default`") is the next hypothesis — patch scenarios to use `($namespace)` for XR namespace, re-dispatch. If a different shape, fetch log first per §6.9 and classify per failure taxonomy.
   - **Alternative:** decision brief if the failure resists 3 fix attempts.
   - **Rewind:** PR #105 stays open; rollback PR-Step4-fix branches.
2. **D-Step6-failure — post-#105 chainsaw red.** Lead-agent best: STOP, write decision brief — this would indicate the migration's underlying observe-roundtrip on v2.5.0 still has issues. Alternative: roll forward only if I can identify a precise fix from the log.
3. **D-PRT2-crossplane-CLI-missing — `crossplane` CLI not in sandbox.** Per prompt §Step 8: install if possible, else document the blocker in PR body and defer. Lead-agent best: attempt install (Go binary download); if blocked, defer cleanly — does NOT halt the run since PR-T3 + handoff + summary + retro can still ship.

---

## 6. What I'll surface in the morning summary

- The 4-6 PR URLs with suggested merge order.
- §11 DoD checklist (10 items) — which closed this run, which deferred.
- The most consequential moment: **chainsaw.yml full GREEN against post-#105 main** (the migration's hinge).
- Whether PR #105's rotation-fix hypothesis was confirmed by Step 4, or required additional fixes.
- Any decision briefs written, with Round-1/Round-2 reviewer consensus.
- Open follow-ups (Phase 3 kubeconfig path change; anything PR-T2/T3 could not generate due to sandbox limits).
- Any `ai/handoff.md` invariants found stale beyond the Phase 0/1 lines.

---

## 7. Stop conditions

**Allowed to stop:**

- All §11 DoD items closed + run-summary + retro committed and pushed.
- Step 1 hard failure (creds rotation didn't take; account access lost).
- Context budget approaches ~70% — write summary + retro NOW.
- GitHub MCP auth dropped after `github-connection-resilience` recovery attempts fail.
- 30-PR cap (very unlikely — this run probably opens 2-3 PRs).
- User chat message arrives.

**NOT allowed to stop:**

- "I think the rotation is good" without `aws sts get-caller-identity` evidence.
- A sub-phase closed — start the next.
- Stale-AWS-creds symptom returns (245s `Unready resources:`) — do NOT assume rotation fixed it; re-fetch log and confirm with current evidence per §10.1/§8.2.
- Step 4 (chainsaw against #105 branch) green but Step 6 (post-#105 main) not yet run — that's not done.

---

## 8. End-of-run protocol (non-optional per skill)

1. Drain in-flight subagents / CI runs.
2. Commit + push everything; verify `git status` clean.
3. Write `run-summary-2026-05-27.md` at repo root.
4. Update `ai/handoff.md` Phase 0/1 lines.
5. Auto-invoke `self-retrospective` skill.
6. Subscribe to PR-T2 + PR-T3 + run-summary PR via `mcp__github__subscribe_pr_activity`.
7. End with one-paragraph status message naming the run-summary PR, suggested merge order, and morning-review items.

---

## 9. User response (filled in by user, or implicit-confirm)

- **Confirm as-written:** implicit (user is structurally absent per prompt; envelope is the contract).
- **Adjustments:** none expected pre-run.
- **Implicit-confirm after wait:** yes — proceeding immediately since the prompt explicitly says "That's it. Now: write your scope envelope, then start executing."
