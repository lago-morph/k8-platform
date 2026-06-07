# agent instruction

**Finalize commits before dispatching a SHA-gated heavy CI run.** "Do not push further commits after dispatching a heavy CI run that a verifier gates by exact HEAD SHA; finalize all commits first, then dispatch, or the cached green run never matches HEAD and the gate stays red on work the run already validated."

*Grounded in: 2026-06-07 — repeatedly dispatched chainsaw then pushed docs commits, so chainsaw-verify never matched HEAD; the merge ultimately relied on `mergeable_state: unstable` (non-blocking), not a green gate.*

# justification

During PR #165 finalization I dispatched chainsaw against a commit SHA, then pushed docs-only commits, which moved HEAD and orphaned the just-dispatched (or in-flight) green run — and I did this three times. Because `chainsaw-verify` gates on an exact HEAD-SHA match (AGENTS §6.7), the PR check stayed red on work the heavy run had actually validated, and the eventual merge leaned on `mergeable_state: unstable` (mergeable, non-blocking) rather than a satisfied gate. The fix is pure sequencing and free: make the last commit, push it, *then* dispatch the SHA-gated run, and add no further commits until it completes. Corollary surfaced the same day: `mergeable_state: unstable` means "mergeable with non-blocking checks failing/pending," not "blocked" — do not defer a merge on the assumption a non-required check is blocking it; check the state.
