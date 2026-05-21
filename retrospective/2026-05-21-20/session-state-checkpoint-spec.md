# Spec: `session-state-checkpoint`

## Intent

Claude Code's harness offers no checkpoint or rewind. Once content
enters the context window — through a tool call that over-returns,
through a prompt-injected tool result, through reading a file that
included material the user told you to skip — there is no undo. The
user's only recovery option is to abandon the session and start a new
one, losing all the conversation history that had value.

In the session that produced PR #20, this exact failure cost the user
roughly two hours of recovery: I read more than they told me to read,
contaminated my context with a rejected design, and they ultimately
had to switch sessions to keep working. Mid-retrospective, the user
surfaced the mitigation themselves: **frequently write running session
state to a file, commit it, and treat git history as user-space
checkpoint storage.** Temporary working files are removed when the
final artifact lands; the history retains them for forensic recovery.

This skill operationalizes that pattern. It is the cheapest, most
effective hedge against the failure mode the harness can't fix.

## Trigger

**Direct triggers — activate when:**

- User says "checkpoint", "save state", "save what we've agreed", "snapshot the session", or anything similar.
- User explicitly invokes `/session-state-checkpoint` or similar.

**Proactive triggers — start a checkpoint without being asked when:**

- Session is multi-turn and decisions are accumulating (more than three substantive answers from the user).
- Work has pivoted (rejected design → new design; user changed direction mid-task).
- A subagent's output has substantially expanded what's been agreed.
- You're about to call a tool that might over-return (issue / PR body, web fetch of a long page, MCP search).
- The user says anything indicating context fragility ("I don't trust your context", "this could get polluted", "let's not lose this").

**Negative triggers — skip when:**

- Single-turn task (one question, one answer, done).
- Routine task with no accumulating state.
- User has explicitly said they don't want checkpoint files in the tree.

## Inputs

- Current session state: decisions made, open questions, constraints
  added, scope changes, what's been ruled out.
- A target path (default: `.session/<short-task-name>.md`; or
  `ai/working/<task>.md` if the project prefers `.session/` to stay
  ignored).
- A short task name for the file (kebab-case, descriptive).

## Outputs

- A markdown file at the target path, committed to the current branch.
- A separate commit per checkpoint update (so each is a real,
  rebaseable checkpoint).
- A removal commit at the end of the task when the final artifact lands.

## Workflow

1. **Choose a path on first invocation.** Default to
   `.session/<task-name>.md`. If the project's `.gitignore` ignores
   `.session/`, switch to `ai/working/<task-name>.md` or similar
   tracked location. Confirm with the user if uncertain.

2. **Write the initial checkpoint with these sections:**

   ```markdown
   # Session checkpoint — <task name>

   ## Goal
   <one paragraph>

   ## Decisions made
   - <bullet>

   ## Open questions
   - <bullet>

   ## What's been ruled out (and why)
   - <bullet>

   ## Last user turn
   <one-sentence summary of the most recent user message>

   ## Next step
   <one-sentence statement of what's next>
   ```

3. **Commit immediately** with subject `checkpoint: <task-name> — <short
   delta>`. Examples: `checkpoint: issue-18-bridge — initial state`,
   `checkpoint: refactor-foo — pivot to library X`.

4. **Update after every significant turn.** Significant = a decision
   was made, a constraint was added, a scope changed, a subagent
   returned something substantive, a tool over-returned in a way that
   matters. Mechanical turns (clarification, formatting) don't need a
   checkpoint update.

5. **Commit each update.** One logical change per commit, per
   `CLAUDE.md`. Subject pattern: `checkpoint: <task-name> — <delta>`.

6. **At final-artifact landing, remove the checkpoint file in a
   separate commit.** Subject: `checkpoint: <task-name> — remove (work
   complete in <ref>)`. Git history retains the file content; the
   working tree is clean.

7. **If context pollution is suspected**, write a final "POLLUTED
   AT <turn-N>" entry to the checkpoint file (briefly describing what
   was polluted) and commit. That commit is the explicit handoff to a
   fresh session.

## Concrete examples

### Example 1 — the session that produced PR #20

What actually happened: at no point did I write a checkpoint file.
The user had to carry all session state in their own head and trust
me to remember it. When Phase 1 polluted my context, recovery meant
the user explaining the recovery options to me in chat.

What this skill would have produced:

```
.session/issue-18-bridge.md  (after turn 1)
.session/issue-18-bridge.md  (updated after turn 3, when modified design landed)
.session/issue-18-bridge.md  (updated after turn 5, with the 10 subagent concerns)
.session/issue-18-bridge.md  (updated after turn 7, with the 7 instruction-critique findings)
.session/issue-18-bridge.md  (POLLUTED AT TURN 1 — entry added when discovered)
```

When pollution was discovered, the user could have opened a fresh
session, said "read `.session/issue-18-bridge.md` and continue", and
been back to productive work in one turn. Instead they paid for two
hours of recovery and lost the rich context.

### Example 2 — a multi-PR refactor

```markdown
# Session checkpoint — refactor-payment-module

## Goal
Extract the payment-handling code from `src/checkout.ts` into a new
`src/payment/` module and update all call sites.

## Decisions made
- Module structure: `src/payment/{processor.ts, validator.ts, types.ts}`
- Keep existing public API surface; only internal organization changes
- One PR per call-site batch (max 5 call sites per PR)

## Open questions
- Whether to split `validator.ts` further

## What's been ruled out (and why)
- Renaming the module to `src/billing/` — user prefers `payment`
- Breaking the public API — out of scope this iteration

## Last user turn
"Let's also extract the error types into `types.ts`."

## Next step
Open PR #43 with the error-type extraction; close out PR #42 first.
```

Committed; survives any context event.

## Anti-patterns

- **Writing the checkpoint to `~/.claude/` or `/tmp/`.** Both are
  sandbox-ephemeral. The whole point is in-tree, git-tracked
  persistence.
- **Skipping the commit.** A file in the working tree but not in git
  history dies with the sandbox. Always commit.
- **Bundling checkpoint updates with feature commits.** Mixes
  unrelated changes and violates the one-logical-change-per-commit
  rule. Checkpoint commits stand alone.
- **Treating the checkpoint as the final artifact.** It's working
  state. Final deliverables go to `ai/specs/`, `docs/`, code, etc.
- **Forgetting to remove at the end.** Leaving `.session/` files in
  the tree after the work lands clutters the repo. Remove in a final
  commit; git log preserves the trail.
- **Writing prose instead of decisions.** The file is dense and
  scannable, not narrative. "We agreed to use X because Y" not "After
  some discussion we eventually came to the conclusion that…"

## Acceptance criteria

1. Checkpoint file path is inside the working tree (not under
   `~/.claude/`, not under `/tmp/`).
2. File is committed to git on the current branch.
3. Each significant turn produces a checkpoint update committed
   separately.
4. The file's content is dense and scannable — a fresh agent reading
   only the file can resume the task without further explanation.
5. At final-artifact landing, the file is removed in a separate commit.

## Files this skill creates / modifies

- `.session/<task-name>.md` (or `ai/working/<task-name>.md` depending
  on project gitignore) — created on first invocation, updated per
  turn, removed at end.
- The repo's git history — gains one checkpoint commit per significant
  turn, then a removal commit at the end.
