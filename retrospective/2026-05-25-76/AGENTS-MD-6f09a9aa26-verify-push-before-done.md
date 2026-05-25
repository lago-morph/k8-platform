# agent instruction

**Verify push succeeds before declaring work done.** After `git commit`, always confirm that `git push` exits 0 and that `git log --oneline origin/<branch>..HEAD` returns empty (i.e. the remote has the commit). A local commit with a failed push is indistinguishable from "not done" to any subsequent session or CI run. If push fails (SSH key unavailable, upstream diverged, remote not configured), surface the failure immediately with the exact error — do not declare the session complete while any commit is local-only.

*Grounded in: 2026-05-25 session — handoff commit `b498d1f` on main was local-only for an extended period after `git push origin main` failed with `Permission denied (publickey)` and the HTTPS fallback also failed.*

# justification

During session wrap, `git push origin main` failed silently in the sense that the agent continued past it and declared the handoff "committed and pushed." The commit existed locally but was invisible to GitHub, to CI, and to the next session. The HTTPS fallback attempt also failed. The result: the user asked in the next exchange whether the handoff was written, and the correct answer was "the commit exists locally but was never pushed." A subsequent `git log --oneline origin/main..HEAD` check would have caught this in one command.

The marginal cost: one `git log --oneline origin/<branch>..HEAD` after every push. If it returns anything, the push failed — surface the exact push error and resolve it before moving on. The cost of skipping: any number of sessions that start from a stale baseline because "committed" was treated as equivalent to "pushed."
