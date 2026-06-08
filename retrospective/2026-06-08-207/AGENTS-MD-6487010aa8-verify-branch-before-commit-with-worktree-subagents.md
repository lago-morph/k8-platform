# agent instruction

**Verify the current branch before every commit when background worktree subagents run.** "When any background subagent is running in an isolated worktree, ALWAYS run `git branch --show-current` immediately before each `git add`/`git commit` in your main worktree — a subagent's `git checkout -B <branch>` can move the MAIN worktree's HEAD, silently landing your commit on the wrong branch."

*Grounded in: auto-015, where a P5 worktree subagent's checkout moved the main HEAD and the OI-1 impl commit landed on the wrong branch, requiring a cherry-pick recovery.*

# justification

In auto-015 two authoring subagents were dispatched with `isolation: worktree`. One of them ran `git checkout -B claude/auto-015-p5-negatives origin/...` which — despite the worktree isolation — moved the *main* worktree's HEAD to that new branch. The lead agent then authored the entire OI-1 implementation (a live-policy terraform change + three test scripts) believing it was on the OI-1 branch, committed, and pushed the OI-1 branch — which received only the earlier brief commits. The mistake surfaced only when a CI run reported "No changes" on a terraform apply that should have shown a policy diff, triggering a multi-step forensic recovery (inspect worktrees, locate the misplaced commit, cherry-pick it onto the correct branch, force-push the mis-based subagent branch). The cost was ~20 minutes of investigation plus the risk of shipping an empty PR. The marginal cost of the rule is a single `git branch --show-current` before each commit — one cheap command that turns a silent, expensive class of error into an immediate catch.
