# agent instruction

**Pre-commit cross-segment decisions before round-2 subagent revisions.** "When adversarial reviewers across N parallel plan segments flag the same cross-cutting inconsistency (e.g., 'segment A picked X, segment B picked Y for the same shared interface'), the orchestrator decides the answer ONCE and propagates the decision to every round-2 author subagent in their brief verbatim. Do not allow round-2 authors to relitigate the decision independently — they will diverge."

*Grounded in: session 2026-05-26 Phase 5 — 4 reviewers across SEG-1/SEG-3/SEG-4 independently flagged `ProviderConfig` vs `ClusterProviderConfig` inconsistency. Pre-committing `ClusterProviderConfig` before R2 dispatch made all 5 plans converge in one round; no round 3 was needed.*

# justification

Multi-subagent planning with adversarial review is expensive. The session that produced this rule dispatched 24 subagents (4 sonnet impact tracers + 5 opus planners + 10 opus reviewers + 5 sonnet R2 author revisions). If the orchestrator lets round-2 authors re-decide contested shared values independently, each will pick a defensible-but-different answer again — because each only sees their own segment's review feedback, not the cross-cutting pattern. Round 3 then becomes mandatory: dispatch 10 more reviewers to catch the same disagreement, then 5 more author subagents to revise. That's 15 additional opus subagents to fix what could have been one orchestrator-side decision.

Pre-committing is cheap. The orchestrator's process:

1. Grep the 2N round-1 review files for shared disagreements (identical fields cited with conflicting recommendations, "should align with SEG-X" phrasing, recurring open questions).
2. For each disagreement, pick the option supported by an existing repo pattern, upstream documentation, or convergent reviewer signal.
3. Cite the source.
4. Append a "Pre-committed cross-segment decisions (USE THESE)" table near the top of every round-2 author brief.

Total orchestrator effort: ~10 minutes per migration. Net savings: an entire adversarial-review round (10 reviewers + 5 authors). Asymmetric cost ratio: roughly 50× in this session's case.

The session demonstrated convergence: all 5 round-2 plans applied the 8 pre-committed decisions verbatim. The post-R2 alignment check (grep each pre-committed value across every revised plan) found no deviations. Round 3 was skipped without loss.
