# agent instruction

**Git branch before any session-wrap commit.** Any commit made at session wrap (handoff update, retrospective, chore) must land on a named branch, not `main`. The sequence is: `git checkout -b chore/<name>`, make the commit, `git push origin chore/<name>`, open a PR. A session-wrap commit directly to `main` violates §3 and requires a three-step unwind (`checkout -b`, `reset --hard origin/main`, push branch) at the start of the next session.

*Grounded in: 2026-05-25 session — handoff commit `b498d1f` landed on main, requiring a 10-minute unwind before the next session could start cleanly.*

# justification

At session wrap the mental model shifts to "just updating docs" — it feels like an exception to the branch rule. It isn't. The violation requires `git checkout -b chore/<name>` (to rescue the commit onto a branch), `git checkout main && git reset --hard origin/main` (to clean main), and `git push origin chore/<name>` (to expose the branch). That's roughly 10 minutes of mechanical recovery at the start of the next session, plus the risk that a distracted agent runs `git push origin main` against the diverged local state and force-pushes.

The marginal cost of doing it right: one `git checkout -b chore/<name>` before the commit. The asymmetry is 1 command vs 3 recovery commands + potential force-push damage. The rule has no edge cases — every session-wrap commit, no matter how trivial, goes on a branch.
