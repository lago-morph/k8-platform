# agent instruction

**Base a stacked PR on the branch carrying the files it edits.** "When a stacked PR
edits a file, set its base to the branch that already holds the most recent version
of that file — not `main` and not an older sibling — or switching to the new branch
restores the older file versions and risks committing a silent regression."

*Grounded in: 2026-06-07 — a feasibility branch was first based on the run-summary
branch instead of the human-readable branch, so checking it out showed the
human-readable edits as reverted.*

# justification

In this session the sandbox-kubectl feasibility branch was first created off the
run-summary branch, but the human-readable edits to `AGENTS.md` and the autonomous-run
skill lived on the next branch up. Checking out the new branch restored the older
versions of those files, and the harness flagged them as "reverted" — a confusing
near-miss that a careless `git add -A && commit` would have turned into a real
regression pushed onto the stack. The fix (re-base onto the branch with the newest
copies) cost two git commands; the marginal cost of the rule is a single moment's
thought about which branch already has the newest copy of what is about to be edited.
The asymmetry — seconds of forethought versus a silently-reverted file shipped in a
PR — is steep, and the failure is hard to spot because the working tree looks clean.
