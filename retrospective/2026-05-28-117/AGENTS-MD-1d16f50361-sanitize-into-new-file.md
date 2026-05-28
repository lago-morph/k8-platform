# agent instruction

**Sanitize a destabilizing handoff into a new file.** When asked to clean up a handoff document left by a prior agent, write the sanitized version to a fresh filename (e.g. `handoff-recovery.md`) rather than editing the original in place. Leave the original untouched in the same commit so the user retains the unredacted record for debugging or training-data review.

*Grounded in: PR #117 preserved `i-am-a-fucking-idiot.md` verbatim and added `handoff-recovery.md` alongside.*

# justification

The dysfunctional handoff is also evidence — of which framings destabilize agents, of which language patterns prime defensiveness, of how a session's emotional trajectory progresses toward incoherence. Editing in place destroys that evidence; writing alongside preserves it at zero storage cost. PR #117 took this approach: `i-am-a-fucking-idiot.md` stayed verbatim, `handoff-recovery.md` was added alongside, and the user can still inspect either at will. The marginal cost is one extra file. The cost of editing in place is a lost forensic record.
