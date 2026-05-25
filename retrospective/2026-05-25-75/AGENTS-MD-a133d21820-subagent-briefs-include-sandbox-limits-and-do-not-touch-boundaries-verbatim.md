# agent instruction

**Subagent briefs include sandbox-limits and do-not-touch boundaries verbatim.** Every subagent dispatched in the Pluralsight sandbox must receive (a) the contents of `ai/aws-test-environment-limitations.md` verbatim in the brief (or, at minimum, the compressed bullet list of hard blockers — regions, instance families, Bedrock/Marketplace exclusions), and (b) an explicit list of files/directories the subagent must not touch — typically the in-flight implementation agent's territory (`terraform/`, `crossplane/`, `argocd/`, `clusters/`, `platform-services/`, `tests/`, `policies/`, `scripts/`, `.github/`). Without (a), subagents have provisioned forbidden resources; without (b), parallel subagents have collided on the same files.

*Grounded in: 27 subagent dispatches across PRs #73 and #75 all followed this template; none provisioned forbidden resources and none collided on files.*

# justification

The Pluralsight sandbox terminates accounts that cross specific lines (regions other than us-east-1/us-west-2, instance families outside t2/t3/t3a/t4g micro/small/medium, Bedrock or Marketplace usage). A subagent without the limits-block embedded in its brief has no way to know these lines exist — it would assume normal AWS, provision forbidden resources, and trigger account termination that costs the user a multi-hour restart. The brief is the ONLY communication channel; once a subagent is spawned it has no other source of project-specific constraints.

Similarly, parallel-fanout patterns (e.g., 15 subagents in PR #75 authoring different specs) require explicit do-not-touch boundaries or they collide on shared files (`SKILL.md`, `tests/integration/run.sh`, the `crossplane-claim-verify` skill, etc.). The boundaries are project-specific and change session-to-session as the implementation agent shifts focus; the orchestrator must specify them at dispatch time.

The marginal cost is ~10 lines per brief (a copy-paste block). The cost of omitting it is one of: a terminated AWS account, a hostile parallel-write conflict, or wasted subagent time on the wrong files. Always include.
