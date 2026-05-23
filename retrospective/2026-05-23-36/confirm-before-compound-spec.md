# Spec: `confirm-before-compound`

## Intent

The 2026-05-23 session received multiple user prompts that bundled
4–6 distinct asks across the lifecycle of one branch (e.g. "do X,
also Y, also Z, then stop and wait, after merge do W"). On two
occasions the lead agent's default to "interpret and act" produced
near-misses: a misread "tear down phase X" almost extended to the
underlying cluster, and the AGENTS.md changes the user wanted
landed in the *next* PR rather than the in-flight one because the
agent inferred merge order from action rather than asking.

The pattern: compound prompts have non-trivial ambiguity surface
area, and the agent's prior default (act first, ask only when stuck)
amplifies misreads into work the user didn't want.

This skill flips the default. For any compound or complex prompt —
defined below — the agent's first action is to repeat back its
understanding in a structured form, then wait for confirmation. The
default is only skipped when the prompt itself contains an explicit
opt-out ("do this without confirming", "no need to repeat back",
"go ahead and run", or equivalent).

## Trigger

**Direct triggers — invoke immediately:**

- Any user message that contains ≥ 3 distinct verbs of action
  (e.g. "add X, then push Y, then run Z").
- Any user message that bundles a feature request with a
  meta-instruction (e.g. "do X, and from now on always Y").
- Any user message that crosses ≥ 2 PR scopes (e.g. "finish the
  current PR with X, then in a stacked PR do Y").
- Any user message of > 200 words.

**Negative triggers — do not invoke:**

- Prompts containing an explicit opt-out phrase ("just do it",
  "skip the recap", "don't confirm", "do this without confirming",
  "you don't need to repeat back").
- Single-action prompts even if long (e.g. a multi-paragraph bug
  report that asks for one fix).
- Continuations of a confirmed plan ("yes proceed", "go ahead",
  "do step 2 now").

## Inputs

The current user message and the immediate conversation context
(recent messages, current branch state, any in-flight PRs).

## Outputs

A structured repeat-back message containing:

1. **Numbered or labelled list** of each distinct action the agent
   understood from the prompt, in the order the agent will perform
   them.
2. **Explicit stopping points** — where the agent will pause for
   confirmation or for an external event (CI run, PR merge, etc.).
3. **Flagged ambiguities** — sub-bullets under each step where the
   prompt was unclear, with the agent's intended interpretation. The
   user can correct each independently.
4. **Implicit assumptions** — anything the agent inferred from
   context that was not in the prompt (default values, tool choices,
   target branches).
5. **Final line**: "OK to proceed once you give the green light?"
   or equivalent.

## Workflow

1. **Read the user message** carefully. Resist the urge to start
   tool calls.
2. **Apply the trigger heuristic.** Count verbs of action; check for
   meta-instructions; check for opt-out phrases.
3. **If triggered**, draft the structured repeat-back per the output
   format. Use real branch names, file paths, and PR numbers from
   context.
4. **If not triggered**, proceed as normal.
5. **Wait for the user's chat response.** Approval comes from chat,
   explicitly, with words. Their reply may:
   - Confirm: proceed exactly as drafted.
   - Correct one or more steps: incorporate corrections; re-confirm
     only if the corrections were substantial.
   - Add new asks: treat the combined set as a new compound prompt
     and re-confirm.
   - Use an explicit opt-out ("go", "just do it"): proceed without
     re-confirming further sub-questions.
6. **System actions are not approval.** If the user takes a system
   action (merges a PR, leaves a review comment, dispatches a
   workflow, edits a file the agent is mid-work on) without replying
   in chat, **do not interpret it as approval**. The user is often
   reviewing and approving pull requests in parallel with agents
   doing work, and may take those actions without even realizing
   the agent has asked for approval for something. Continue waiting.
7. **If the wait is unproductive**, the agent may:
   - Continue any orthogonal work unaffected by the pending question.
   - Send a follow-up chat reminder naming the specific question.
   - Do not proceed on the pending question itself until the user
     replies in chat.

## Concrete examples

### Example 1 — compound prompt triggers confirmation

User message (paraphrased from 2026-05-23):

> Make sure all tests run every time the env is up. Also write
> maximal tests of all types for each phase. Whenever you find an
> issue, before fixing it write a test that would have caught it.
> Bake all this into AGENTS.md. Then finalize PR #34 and wait for
> merge before doing anything else. After merge do a phase-1 run.
> DO NOT tear down phase 1. Then start phase 2 with a stacked PR.

Agent response (structured):

```
Repeating back before I touch anything.

### Phase A — finish PR #34
1. Add AGENTS.md §6.2 (TDD on bug fix) and §6.3 (full test bundle
   on env up).
2. Commit on the existing branch claude/busy-tesla-pe3Ey.
3. Flip PR #34 from draft → ready.
4. Subscribe to PR #34 activity and stop.

### Phase B — after merge notification
5. Off a new branch from main, dispatch base + management
   apply-and-verify, then full test bundle per §6.3.
6. Any issues → TDD discipline (§6.2). Push fixes to the same
   branch and open follow-up PR. Phase 1 stays deployed.

### Phase C — phase 2 (stacked, don't wait)
7. Branch off phase-B branch → phase 2 implementation + tests →
   stacked PR with base = phase-B branch.
8. Branch off that → phase 2 test run + bug fixes → stacked PR with
   base = phase-2-impl branch.

### Two ambiguities I want to flag
- AGENTS.md vs CLAUDE.md: my default is to create AGENTS.md as
  canonical, shrink CLAUDE.md to a pointer. Tell me if you'd
  rather just bolt onto CLAUDE.md.
- "Tear down phase 2": my interpretation is delete every Claim →
  wait for cloud cleanup → delete XRDs/Compositions, leave the
  phase-1 management cluster alone. Confirm.

OK to proceed once you give the green light on those two?
```

### Example 2 — opt-out skips confirmation

User message: "Just fix the failing test, no need to recap."

Agent response: proceeds directly to investigating + fixing the test
without a repeat-back. The opt-out phrase ("no need to recap")
matches the negative trigger.

### Example 3 — single ambiguous fact, not a compound prompt

User message: "Run terraform plan."

This is one action. Trigger heuristic says no. Agent proceeds.
But if the action would touch multiple modules or branches and the
correct target isn't clear from context, the agent asks a focused
clarifying question — that's a different discipline, not this skill.

## Anti-patterns

- **Do not** confirm trivial single-step prompts. The skill's value
  comes from filtering — applying it to every prompt is noise that
  trains the user to ignore the confirmations.
- **Do not** use confirmation as a delay tactic when uncertain about
  the *content* of the work. If you don't know how to do X, ask "how
  should I approach X?" — that's a different kind of question and
  doesn't belong inside this skill's output format.
- **Do not** treat system actions (PR merges, review comments,
  workflow dispatches, file edits) as approval of a pending
  repeat-back. The user works in parallel; their environment
  actions are orthogonal to the question they were asked. Wait for
  chat.

## Acceptance criteria

1. For prompts matching the trigger heuristic, the agent's *first*
   response is a structured repeat-back. No tool calls before the
   repeat-back is sent.
2. The repeat-back has all four required pieces: numbered actions,
   stopping points, flagged ambiguities, implicit assumptions.
3. For prompts containing an opt-out phrase, the agent skips the
   repeat-back and proceeds directly.
4. When the user takes system actions but does not reply in chat,
   the agent does NOT proceed on the pending question. It either
   waits, does orthogonal work, or sends a chat-only follow-up
   naming the open question.

## Files this skill creates / modifies

- No persistent file. The skill modifies *behaviour*; its presence
  is recorded in `AGENTS.md` as a rule, not as a script.
