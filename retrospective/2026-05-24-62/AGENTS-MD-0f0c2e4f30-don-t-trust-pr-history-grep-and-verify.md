# agent instruction

**§6.X — Don't trust PR-history claims; grep and verify.** When the agent (or a doc) asserts "PR #N adds field X" or "the config includes Y per PR #N", the agent MUST grep the live source to confirm before relying on it. PRs can be reverted, merged-then-edited, or simply mis-described in retrospect.

*Grounded in: the handoff doc's Step 11 said "Confirm the AppProject allows PlatformCluster claims (already does per PR #42's project spec)" — replacing trust-the-PR with `grep -A4 namespaceResourceWhitelist argocd/projects/*.yaml` was a finding in iteration 3 of the handoff review.*

# justification

The rule is a 5-second grep. The cost of not having it is a category of confidently-wrong actions based on stale PR history.

---
