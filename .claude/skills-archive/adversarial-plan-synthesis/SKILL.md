---
name: adversarial-plan-synthesis
description: For a high-stakes, contested plan (a test strategy, a security architecture, a migration design) where a single author's blind spots are expensive, produce the plan by competition + adversarial pressure + synthesis — author several independent plans, attack each with parallel adversarial panels, synthesize the winner, then re-attack the synthesis across further rounds. Use when the user asks to "write N plans and adversarially review them", "use multiple personas to design and critique", "synthesize competing plans", or specifies rounds of review; proactively for a load-bearing architectural decision where being wrong is costly. Every subagent writes a full artifact to a file and returns only a short summary so the lead's context stays bounded. Not for small/reversible decisions or time-critical fixes.
---

# Skill: adversarial-plan-synthesis

- **ID**: SKILL-SPEC-3bc949d238
- **Source retrospective**: `retrospective/2026-06-07-167.md`

For a high-stakes, contested plan where a single author's blind spots are
expensive, produce the plan by **competition + adversarial pressure +
synthesis**: author several *independent* plans, attack each with parallel
adversarial panels, synthesize the winner, then re-attack the synthesis across
further rounds.

The skill exists because (a) one author + inline-simulated critics exert no real
adversarial pressure, and (b) the process must not blow the lead's context — so
every subagent writes a full artifact to a file and returns only a short
summary.

---

## Trigger

- **Direct:** the user asks to "write N plans and adversarially review them",
  "use multiple personas to design and critique", "synthesize competing plans",
  or specifies rounds of review.
- **Proactive:** a load-bearing architectural decision where being wrong is
  costly and the lead suspects its own framing; or a plan that several
  independent experts should pressure before adoption.
- **Negative (do NOT use):** small/reversible decisions; anything a single
  decision-brief with one review wave already covers; time-critical fixes.

---

## Inputs

- The goal/problem statement + hard requirements (verbatim from the user where
  given).
- The repo (subagents must be able to read it for grounding).
- Persona definitions: author personas and adversary-panel personas (distinct
  angles).
- The number of plans, panel size, and number of review rounds (often
  user-specified).

---

## Outputs

- A directory tree of artifacts: `plans/` (N source plans), `reviews-roundK/`
  (one file per reviewer per round), `synthesis/`, optional
  `CONSTRAINT-CORRECTION*.md`, and the `FINAL-PLAN.md`. Each is committed for
  provenance.
- A final synthesized plan that resolves the convergent findings, with a
  "deliberately rejected" and a "changes per round" section.

---

## Workflow

1. **Author plans independently and in parallel.** The lead writes one; spawn a
   subagent per additional persona. None sees the others (independence). Each
   writes to `plans/<id>.md`, returns ≤150 words.
2. **Round-1 panel.** For each plan, dispatch one subagent per adversary persona
   (personas × plans subagents) in parallel. Each reads its plan, attacks from
   its angle, **verifies load-bearing claims against the tree** (mandatory),
   ranks findings Critical/Major/Minor, names what to preserve, writes to
   `reviews-round1/`, returns ≤150 words.
3. **Synthesize.** Delegate synthesis to a subagent that reads all plans + all
   reviews from disk and writes `synthesis/SYNTHESIZED-PLAN.md` (resolve each
   convergent critical explicitly; pick-and-justify on conflicts; "rejected, and
   why"). Hand it the convergent findings so it can't miss them.
4. **Round-2 panel** on the synthesis (the prior author personas may join as
   adversaries). Same file-write/short-return discipline.
5. **Apply corrections / finalize.** Fold review findings + any owner
   corrections into the synthesis. If a correction lands mid-flight, record it as
   a `CONSTRAINT-CORRECTION.md` and apply it in a focused pass rather than
   corrupting an in-flight subagent.
6. **Further rounds as specified** (round-3, …), each re-grounding against the
   tree.
7. **Commit every artifact; open a PR; merge.** The trail is the provenance.

---

## Concrete examples

**Example 1 (this session).** Test-overhaul plan: lead Plan A + subagent Plans B
(k8s-testing-expert) and C (QA-live-systems-guru); round-1 = {SRE, security, DX}
× {A,B,C} = 9; synthesis; round-2 = those 3 + B-author + C-author = 5; two owner
corrections (workflows-editable; build≠CI) as `CONSTRAINT-CORRECTION{,-2}.md`;
round-3 = same 5; finalize. Tree-grounded reviewers caught `source: IRSA`, v1/v2
claim-verify, Pipeline parsing, spoke-public — all plan errors.

**Example 2 (generalized).** A secrets-management redesign: 3 plans
(platform-eng, appsec, SRE personas); 2 review rounds with a regulator + a
cell-defender + a naive-newcomer panel; synthesis picks one mechanism and
documents the rejected ones; final PR carries the full trail for the security
review record.

---

## Anti-patterns

- Inline-simulating reviewers instead of real subagents (no real pressure;
  AGENTS real-subagent rule).
- Letting authors see each other's plans (kills independence).
- Pulling all plans + reviews into the lead context (blows the budget) — always
  file-write + short-return.
- Reviewers that only reason about the prose (must verify claims against the
  tree — AGENTS.md §6.31).
- Encoding an unverified premise into the briefs (a false premise propagates
  across every agent and round — AGENTS.md §6.29).
- Building on an invented distinction with no repo referent (AGENTS.md §6.30).
- Editing an in-flight subagent's target mid-run to apply a late correction —
  let it finish, then a focused pass.

---

## Acceptance criteria

1. ≥2 independent source plans authored without sight of each other.
2. Every plan reviewed by ≥3 distinct adversary personas per round, real
   subagents.
3. Every review/synthesis brief requires tree-grounding of load-bearing claims.
4. Lead context stays bounded (all artifacts on disk; returns are summaries).
5. The final plan resolves each convergent critical explicitly and records
   rejected alternatives + per-round changes.
6. Full artifact trail committed and merged.

---

## Files this skill creates / modifies

- `<plandir>/plans/*.md`, `<plandir>/reviews-round*/*.md`,
  `<plandir>/synthesis/*.md`, `<plandir>/CONSTRAINT-CORRECTION*.md`,
  `<plandir>/FINAL-PLAN.md` — the plan + its full provenance trail. (No product
  code; planning only.)

---

## Related

- AGENTS.md §6.4 (adversarial subagent review of test plans), §6.29–§6.31
  (premise/framing/claim verification under fan-out).
- `parallel-subagent-fanout` skill (the dispatch mechanics for parallel rounds).
- `subagent-prompting` skill (the per-subagent brief template).
- ADR-1946fbb159 / `docs/decisions/0006-*` — the test-architecture decision this
  process produced.
