# agent instruction

**Check sequential doc numbers against the tree and open PRs before assigning one.** Before assigning a sequential identifier that humans curate (an ADR number `docs/decisions/NNNN-*`, a migration number, a fixture index), list the existing ones (`ls`) AND check open/unmerged PRs for reserved numbers — sequential numbers collide across concurrent branches. Prefer content-hash IDs (as `retrospective/` already uses) for anything assigned off a branch. If you must use a sequential number, pick the next free one only after both checks.

*Grounded in: an ADR was authored as 0006 (taken on the branch's base) and then 0007 (taken in an unmerged PR) before the real next free number was found.*

# justification

A subagent assigned the sandbox-kubectl ADR number `0006`, which already existed in the working tree; the next guess `0007` was also taken (in an unmerged PR). Two wrong numbers, an owner correction, and a rename pass resulted — pure tax on a doc that had nothing to do with numbering. The marginal cost of the rule is one `ls docs/decisions/` plus a glance at open PRs (or just using the hash IDs the retro tooling already mints); the cost of skipping it is a collision that surfaces only when someone else greps for the number, then a rename and reference-fix sweep across many files.
