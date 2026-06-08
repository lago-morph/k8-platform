# agent instruction

**Verify PR and merge state from the remote, never from stale local refs.** "Before asserting that a PR is merged/open or that a branch is on `main`, run `git fetch origin main` (or query the GitHub API). The sandbox clones once at container start; local `origin/main` is frozen at that moment and silently drifts behind. Never report merge state, re-ask a merge decision, or rebase off a local ref without fetching first."

*Grounded in: a session that reported #189/#190 merge state inconsistently and re-asked an already-answered merge question because local `origin/main` was pinned at the clone-time commit while real `main` had advanced past it.*

# justification

This bit hard and visibly: the agent re-asked the owner a merge question that had already been answered and acted on, and wavered on whether two PRs were merged — all because the local `origin/main` ref was hours stale from the container-start clone. The repo already added a session-start fetch-and-warn in the same session, proving the team agrees the stale clone is a real hazard; the gap is that the warning is non-blocking and one-shot, so mid-session state assertions still read frozen refs. The marginal cost of the rule is one `git fetch origin main` (sub-second) before any merge-state claim. The cost of not having it is user-visible confusion and wasted round-trips. The asymmetry is overwhelming.
