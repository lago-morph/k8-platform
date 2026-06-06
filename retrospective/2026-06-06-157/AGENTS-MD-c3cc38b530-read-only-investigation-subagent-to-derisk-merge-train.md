# agent instruction

**De-risk a feared merge-train with a read-only investigation subagent first.** Before committing to a multi-cycle, CI-gated merge train, dispatch one read-only investigation subagent to establish which gates actually apply: which PRs touch the paths the expensive gate watches, and whether that gate is required. A train that *looks* like it needs N expensive CI cycles often collapses into a few fast conflict-resolve-and-merge steps once you know the gate does not apply.

*Grounded in: auto-009 — one read-only subagent established the auto-007 stack touched no chainsaw paths and `chainsaw-verify` was non-required, turning a feared chainsaw-gated train into five fast merges.*

# justification

The instinct when facing a stack of stale PRs is to assume the worst about CI: that each merge will trigger the heaviest gate and the train will take many slow cycles. In auto-009 a single read-only investigation subagent dissolved that fear cheaply — it established that the auto-007 phase 3-6 stack touched no `crossplane/**` or `tests/chainsaw/**` paths (so no chainsaw run was needed) and that `chainsaw-verify` was non-required anyway (PR #144 had merged with it red). The feared multi-cycle chainsaw-gated train became five fast conflict-resolve-and-merge steps. The subagent is read-only and runs in parallel, so it costs almost nothing against the lead's budget; the alternative is either serially waiting on expensive gates that may not even apply, or merging blind and discovering the gate matters after the fact. One cheap reconnaissance dispatch reshapes the entire plan from "slow and gated" to "fast and serial".
