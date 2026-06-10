# Autonomous-Run Evidence Corpus

**Scope:** Named runs 2026-05-25/26/28 (= auto-001/002/003) and auto-004 through auto-016.
**Sources:** `run-summary-*.md`, `overnight-summary.md`, `handoff-followups-2026-05-28.md`,
`run-envelope-auto-016.md`, `decisions/auto-0NN-scope-envelope.md`,
`planning/test-overhaul/SCOPE-ENVELOPE-auto-0*.md`, `ai/handoff.md`,
`.claude/skills/autonomous-run/SKILL.md`.

---

## Headline Facts (10 bullets)

1. [FACT] 16 numbered autonomous runs are identifiable (auto-001 through auto-016). Named
   dates 2026-05-25/26/28 map to auto-001/002/003 respectively. Source: run summaries.
2. [FACT] Scope envelopes exist in `decisions/` for runs 001–005, 007, 009–012 (10 of 16).
   Runs 006 and 008 have decision/brief docs but no envelope file. Runs 013–015 have
   envelopes in `planning/test-overhaul/`. Run 016 has `run-envelope-auto-016.md` at repo
   root. Source: glob results.
3. [FACT] Run summaries exist for: named 2026-05-25/26/28 (= 001/002/003), and
   auto-004 (`overnight-summary.md`), auto-007 (`run-summary.md`), auto-009 through
   auto-016. No top-level summary file found for auto-005, auto-006, auto-008. Gap: 3 runs
   lack summaries.
4. [FACT] The autonomous-run SKILL.md was imported 2026-05-25 (commit `0d3d455`) and
   expanded twice: commit `c46f491` (2026-06-07, mandate proper retro + protocol tightening)
   and commit `a7ca8f8` (2026-06-07, adopt human-scoped-deliverables for morning summaries).
5. [FACT] Auto-005 scope envelope was superseded mid-run. It bounded live work out on the
   false assumption that account creds were stale. The user corrected this live. Source:
   `decisions/auto-005-scope-envelope.md` banner: "SCOPE CORRECTED — wrongly bounded the
   live build OUT."
6. [FACT] The same three infra gaps recurred across at least four runs (auto-011 through
   auto-016): hub→spoke firewall rule (SG-443), shared-VPC ELB subnet tags, and
   placeholder-overlay vs GitOps self-heal. Each run applied a live hand-fix; none
   shipped a durable code fix until after auto-016. Source: auto-012, auto-016 summaries,
   `ai/handoff.md` OI-2026-06-07-2/-3/-4.
7. [FACT] Auto-016's own summary states: "auto-016 declared progress but clean-build-tested
   NONE of it. Every 'fix' was validated by a live hand-workaround." Source: `ai/handoff.md`
   auto-017 quickstart block.
8. [FACT] The formal decision-brief protocol (2 rounds, ≥3 real adversarial reviewers) was
   not executed in auto-001 because "subagents universally reported 'no Task tool exposed
   in this sub-environment.'" Source: `run-summary-2026-05-25.md` §4.
9. [INFERENCE] PR production per run ranged from 3 (auto-003/004) to ~9 (auto-014),
   far below the protocol's 30-PR cap and stated "floor" of 20–30. The 2026-05-25 run
   produced 12 PRs (incl. envelope + summary) but was described as finishing "way too
   quickly." Source: per-run summary metadata.
10. [FACT] As of auto-016 end-state, the substrate "phase 1 reproducibly green" claim first
    made in auto-002/003 had been broken and re-fixed at least three times (auto-005/007
    provider-bootstrap deadlock; auto-009 provider-SA fix; auto-010 external-dns zone-match
    bug; auto-016 IAM regression). Source: run summaries cross-referenced.

---

## 1. Run Register

| Run ID | Date | Envelope | Envelope path | Summary file | Goal (stated) | PRs opened | Notable incidents |
|---|---|---|---|---|---|---|---|
| auto-001 (2026-05-25) | 2026-05-25 | Y | `decisions/auto-001-scope-envelope.md` | `run-summary-2026-05-25.md` | Phase 1 + Phase 2 implementation (11 specs) | 12 (incl. envelope + summary) | Decision-brief protocol skipped (no Task tool); 5 PRs had chainsaw-verify failures at run end |
| auto-002 (2026-05-26) | 2026-05-26 | Y | `decisions/auto-002-scope-envelope.md` | `run-summary-2026-05-26.md` | Crossplane v1→v2 migration execution | 5 (#101–#105); 4 merged | PR #105 blocked on rotated AWS creds; 3 chainsaw scenarios still red at run end |
| auto-003 (2026-05-28) | 2026-05-27–28 | Y | `decisions/auto-003-scope-envelope.md` | `run-summary-2026-05-28.md` | v1→v2 migration tail (close DoD) | 4 (#110–#113); 1 merged | SEG-4 PR-T2 deferred (Docker absent); chainsaw on PR-T3 still in-flight at run end |
| auto-004 (2026-05-29) | 2026-05-29 | Y | `decisions/auto-004-scope-envelope.md` | `overnight-summary.md` | Phases 2–6 on AWS; "XRDs not working" | ~3 PRs; 1 stacked (#132) | Account was freshly rotated (handoff wrong); phase 3 NOT started; chainsaw re-kick pending |
| auto-005 | 2026-06-05 | Y (SUPERSEDED) | `decisions/auto-005-scope-envelope.md` | [OPEN – no top-level summary found] | Code-only backlog (live build bounded out) | ~5–7 (estimated from envelope) | Envelope superseded mid-run; user corrected "creds are current, build live" |
| auto-006 | ~2026-06-05 | N (no envelope) | — | [OPEN – no summary found] | [OPEN] | [OPEN] | Only artifact: `decisions/auto-006-asm-external-name-fix.md` (decision doc) |
| auto-007 | 2026-06-05 | Y | `decisions/auto-007-scope-envelope.md` | `run-summary.md` | Finish phase 3; phases 4/5/6 | 5 (#144–#148) | ArgoCD unreachable from sandbox (egress MITM); no `workflow` scope on push token; live spoke NOT provisioned |
| auto-008 | ~2026-06-05–06 | N (no envelope) | — | [OPEN – no summary found] | [OPEN] | Only artifact: `decisions/auto-008-spoke-gitops-delivery.md` (design brief, 2 adversarial rounds, 5 reviewers) |
| auto-009 | 2026-06-06 | Y | `decisions/auto-009-scope-envelope.md` | `run-summary-auto-009.md` | "To phase 6 clean"; land auto-007 stack; fix provider-bootstrap deadlock | ~9 PRs (#153–#156 + stack); all merged | Provider-SA bootstrap deadlock diagnosed + fixed; phases 4/5/6 live NOT built |
| auto-010 | 2026-06-06 | Y | `decisions/auto-010-scope-envelope.md` | `run-summary-auto-010.md` | maxPods fix; validate phases 0–3; complete phases 4–5 | 1 PR (#159, single-branch) | 5 bugs found+fixed with regression tests; phase-3 cluster provisioned but live RDS NOT run |
| auto-011 | 2026-06-06–07 | Y | `decisions/auto-011-scope-envelope.md` | `run-summary-auto-011.md` | Finish phase-3 LIVE (spoke registration); phase-5 LIVE (keycloak-db) | 3 PRs (#160–#162) | Phase-3 had 4 undiscovered blockers; child-provider IRSA blocker left open; UPDATE: platform cluster went LIVE during run |
| auto-012 | 2026-06-07 | Y | `decisions/auto-012-scope-envelope.md` | `run-summary-auto-012.md` | Spoke registration + spoke app convergence + phase-5 RDS | 1 PR (#165, single-branch) | 8-blocker chain diagnosed+fixed live; `hello.platform.` HTTP 200 achieved; bootstrap PAUSED at run end (3 OI items unresolved) |
| auto-013 | 2026-06-07 | Y | `planning/test-overhaul/SCOPE-ENVELOPE-auto-013.md` | `run-summary-auto-013.md` | Test overhaul P1: scaffold (inverted-skip runner, evidence gate, scoped IAM, etc.) | 8 PRs (#170–#177) | Proof-of-mechanism (SPIKE-6 live XR provision) NOT completed; pipeline wiring NOT done; no subagents dispatched |
| auto-014 | 2026-06-08 | Y | `planning/test-overhaul/SCOPE-ENVELOPE-auto-014.md` | `run-summary-auto-014.md` | 13 behavioral checks; 4 decision briefs; mutex + reaper | 8 PRs (#191–#199) | P4/P5 live runs deferred; agent incorrectly called sandbox "read-only" (AGENTS §6.37 violation noted in summary); GitHub 504s on CI |
| auto-015 | 2026-06-08 | Y | `planning/test-overhaul/SCOPE-ENVELOPE-auto-015.md` | `run-summary-auto-015.md` | Fresh account; IAM narrowing validated; 3 of 4 dormant checks flipped; P3/P4/P5 built | 7 PRs (#201–#207) | IAM narrowing validated live (OI-1 resolved); subagent git checkout moved main worktree HEAD (incident); P4/P5 mutating NOT live-run |
| auto-016 | 2026-06-08–09 | Y | `run-envelope-auto-016.md` (repo root) | `run-summary-auto-016.md` | Fresh account re-validation; IAM regression found + fixed; RDS/EC2 narrowing | 5 PRs (#209–#213) | Regression in auto-015 IAM narrowing: broke spoke nodegroup (0 nodes). Fixed (#213). 3 recurring gaps re-hit, live-fixed again. Zero clean-build verification done. |

### Numbering gaps and artifact matrix

| Run | Scope envelope | Top-level summary | Decision doc (non-envelope) |
|---|---|---|---|
| auto-001 | `decisions/auto-001-scope-envelope.md` | `run-summary-2026-05-25.md` | — |
| auto-002 | `decisions/auto-002-scope-envelope.md` | `run-summary-2026-05-26.md` | — |
| auto-003 | `decisions/auto-003-scope-envelope.md` | `run-summary-2026-05-28.md` | — |
| auto-004 | `decisions/auto-004-scope-envelope.md` | `overnight-summary.md` | `decisions/auto-004-phase-3-plan.md` |
| auto-005 | `decisions/auto-005-scope-envelope.md` (SUPERSEDED) | [OPEN — not found] | `decisions/auto-005-session-plan.md` |
| auto-006 | [OPEN — no envelope] | [OPEN — not found] | `decisions/auto-006-asm-external-name-fix.md` |
| auto-007 | `decisions/auto-007-scope-envelope.md` | `run-summary.md` | `decisions/auto-008-spoke-gitops-delivery.md` (authored during run) |
| auto-008 | [OPEN — no envelope] | [OPEN — not found] | `decisions/auto-008-spoke-gitops-delivery.md` |
| auto-009 | `decisions/auto-009-scope-envelope.md` | `run-summary-auto-009.md` | `decisions/auto-009-phase3-live-completion-runbook.md` |
| auto-010 | `decisions/auto-010-scope-envelope.md` | `run-summary-auto-010.md` | — |
| auto-011 | `decisions/auto-011-scope-envelope.md` | `run-summary-auto-011.md` | `decisions/auto-011-child-provider-irsa.md` |
| auto-012 | `decisions/auto-012-scope-envelope.md` | `run-summary-auto-012.md` | — |
| auto-013 | `planning/test-overhaul/SCOPE-ENVELOPE-auto-013.md` | `run-summary-auto-013.md` | — |
| auto-014 | `planning/test-overhaul/SCOPE-ENVELOPE-auto-014.md` | `run-summary-auto-014.md` | `planning/test-overhaul/decisions/auto-014-001 thru 004` |
| auto-015 | `planning/test-overhaul/SCOPE-ENVELOPE-auto-015.md` | `run-summary-auto-015.md` | `planning/test-overhaul/decisions/auto-015-001` |
| auto-016 | `run-envelope-auto-016.md` | `run-summary-auto-016.md` | `planning/test-overhaul/decisions/auto-016-001` |

**Summary:** Envelopes exist for 12 of 16 runs (missing: 006, 008; envelope path migrated to `planning/test-overhaul/` from auto-013 onward). Top-level summaries exist for 13 of 16 (missing: 005, 006, 008). [FACT] Source: file system glob.

---

## 2. Envelope-vs-Outcome Drift

### auto-001 (2026-05-25)

**Planned:** "11 implementation PRs … 2-round ≥3-real-reviewer adversarial brief at every genuine decision point." [FACT] `decisions/auto-001-scope-envelope.md` §1.
**Outcome:** "Formal 2-round, ≥3-reviewer adversarial protocol from the autonomous-run skill was NOT executed. Subagents universally reported 'no Task tool exposed in this sub-environment' and self-reviewed inline instead." [FACT] `run-summary-2026-05-25.md` §4. Also: 5 of 11 implementation PRs had chainsaw-verify failures at run end.

### auto-005 (2026-06-05)

**Planned envelope:** "Will NOT dispatch heavy CI … Will NOT build the phase-3 spoke … No AWS resources." [FACT] `decisions/auto-005-scope-envelope.md` §"What I plan to NOT do".
**Outcome:** User corrected mid-run: "credentials are current, and the mandate is to build phases 0→3 and work live." The envelope was superseded by `decisions/auto-005-session-plan.md`. [FACT] `decisions/auto-005-scope-envelope.md` banner.
**Drift type:** Goal substitution. The agent bounded live work out based on a false premise (stale creds), contradicting the user's actual goal.

### auto-007 (2026-06-05)

**Planned:** "Finish phase 3 (live)… build the hub-spoke… verify `https://hello.platform.<domain>`" and "Phase 4 (observability)… Phase 5 (auth)… Phase 6 (workload cluster)." [FACT] `decisions/auto-007-scope-envelope.md` §1.
**Outcome:** "The live platform-cluster provision is BLOCKED by environmental constraints… ArgoCD unreachable (proxied egress 503s), no `workflow` scope, kubectl blocked." Phases 4/5/6 were scaffolded as GitOps manifests but NOT provisioned live. "Did not run the live spoke registration / hello verify — gated on the platform cluster existing." [FACT] `run-summary.md` §1 TL;DR, §7.
**Drift type:** Scope reduction. Live validation blocked by sandbox constraints not anticipated in the envelope.

### auto-009 (2026-06-06)

**Planned:** "Finish the live rebuild… phase-0→3 and verifying `https://hello.platform.<domain>`… Drive phases 4/5/6 live." [FACT] `decisions/auto-009-scope-envelope.md` §1.
**Outcome:** "Phases 4/5/6 LIVE implementation (hub-addons AppProject, XDatabase XRD+RDS, maxPods): NOT STARTED. Phase-2 chainsaw / phase-3 platform-cluster sync not reached this run (budget; the provider-SA diagnose→review→fix→validate loop consumed the live-track time)." [FACT] `run-summary-auto-009.md` §5.
**Drift type:** Live work consumed by unplanned debugging. The provider-bootstrap deadlock repair (OI-2026-06-06-2) displaced the stated goal.

### auto-016 (2026-06-08–09)

**Planned:** "Confirm the live gate end-to-end (STEP 0)… Flip the last 2 SKIP kinds… Live-validate Track B in MUTATING mode (P4/P5/P3)… OI-2026-06-08-2: build a HARD bounded-poll hello e2e." [FACT] `run-envelope-auto-016.md` §1.
**Outcome:** STEP 0 not completed; 2 SKIP kinds NOT flipped; Track B mutating NOT run; hello e2e authored but NOT live-validated; RDS proof incomplete ("ongoing-reconcile, not pristine-create"). [FACT] `run-summary-auto-016.md`. Additionally: "auto-016 declared progress but clean-build-tested NONE of it." [FACT] `ai/handoff.md` auto-017 quickstart.
**Drift type:** Systematic under-delivery on all stated live validation goals. Every planned "confirm" item became "deferred" or "blocked."

---

## 3. Carry-Over Debt (5 tracked items across runs)

### Item A: Phase-3 live spoke registration + hello.platform. HTTP 200

- **First deferred:** auto-007 (2026-06-05): "Did not run the live spoke registration / hello verify." Source: `run-summary.md` §7.
- **Re-deferred:** auto-009: "Phase-3 platform-cluster sync not reached this run." Source: `run-summary-auto-009.md` §5.
- **Re-deferred:** auto-010: "Phase-3 live: once ArgoCD is reachable, follow runbook." Source: `run-summary-auto-010.md` §6.
- **Claimed resolved:** auto-012: `https://hello.platform.596430611165.realhandsonlabs.net` HTTP 200 (3/3). Source: `run-summary-auto-012.md` Live verification section.
- **Regressed:** auto-016: "hello.platform.<domain> is unreachable. Needs the real fix (cluster-facts ConfigMap)." Source: `run-summary-auto-016.md`. The spoke app stack was blocked by the overlay gap. Bootstrap PAUSED.
- **Net status:** Resolved on one ephemeral account (auto-012) but re-opened on the next fresh account (auto-016). No durable fix in committed code as of auto-016. [FACT]

### Item B: SEG-4 PR-T2 render-fixture goldens

- **Deferred:** auto-003 (2026-05-28): "NOT opened SEG-4 PR-T2 (render-fixture goldens). Sandbox lacks Docker." Source: `run-summary-2026-05-28.md` §"What I deliberately did NOT do".
- **Re-deferred:** auto-004: "PR-T2 … requires `crossplane` CLI to generate expected.yaml against live v2 manifests." Source: `overnight-summary.md` morning-review #1.
- **Re-deferred:** not mentioned again by name in later summaries; subsumed under "render-fixtures unit test flakes red" in auto-015. [OPEN — resolution unclear after auto-005]

### Item C: Hub→spoke firewall rule (SG 443) and shared ELB subnet tags

- **First appeared:** auto-012 (2026-06-07): "hub→spoke EKS-API path blocked (spoke cluster SG had no inbound 443 from mgmt nodes)" — fixed live. Source: `run-summary-auto-012.md` phase-3 blocker chain #4.
- **Re-hit + re-live-fixed:** auto-016 (2026-06-08): "hub→spoke firewall rule — the spoke's API firewall didn't admit the hub's nodes on 443 … Added the rule live." Source: `run-summary-auto-016.md`.
- **Status in auto-016 summary:** "durable Composition SecurityGroupRule (mgmt SG → spoke API) owed." No durable PR opened. Source: `run-summary-auto-016.md`.
- **OI tracking:** `OI-2026-06-07-4` open as of auto-016. [FACT]

### Item D: Provider-bootstrap deadlock (recurring bring-up failure)

- **First noted:** "the recurring provider-bootstrap deadlock that blocked auto-005/auto-007" (per auto-009 summary). Source: `run-summary-auto-009.md` §1.
- **Diagnosed + fixed:** auto-009 (2026-06-06): provider-SA bootstrap fix PR #156 merged. "Phase-1 management is reproducibly GREEN." Source: `run-summary-auto-009.md` §1.
- **Recurrence of new variant:** auto-010 found 5 fresh bugs in phase-1 bring-up (EKS auth-token expiry, Kyverno CRD-kind GVR, external-dns zone-match-parent, mikefarah-yq glob). Source: `run-summary-auto-010.md` §2.
- **IAM regression introduced + found:** auto-016: auto-015's IAM narrowing broke EKS nodegroup creation. Fixed by #213. Source: `run-summary-auto-016.md`.
- **Net pattern:** Each run that claims "phase 1 reproducibly green" is followed by another run finding a new bring-up bug. [INFERENCE]

### Item E: unit-tests.yml / run.sh CI wiring gap

- **First documented:** `handoff-followups-2026-05-28.md` Task 1: "17 of 39 tests in run.sh are missing from unit-tests.yml." Recommends a catch-all step. Source: `handoff-followups-2026-05-28.md` §1.
- **Re-documented:** auto-007 bring-up added more tests to run.sh; auto-010 added 5 new test files. Each run summary notes "new unit tests wired into tests/unit/run.sh."
- **Explicit AGENTS rule added:** `AGENTS.md §6.16` ("run.sh and unit-tests.yml must stay in sync"). Source: `AGENTS.md`.
- **Status:** Rule added; whether the 17-test gap was closed is [OPEN — not confirmed in any post-auto-004 summary].

---

## 4. The Autonomous-Run Protocol

### What SKILL.md mandates

[FACT] Source: `.claude/skills/autonomous-run/SKILL.md`

| Protocol element | Mandate |
|---|---|
| Scope envelope | Required before any work; committed as first file; defines deliverables, boundaries, scale estimate, decision points, stop conditions |
| Decision briefs | Required whenever reaching user-input territory; 2 rounds, ≥3 real adversarial reviewer subagents per round; inline simulation forbidden |
| Stacked PRs | Cap: 30/run; floor (target): 20–30/run; each PR independently reviewable |
| Morning summary | Required, every run; human-facing (human-scoped-deliverables skill); four-part orientation; full PR table + merge order |
| Self-retrospective | Required at end of every run; full structured package (main report + AGENTS-MD files + ADR drafts + SKILL-SPEC drafts); not a freehand note |
| Volume floor | "Don't stop because a sub-phase closed — start the next." 30 PRs is cap, 20–30 is target. |

### SKILL.md creation and expansion timeline

| Commit | Date | Event |
|---|---|---|
| `0d3d455` | 2026-05-25 | SKILL.md created (imported from software-factory, 422 lines) |
| `c46f491` | 2026-06-07 | Expanded: mandate full self-retrospective package in end-of-run protocol; prohibit freehand retro substitution; context-budget guidance added |
| `a7ca8f8` | 2026-06-07 | Expanded: human-scoped-deliverables requirement added to morning summary; four-part orientation template added |

[FACT] Source: `git log --oneline --follow .claude/skills/autonomous-run/SKILL.md`

### Protocol overhead per run (sample: 3 runs)

**auto-001 (2026-05-25)** — 12 PRs total:

| Category | PRs | Notes |
|---|---|---|
| Protocol artifacts | 2 | PR #84 (scope envelope), PR with run summary + retro |
| Platform work | 10 | PRs #85–#94 (implementation specs) |
| Overhead % | ~17% | |

[FACT] Source: `run-summary-2026-05-25.md` §3 table.

**auto-007 (2026-06-05)** — 5 PRs total:

| Category | PRs | Notes |
|---|---|---|
| Protocol artifacts | 2 | PR #144 (trunk: scope envelope + run docs), PR with summary |
| Platform work | 3 | PRs #145 (phase-3 spoke), #146/#147/#148 counted as 1 unit (scaffolding) |
| Overhead % | ~40% | PR #144 bundles envelope + briefs + summary; overhead is definitional |

[FACT] Source: `run-summary.md` §3.

**auto-013 (2026-06-07)** — 8 PRs total:

| Category | PRs | Notes |
|---|---|---|
| Protocol artifacts | 2 | PR #170 (scope envelope), PR #177 (summary + retro + handoff) |
| Platform work | 6 | PRs #171–#176 (6 scaffold pieces) |
| Overhead % | ~25% | |

[FACT] Source: `run-summary-auto-013.md` pointers section.

Note: The decision-brief PRs (containing `decisions/auto-NNN-*.md` files) are often
bundled into the trunk/envelope PR rather than counted separately. [INFERENCE]

---

## 5. Progress-per-Run Trend

### Claimed progress vs. next-run findings

| Claim | Run claiming it | What the next run found |
|---|---|---|
| "Crossplane v1→v2 migration succeeded. §11 DoD #5 chainsaw FULL GREEN." | auto-003 (`run-summary-2026-05-28.md`) | auto-004: "The real 'not working' cause: SPEC-S9 author-time render check had never run (no goldens existed) due to a determinism bug." Phase 2 re-verified from scratch. |
| "Phase 0 + Phase 1 + Phase 2 all verified on the freshly-rotated AWS test account." | auto-003 (`run-summary-2026-05-28.md`) | auto-004: "The account was freshly rotated — the handoff said phase 0/1 were verified, but that was the prior account." Added AGENTS §8.4. |
| "Phase-1 management is reproducibly GREEN." (provider-SA fix) | auto-009 (`run-summary-auto-009.md`) | auto-010: "Five real bugs found and fixed" in phase-1 bring-up (EKS token expiry, Kyverno GVR, external-dns zone-match, mikefarah-yq glob). |
| "Phase-3 trust plane is now fully LIVE and the spoke is registered." | auto-012 (`run-summary-auto-012.md`) | auto-013/auto-016: the same hub→spoke SG 443, subnet tags, and overlay gaps re-hit on next fresh account. |
| "The identity-layer narrowing from last session was re-proven on a fresh account's create path." | auto-015 (`run-summary-auto-015.md`) | auto-016: "a genuine fail-closed regression in last session's permission narrowing… broke EKS worker-node creation, so the spoke came up with zero nodes." |
| "clean-build-tested NONE of it" (auto-016 self-assessment) | auto-016 (`ai/handoff.md`) | — (no auto-017 summary available) |

[FACT] Sources: cross-referenced run summaries as cited.

### Substrate/foundation rebuild count

[FACT] Each of the following runs performed a full phase-0+1 (and sometimes phase-2) bring-up from scratch on a fresh/rotated account:

auto-002, auto-003, auto-004, auto-007, auto-009, auto-010, auto-013, auto-015, auto-016 = **9 full rebuilds** across 16 runs.

auto-011 and auto-012 inherited a live account (no rebuild needed for 0/1).
auto-005/006/008 are [OPEN] — no summary confirms whether live applies occurred.

[INFERENCE] The ~1-per-run rebuild rate is structural: the AGENTS §8.1 policy (account rotates between sessions) mandates it, but the number of bugs caught during rebuild (5 in auto-010 alone) indicates the substrate was not stable.

---

## Evidence Index

| File | Role |
|---|---|
| `run-summary-2026-05-25.md` | auto-001 summary |
| `run-summary-2026-05-26.md` | auto-002 summary |
| `run-summary-2026-05-28.md` | auto-003 summary |
| `overnight-summary.md` | auto-004 summary |
| `run-summary.md` | auto-007 summary |
| `run-summary-auto-009.md` through `run-summary-auto-016.md` | auto-009–016 summaries |
| `decisions/auto-001-scope-envelope.md` through `decisions/auto-012-scope-envelope.md` (gaps: 006, 008) | Scope envelopes for auto-001 to auto-012 |
| `planning/test-overhaul/SCOPE-ENVELOPE-auto-013.md` through `…-auto-015.md` | Scope envelopes for auto-013–015 |
| `run-envelope-auto-016.md` | auto-016 scope envelope (root) |
| `handoff-followups-2026-05-28.md` | Post-auto-003 carry-over task audit |
| `ai/handoff.md` | Cross-session state; auto-016/auto-017 quickstart block |
| `.claude/skills/autonomous-run/SKILL.md` | Protocol definition (created 2026-05-25) |
