# Scope envelope — autonomous run 2026-05-25 (Phase 1 + Phase 2)

**Run start:** 2026-05-25
**Driving prompt:** combined Phase 1 + Phase 2 implementation from
`ai/brainstorming/specs/PHASE-1-2-AGENT-PROMPT.md`.
**Skill:** `autonomous-run`.
**Authorization to act:** user is structurally absent for the duration;
asked for clarifying questions up-front, then "run all the way to
completion making decisions as documented in the skill autonomous-run."

---

## 1. What I plan to do

- Open **11 implementation PRs** ready-for-review covering the 10
  specs in Phase 1 (S4, S5, S6, S10) and Phase 2 (S7, S2, S3, A4, C4,
  S9). Each branches off the latest `main` except for the 3 stacked
  children. **Per user direction: I will NOT merge any PR.** User
  merges in the morning after reviewing decision briefs.
- Use **stacked PRs only where a real code dep exists** (3 edges:
  S5→S4, S2→S7, C4→A4). Other 8 PRs branch directly off `main`.
- Run a **2-round, ≥3-real-reviewer adversarial brief** at every
  genuine decision point (spec admits >1 reasonable interpretation
  *and* the choice affects API surface or downstream consumers).
  Decision briefs land at `decisions/auto-NNN-<slug>.md` on their own
  small PR.
- Per AGENTS.md §6.4, every implementation subagent dispatches one
  test-plan adversarial reviewer **before** authoring tests.
- Auto-fix CI failures up to **3 attempts per PR**, then surface.
- End with a **self-retrospective** at `retrospective/2026-05-25-PPP.md`
  (PPP = highest PR number opened in the run) and a
  **morning-summary** at `run-summary-2026-05-25.md`.

## 2. What I plan to NOT do

- **Not merge any PR** (user-owned).
- **Not modify any `SPEC-*.md`** (frozen) or `IMPLEMENTATION-PLAN.md`
  (retro is the feedback channel).
- **Not touch any Phase 3+ scope.** Stop after the 11 PRs + retro
  PR are opened.
- **Not provision EC2-class AWS resources.** All work here is
  scripts / lints / docs / chainsaw YAML; sandbox constraints
  preserved.

## 3. Scale estimate

- **Run PRs:** 1 (this envelope) + 11 (implementation) + 1
  (retrospective) + N (decision briefs, expect 0–5) =
  **13–18 PRs**, well under the 30 cap.
- **Subagents:** 11 implementation + ~11 test-plan adversarial
  reviewers (§6.4) + ~3-9 decision-brief reviewers (2 rounds × ≥3
  each) + 0-3 CI-fix subagents. Total **~25-35**, dispatched in
  parallel waves.
- **Duration:** unbounded by user direction. Stop on scope
  completion, hard failure, or context-budget approach.

## 4. First decision points (likely)

These are predicted, not certain. Each will get a brief + 2 review
rounds if it materializes.

- **D1 — wait-for-claim primitive shape (PR-2.S7).** Whether the
  on-timeout dump emits to stderr or a fixed file path. Spec wording
  may underspecify; affects every consumer in Phase 2 onward.
  *Rewind:* revert PR-2.S7's merge; later consumers wait.
- **D2 — kubeconform audit-fix blast radius (PR-1.S6).** Whether the
  audit rollout fixes every existing manifest or marks known-broken
  ones as ignored-with-rationale. Affects pre-commit pain on day 1.
  *Rewind:* revert PR-1.S6; pre-commit hook removal restores prior
  state.
- **D3 — catch hook truncation thresholds (PR-2.A4).** Plan §5 calls
  out "noisy first-day output". Picking conservative defaults vs
  aggressive defaults. *Rewind:* PR-2.A4 revert or follow-up tuning
  PR.

## 5. What I'll surface in the morning summary

- The 11 PR URLs with suggested merge order respecting the 3 dep edges.
- Every decision brief written, with Round-1 / Round-2 reviewer
  consensus and the chosen option per brief.
- Hot-file collision risk between the 11 PRs and any concurrent
  unrelated PRs that landed on `main` during the run.
- §11 verification status per PR (which subagents reported all-green
  vs partial-pass).
- Any spec-vs-reality drift surfaced (with retro entries pointing at
  the specific drift).

## 6. Stop conditions

**Allowed to stop:**
- All 11 PRs opened, retro committed, summary committed.
- Context budget approaches ~70% — write summary + retro NOW and
  stop (vs ~90% scramble).
- Hard failure: GitHub MCP auth drops permanently after
  `github-connection-resilience` recovery attempts; sandbox dies;
  subagent harness errors out repeatedly.
- 30-PR cap hit (very unlikely given current estimate).
- User sends a chat message (interrupts the unattended mode).

**NOT allowed to stop:**
- A subagent returns ambiguous results → dispatch a clarifying
  subagent or write a decision brief.
- A sub-phase closes (Wave 1 finishes) and Wave 2 has dependencies
  outstanding → dispatch Wave 2 the moment each prereq is pushable.
- A CI failure on a PR → auto-fix loop up to 3 attempts before
  surfacing.

---

## 7. Aligned with user's pre-run answers

| Question | Decision |
|---|---|
| Merge authority | User merges; I open ready-for-review. |
| CI recovery | Up to 3 auto-fix attempts per PR. |
| Review intensity | 2 rounds + ≥3 reviewers only at genuine decisions. |
| Time bound | Run until 11 PRs + retro done. |
| Stack shape | Natural forest (8 base=main, 3 stacked). |
| Retro timing | Write at end of run. |

---

## 8. Subagent brief boilerplate (per per-task brief in the prompt)

Each implementation subagent's brief carries:
- Absolute path of target spec.
- Verbatim: "Implement this spec literally. Do not invent scope. Do
  not modify the spec — if reality diverges, note it in the PR body
  and a retro entry."
- TDD per AGENTS.md §6.2; §6 tests-required gate; §11 verification
  checklist; adversarial test-plan review per §6.4 BEFORE drafting
  tests.
- PR title: `phase-<N>-<spec-id>: <one-line summary>`.
- PR ready-for-review (not draft).
- Hard rules: no `SPEC-*.md` edits, no files outside the spec's §4
  file list, no other-spec scope.
- Output: ≤150-word summary with PR URL and open questions.

Worktree isolation is applied per Agent call (`isolation: "worktree"`)
so concurrent subagents do not corrupt the shared git index.
