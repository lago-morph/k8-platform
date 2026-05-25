# agent instruction

**Push-with-merge-intent must end in an open PR.** If the goal of pushing a branch is to merge it (i.e., this is not a draft / WIP push), the push step is followed in the same turn by `create_pull_request` (or `gh pr create`). Do not report "branch is pushed" as the end state unless "pushed without PR" was the explicit intent. The harness's git-status check covers uncommitted-tree drift but does not cover unopened PRs.

*Grounded in: 2026-05-25 session where the gantt-fix branch was pushed but no PR was opened; the user had to prompt "Or, uh, you didn't create a PR. Do that."*

# justification

The 2026-05-25 session pushed the `claude/kind-feynman-S6hmw-fix-gantt` branch with two commits (gantt fix + Phase 1+2 prompt), reported "branch is pushed" to the user, and ended the turn. No PR was opened. The user had to come back with "Or, uh, you didn't create a PR. Do that."

This is a quiet but reliable failure mode: the agent thinks "the work is on the remote, my job is done" because the local git operations succeeded. But on a fork-and-PR workflow, the remote branch alone is not a deliverable — the user can't review or merge it without a PR. The agent's session-ending status was indistinguishable from "everything succeeded" when in fact a required step was missing.

Cost of the rule: one extra tool call (`create_pull_request`) per push-with-merge-intent — usually under 5 seconds. Cost of not having the rule: a missed PR is missed wall-clock; the user notices when they next check GitHub, then has to interrupt their flow to prompt the agent to finish. The harness's stop-hook git-status check catches uncommitted files but does NOT detect "pushed branch without PR" — this is a known gap.
