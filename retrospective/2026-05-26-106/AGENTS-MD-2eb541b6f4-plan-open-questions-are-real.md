# agent instruction

**Treat plan Open Questions as adversarial-execution checkpoints, not curiosities.** "When executing a multi-segment migration plan, every `§3 Open Question` left unresolved by the plan must be VERIFIED at execution time, not skipped. The plan-authoring session marked them open because the answer wasn't known then; resolving them is part of the execution scope. Default behavior must be: explicitly run the verification command the plan suggests, before any code change that depends on the answer."

*Grounded in: 2026-05-26 v1→v2 migration — SEG-1 plan §3 Open Q-3 anticipated v2 might reject `connectionSecretKeys`; the SEG-1 subagent kept the field based on kubeconform schema-pass alone, requiring a hotfix PR after Wave 2 merged.*

# justification

A plan's §3 Open Questions encode known unknowns. Skipping them is a common-mode failure across multi-segment plans. The 2026-05-26 migration had 5 plan-flagged open questions; 4 were resolved by execution-time observation, but Q-3 (XRD `connectionSecretKeys` survival on v2) was dismissed because kubeconform validated cleanly. The plan's exact wording was "Verify after XRD apply"; the subagent treated kubeconform as the apply, which is wrong. Cost of adopting: each open question becomes a verification step in the segment's execution; ~5-30 min per question. Cost of NOT adopting: the question's failure mode lands as a post-merge hotfix, which costs strictly more.
