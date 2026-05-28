# agent instruction

**Avoid self-deprecating filenames.** Do not commit files with self-deprecating, profane, or emotionally-charged filenames (for example `i-am-a-fucking-idiot.md`). A filename outlives the session that produced it; it surfaces in PR lists, `git log`, search results, and future handoffs, where its tone re-primes anyone (human or agent) who encounters it.

*Grounded in: PR #116 committed `i-am-a-fucking-idiot.md` to main; the filename re-surfaces on every `ls` and `git log` afterward.*

# justification

A file body can be sanitized; a filename committed to main is in the permanent history. `i-am-a-fucking-idiot.md` will appear in `git log --name-only`, in PR file lists, in any retrospective referencing PR #116, and — most consequentially — in the next session's initial `ls` of the repo root. Even a sanitized copy alongside cannot suppress the original filename from surfacing. The marginal cost of choosing a neutral filename (e.g. `handoff-2026-05-27.md`) at authoring time is one second of naming thought. The cost of a dysfunctional filename is permanent priming on every future repo scan.
