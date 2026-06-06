# agent instruction

When delegating substantial file-producing work to a background subagent in a
session governed by a stop-hook that blocks turn-end on a dirty working tree, be
aware the two interact badly: the subagent continuously creates uncommitted
files, so every turn-end triggers the hook and forces a commit, and committing
mid-write can capture an inconsistent file set that reds CI (e.g. a catch-block
edit committed before its scenario-copy propagation finishes). Prefer one of: (a)
run the subagent in the **foreground** when its output must be committed as a
unit; (b) give it an **isolated git worktree** (`isolation: "worktree"`) so its
in-flight files don't dirty the main tree; or (c) if running it in the
background, commit explicit **WIP checkpoints** with a `wip(...)` message and do
NOT treat a WIP push's transient CI red as a real failure — reconcile and
re-validate when the subagent completes, then make one clean commit. Never
declare a phase done off a WIP checkpoint; gate "done" on a full local
`run.sh` + the subagent's completion report.

# justification

auto-010 (PR #159): a phase-5 finalization subagent ran ~18 min in the
background while the stop-hook (`stop-hook-git-check.sh`) fired on every
turn-end, forcing a series of WIP checkpoint commits. One checkpoint captured
the chainsaw catch-block mid-propagation and reded the unit-tests check
transiently; it self-resolved once the subagent finished and a full local
`run.sh` confirmed green. The thrash cost several turns on bookkeeping commits
and produced noisy CI reds. Recognizing the interaction up front (and choosing
foreground / worktree-isolation for commit-as-a-unit work) avoids both the churn
and the misleading transient reds.
