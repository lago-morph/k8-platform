# agent instruction

**§6.X — Long-form load-bearing docs (handoffs, RFCs, plans, specs) get at least 3 review iterations.** Each iteration uses a subagent (named scope, named previous-iteration findings to verify) PLUS the agent's own re-read. Iteration N's prompt explicitly lists iteration N-1's findings for verification, so regressions are caught. Stop when two consecutive iterations surface no MEDIUM+ findings.

*Grounded in: the handoff rewrite (PR #62) went through 3 iterations. Iteration 1 found 12 issues; iteration 2 found 11 new ones AFTER iteration 1's fixes were applied; iteration 3 found 6 more. A single-pass review would have shipped 22 known-now-fixable issues.*

# justification

Long docs are the most expensive to get wrong — they're read by future agents who can't ask for clarification. The rule's cost is ~3× one pass, which is small relative to a doc's lifetime. The rule's value is the cross-iteration regression detection that no single pass provides.

---
