# agent instruction

**Batch-commit during high-fanout subagent waves.** When ten or more background subagents are concurrently writing to disk, commit their outputs in batches rather than per-completion. Sensible cadences: every ~10 completions, every stop-hook trigger, every user prompt that yields the turn. Per-completion commits create a noisy commit stream that obscures the per-batch narrative; not committing at all causes the harness stop hook to block when the parent agent tries to yield. Use a commit message like "Phase N fanout: batch K outputs" so the commit log groups by batch, not by individual file.

*Grounded in: 2026-05-25 session where the stop hook blocked mid-fanout because 28 of 49 spec files were uncommitted; resolved by committing in two batches.*

# justification

The 2026-05-25 session dispatched 49 background subagents in parallel. Notifications streamed in over ~10 minutes as each subagent completed and wrote its spec file. Two failure modes are present:

1. **Per-completion commit:** 49 commits, each one file, each with a one-line "SPEC-Sx authored" message. The commit log becomes useless — readers have to fold the 49 commits back into one logical batch to understand what happened.
2. **No commits until all 49 done:** the harness's `~/.claude/stop-hook-git-check.sh` blocks when the parent tries to yield the turn back to the user (because there are uncommitted changes). The user gets an awkward "stop hook feedback" message instead of a clean turn boundary.

The session hit failure mode 2: 28 of the 49 spec files were uncommitted when the parent agent first yielded; the stop hook blocked. Resolved by adopting batch-commit cadence — one commit at ~25 completions ("Add SPEC-TEMPLATE, IMPLEMENTATION-PLAN, and 49 spec authoring outputs (in progress)"), a second commit when the remaining late-arrivers landed ("Phase 0 fanout: more spec authoring outputs (LA4 + LC2/LC6 final content)").

Cost of the rule: a few extra commit messages, one per batch — under a minute total. Cost of not having it: stop-hook noise and an unreadable per-file commit log. This rule pairs with "Subagent briefs use absolute paths and prohibit cross-task edits" (`AGENTS-MD-6065d877c7`): the per-task no-commit rule is what makes the parent's batch-commit coherent.
