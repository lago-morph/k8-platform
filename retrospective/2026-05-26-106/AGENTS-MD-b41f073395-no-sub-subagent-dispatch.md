# agent instruction

**Worktree-isolated subagents cannot dispatch sub-subagents.** "When the lead agent dispatches a subagent in worktree-isolation mode, the subagent does NOT have access to the Agent/Task tool. AGENTS.md §6.4 adversarial test-plan review must therefore be performed INLINE by the worktree subagent (which is acceptable per §6.4's allowance for `general-purpose`) OR by the lead agent before the worktree dispatch. Do NOT brief a worktree subagent with `dispatch a reviewer subagent`; it will fail silently and proceed without review."

*Grounded in: 2026-05-26 v1→v2 migration, all 4 worktree subagents (PR-A/B/Wave2-C/D) reported `Agent tool not available; inline review only`.*

# justification

AGENTS.md §6.4 requires adversarial test-plan review by subagent. All 4 worktree subagents in the 2026-05-26 run honestly documented "Agent tool not available; inline review performed instead" — proving the contract was unworkable as written for nested dispatch. The inline reviews still surfaced findings (e.g., SEG-3 caught the `spec.scope: Namespaced` defaulting trap that would otherwise have admitted a `LegacyCluster`-defaulted XRD), but the lead-agent brief should not REQUIRE a tool the subagent doesn't have. Cost of adopting: lead-agent briefs must specify "perform inline review" for worktree subagents. Cost of NOT adopting: subagents silently degrade to no review, or waste context attempting an impossible dispatch.
