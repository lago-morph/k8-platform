# agent instruction

**Commit each subagent's on-disk artifact immediately on the subagent's completion notification.** "Background subagents that write to disk produce uncommitted files in the orchestrator's worktree. Do not batch-commit at end-of-pipeline; each completion notification should be followed by `git add <files> && git commit && git push` for that subagent's output within the same turn."

*Grounded in: session 2026-05-26 throughout — stop-hook `git-check` warnings fired approximately 15 times across the session because subagent artifacts accumulated uncommitted between completions.*

# justification

Stop-hook warnings are user-facing friction. Each one wastes a turn of the user's attention (they see the warning, they wonder what's uncommitted, they may interrupt to ask). The session that codified this rule received warnings repeatedly — every time a sonnet impact tracer or an opus segment planner or an adversarial reviewer or an R2 author revision completed without an immediate commit, the next turn fired the warning.

Beyond user-facing friction, the operational risk is real: an unexpected session termination (context exhaustion, harness crash, network drop, hook-induced abort) loses every subagent's work since the last commit. In this session's 24-subagent pipeline, batching commits at end-of-pipeline would mean a single crash discards hours of opus output. Per-completion commit reduces the loss surface to one subagent's work.

The marginal cost of the rule is one extra tool call per subagent (a `git add && git commit` Bash invocation). The asymmetric cost not following the rule is: 15+ stop-hook warnings, intermittent user interruption, and a non-zero chance of losing the pipeline's entire output on the next crash.

The pattern is mechanical: every time a subagent completion notification arrives, the next tool calls should be (a) read the subagent's output file path (already known from the notification), (b) `git add` that path, (c) `git commit` with a one-line message naming the subagent, (d) `git push`. Approximately three tool calls per subagent completion. The cost vanishes against the cost of the subagent's actual work, which dwarfs the commit overhead.
