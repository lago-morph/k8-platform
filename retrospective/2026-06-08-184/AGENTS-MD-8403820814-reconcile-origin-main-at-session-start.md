# agent instruction

**Reconcile with `origin/main` at session start before numbering or basing new work.** The sandbox clones the repo once at container start, so a session can be behind `main` by the time you act. Run `git fetch origin main` and rebase/merge (or branch off the freshly-fetched `origin/main`) before doing anything order-sensitive — numbering, basing a new branch, or assuming a file's latest content. A stale base silently hides files and conventions that already exist on `main`.

*Grounded in: the working branch was 4 commits behind main — missing two committed ADRs — which caused an ADR-number collision and a "where is this file" investigation.*

# justification

The session's branch was cut from `main` at container-start and never re-synced; meanwhile `main` advanced 4 commits (including the two ADRs that caused the numbering collision). Because the local tree didn't contain them, time was lost spelunking for "missing" files before realizing the base was simply stale. The rule is one `git fetch` + a rebase/merge at the top of the session; not having it means every order-sensitive decision is made against a snapshot that may already be wrong, and the staleness only reveals itself after the mistake.
