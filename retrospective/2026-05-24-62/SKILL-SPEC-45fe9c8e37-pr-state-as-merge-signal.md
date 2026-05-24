# Spec: `pr-state-as-merge-signal`

- **ID**: SKILL-SPEC-45fe9c8e37
- **Source retrospective**: ../2026-05-24-62.md

## Intent

A pull request's draft/ready state IS the agent's signal to the user about whether to merge. Treat it as load-bearing UI: a draft PR means "do not merge yet", a ready-for-review PR means "merge when you have time". Authoring everything as draft regardless of state confuses the user about which to merge; opening as ready while CI is still pending leaves red badges visible until the next push.

Grounded in: this session opened ten PRs (#52 through #62 modulo #61), almost all as draft regardless of whether CI was green and I wanted them merged. The user explicitly said: *"Going forward, please leave PRs you are still working on in draft, and ones you want me to merge as ready. Then I won't be as confused."* The very next PR (#61) was opened as ready when CI was actually green — and merged smoothly.

## Trigger

**Direct user phrases:**
- "Open the PR"
- "Mark this ready"
- "Convert to draft"
- "Is this ready?"

**Proactive triggers (skill activates automatically):**
- About to call `create_pull_request` with `draft: true` — verify state matches signal
- About to call `create_pull_request` with `draft: false` — verify CI is actually green AND the agent wants the user to merge
- Just received a CI green signal on a draft PR — should the PR be promoted to ready?
- Reporting status to the user — does the PR table reflect actual state?

**Negative triggers:**
- The PR has unresolved review comments → stays draft regardless of CI
- The PR depends on another PR not yet merged → stays draft
- The PR is "save my work" only with no intent to merge → stays draft

## Inputs

- The branch's CI state (all required checks: green / yellow / red / unknown)
- The author's intent (want-user-to-merge-now vs still-iterating vs save-only)
- Any blockers (review comments, dependent PRs, hold instructions)

## Outputs

- `draft: true` ↔ CI red or yellow OR agent still iterating OR explicit hold
- `draft: false` (ready for review) ↔ CI green AND agent wants merge
- A status line that names the state and the reason

## Workflow

1. **Before calling `create_pull_request`:** determine the four-cell state below.

   | Want user to merge? | CI green? | Draft? |
   |---|---|---|
   | No, still iterating | any | draft |
   | No, hold per user instruction | any | draft |
   | Yes, eventually | red/yellow | draft (re-evaluate after CI) |
   | Yes, now | green | **ready (`draft: false`)** |

2. **If draft:**, the PR body must state WHY (e.g., "draft — chainsaw not yet dispatched / fix in progress / hold until phase-2 verified").

3. **If ready for review:** the PR body must reference the green CI evidence (link to the workflow run) — and the agent must verify the CI is genuinely green per the `verify-evidence-not-exit-codes` skill (not just `conclusion: success` on a wrapper).

4. **After CI completes on a draft PR:** re-evaluate. If green AND intent is "yes, merge", promote via `update_pull_request method=update draft: false` — and tell the user "promoted to ready for review."

5. **In status summaries to the user**, name the draft/ready state of every open PR. Don't bury it.

## Concrete examples

### Example 1 — the actual session pattern (anti-example fixed)

PRs #52, #53, #54, #55, #56, #57, #58, #59, #60 were ALL opened as draft regardless of whether they were ready. After the user's correction, PR #61 was opened ready:

> `mcp__github__create_pull_request` with `draft: false` AND the PR body said *"Ready for review."*

The user merged #61 the next message. No confusion.

PR #62 was also opened ready for the same reason. PR #58 stayed draft per the explicit hold instruction ("hold until phase-2 verified end-to-end"). That state communicated the merge order clearly.

### Example 2 — promote draft→ready after CI green

**Setup:** PR opened as draft because chainsaw was just dispatched. CI completes 7 minutes later, status reads green.

**Workflow:**

1. Receive webhook event `chainsaw run completed conclusion: success`.
2. Run `verify-evidence-not-exit-codes` on the chainsaw log: read the per-scenario PASS lines. Confirm.
3. Call `update_pull_request method=update pullNumber=N draft: false`.
4. Report to user: "Chainsaw green on commit <SHA>: PASS lines for all scenarios. Promoted PR #N to ready for review."

## Anti-patterns

- **Open PR as draft 'just in case'** — defeats the signal. If you want it merged, mark it ready and explain why it's ready.
- **Open PR as ready while CI is still pending** — leaves a red verify-check on the PR until next push. Confusing.
- **Forget to promote draft→ready after CI greens** — leaves the user wondering why a green PR is still in their "drafts" pile.
- **Multiple status updates that don't restate PR state** — the user has to grep the conversation history. Re-state in every status table.
- **Promote to ready without verifying evidence** — see `verify-evidence-not-exit-codes`. The CI badge alone is not enough.

## Acceptance criteria

1. Every PR opened by the agent has its `draft` flag set per the four-cell table above.
2. Every status summary listing open PRs explicitly names each PR's state as `draft` or `ready`.
3. Every promotion draft→ready is announced to the user with the evidence that justified it.
4. Every PR still in draft at session end has its hold-reason in the PR body (so the next agent knows).
5. Zero "I opened PR #N" messages without naming its draft/ready state.

## Files this skill creates / modifies

- No file modifications. This is a behavioural skill governing `mcp__github__create_pull_request` and `mcp__github__update_pull_request` invocations.
