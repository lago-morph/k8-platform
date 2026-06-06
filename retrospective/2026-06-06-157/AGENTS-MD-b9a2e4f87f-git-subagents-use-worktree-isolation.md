# agent instruction

**Dispatch git-operating subagents with `isolation: worktree`.** When dispatching a subagent that performs any git operation (checkout, merge, commit, push, rebase), pass `isolation: worktree`. A non-isolated subagent shares the lead agent's working tree; if it `git checkout`s a different branch mid-run, the lead's stop-hook will flag the subagent's in-flight merge as "uncommitted changes" and concurrent git state collides.

*Grounded in: auto-009 — the first stack-resolution subagent ran on the shared clone and collided; every later resolution subagent used worktree isolation and stayed clean.*

# justification

In auto-009 the first stack-resolution subagent ran on the shared clone and `git checkout`ed a different branch mid-run. The lead agent's stop-hook then flagged the resulting working-tree state as "uncommitted changes" — when it was actually the subagent's in-flight merge — producing a false alarm that had to be untangled by hand before work could continue. Every subsequent resolution subagent was dispatched with `isolation: worktree` and the collision never recurred. The failure mode is structural: any two agents sharing one working tree will fight over `HEAD`, the index, and dirty files, and the symptoms (phantom uncommitted changes, branch-switch surprises) are confusing precisely because they look like the lead agent's own mistake. The marginal cost of the rule is a single field on the dispatch call; the cost of omitting it is a corrupted-looking working tree mid-merge and the time to diagnose that the "dirty" state belongs to a different agent entirely.
