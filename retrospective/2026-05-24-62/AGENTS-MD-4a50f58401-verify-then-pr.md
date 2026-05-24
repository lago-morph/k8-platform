# agent instruction

**§6.X — Verify-then-PR.** For any PR whose value depends on a manual check (chainsaw, integration-tests, phase-2-diagnose, custom diag workflow), the agent SHOULD push the branch, dispatch the relevant check against the SHA, wait for the check to go green, and ONLY THEN open the PR. Per AGENTS §6.7's chainsaw rule, generalized to all manual checks.

Exception: workflow-only PRs where the workflow itself is the check (chicken-and-egg). Document the exception in the PR body.

*Grounded in: every PR opened "to dispatch chainsaw against the SHA" then waited for chainsaw to finish before being merged-ready. The session opened PRs before checks completed, leaving red verify badges visible to the user.*

# justification

Opening a PR before its check completes leaves a visible red badge that the user has to mentally filter. The cost of the rule is ~5–15 minutes of wall-clock waiting per PR; the value is a PR that's actually green when reviewed. Repeated 11 times this session, the cost of not-having-the-rule was 11 confusing PRs.

---
