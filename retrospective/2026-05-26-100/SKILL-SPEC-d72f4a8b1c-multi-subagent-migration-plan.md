# Spec: `multi-subagent-migration-plan`

- **ID**: SKILL-SPEC-d72f4a8b1c
- **Source retrospective**: ../2026-05-26-100.md

## Intent

When a breaking-change migration affects many files across multiple distinct concern areas, no single subagent has the context to design the migration alone, and no human agent has the cycles to plan every segment with enough rigor. This skill prescribes a pipelined multi-subagent workflow: cheap mechanical impact tracing (sonnet) feeds expensive parallel design subagents (opus), each segment goes through adversarial review (opus reviewers), revisions converge by pre-committed cross-segment decisions (sonnet), and the orchestrator synthesizes one master plan. The pipeline ran in session 2026-05-26 with 24 total subagents and converged on a Crossplane v1→v2 migration plan in two rounds with no round-3 needed.

## Trigger

Direct triggers:
- "Design a migration plan for X"
- "Plan the upgrade from V1 to V2"
- "Get a thorough breakdown of what needs to change"
- "Multi-segment plan with adversarial review"

Proactive triggers:
- Repository touches more than ~15 files for a single breaking change
- Migration crosses concern boundaries (e.g., production manifests + infra + tests + tooling + in-flight PRs)
- User explicitly asks for "plan-only, not execute"

Negative triggers:
- Single-file or single-concern change (over-engineered)
- Routine version bump that doesn't break APIs
- Migration of fewer than ~3 segments worth of concern (one or two opus planners is enough; the pipeline overhead isn't justified)

## Inputs

- A clearly-stated breaking change at the source (e.g., "Crossplane v1→v2") with one or more upstream documentation pages or release notes the orchestrator can cite.
- Knowledge of the repo's concern boundaries (production code vs. tests vs. infra vs. tooling vs. open work).
- An output directory to write artifacts to (canonical: `ai/<migration-name>/`).

## Outputs

A directory under `ai/<migration-name>/` (or equivalent) containing:

- `00-situation.md` — root cause, evidence, breaking-change list, scope
- `10-impact-<area-1>.md`, `11-impact-<area-2>.md`, ... — mechanical impact traces (one per concern area)
- `20-plan-SEG-<N>-<name>.md` — per-segment plans (POST-REVIEW-R1)
- `30-review-SEG-<N>-R1<A|B>-<aspect>.md` — round-1 adversarial reviews (2 per segment)
- `40-final-plan.md` — synthesized master plan

The final plan must contain: a one-diagram summary, segment ownership matrix, merge sequence (Gantt or DAG), parallel work streams, hot-files matrix, failure recovery decision tree, definition of done.

## Workflow

1. **Orchestrator writes the situation doc.** This is non-delegable. Capture: what is broken, what evidence proves it, what the target state is, the scope (file counts, breaking-change list), why now. End with a "what this migration is NOT" section to bound scope.

2. **Dispatch N sonnet impact tracers in parallel.** N = number of distinct concern areas (typically 3–5). Each tracer is given a strict scope and a list of files to inspect. The tracer produces a mechanical reference-trace report: which files contain v1 patterns, what the runtime symptom would be on v2, no opinions on fix design. Sonnet because the work is reference-counting, not creative.

3. **Orchestrator reviews impact traces for correctness.** Spot-check a few specific claims by running the same `grep`/`find` and comparing. If a trace is wrong, dispatch a corrective subagent or fix manually.

4. **Dispatch M opus segment planners in parallel.** M = number of cohesive work segments (typically 4–7). Each planner gets the situation doc + all relevant impact traces + a scope definition. Output: per-segment plan with mermaid migration sequence, open questions, failure recovery, cross-segment dependencies, hot files, time estimate.

5. **Dispatch 2 × M opus adversarial reviewers in parallel.** Reviewer A focuses on sequencing (merge order, race conditions, blocked states, gate ordering). Reviewer B focuses on correctness (does the proposed change actually achieve the migration's goal; are there missing alternatives; are there factually wrong claims). Each reviewer produces a verdict (`ACCEPT` / `REVISE-MINOR` / `REVISE-MAJOR`) plus a numbered list of findings with line citations.

6. **Orchestrator scans all 2M reviews for cross-cutting issues.** If reviewers across multiple segments flag the same disagreement (e.g., "segment A picked X, segment B picked Y for the same shared interface"), the orchestrator **pre-commits** the decision before dispatching round-2 (see the companion skill `pre-commit-cross-segment-decisions`).

7. **Dispatch M sonnet author revisions in parallel.** Each gets the original plan + both round-1 reviews + the pre-committed cross-segment decisions. Sonnet because the work is "incorporate clear feedback" not "design from scratch". Author addresses every flaw or explicitly flags why it wasn't addressed.

8. **Orchestrator runs a cross-segment alignment check** by grepping for the pre-committed decision values across all 5 revised plans. If alignment is clean and no new contradictions emerged, skip round-3 reviewers and proceed to synthesis. If not, dispatch round-3 reviewers per segment.

9. **Orchestrator synthesizes the final master plan.** Non-delegable. Combines per-segment plans into a single document with: one-diagram master flowchart, segment ownership matrix, merge sequence Gantt, parallel work streams (Wave 0/1/2/3 visualization), hot-files matrix, failure recovery decision tree, definition of done, time estimate, location of every per-segment plan.

10. **Commit all artifacts, open a PR.** The PR is the deliverable.

## Concrete examples

### Example 1: Crossplane v1→v2 migration (session 2026-05-26)

- Situation doc: identified v1.12.0 Upbound providers on v2.3.0 Crossplane chart as the root cause of `PendingExternalResource` failures. Cited the chainsaw log showing ESO succeeded while Crossplane provider Observe failed for the same secret.
- 4 sonnet impact tracers (parallel): session tools (10 tools, 42 v1 refs found), production manifests (12 of 26 files affected, both XRDs are BLAST), terraform/IRSA (3 of 22 blocks affected, IRSA SA name pin is the load-bearing question), test infra (45 files inspected, 4 categorized by failure shape).
- 5 opus segment planners (parallel): SEG-1 production manifests, SEG-2 terraform, SEG-3 test infra, SEG-4 tooling regen, SEG-5 in-flight PR reconciliation.
- 10 opus adversarial reviewers (parallel): 2 per segment. Verdicts: 7 REVISE-MAJOR, 3 REVISE-MINOR. No `ACCEPT` clean.
- Pre-committed 8 cross-segment decisions (e.g., provider tag `v2.5.0` not `v2.5.4`; `providerConfigRef.kind: ClusterProviderConfig`; XRD apiVersion `apiextensions.crossplane.io/v2`).
- 5 sonnet R2 revisions (parallel): all 5 plans converged on the pre-committed decisions.
- Cross-segment alignment check (orchestrator) confirmed convergence; no R3 needed.
- Synthesis: `40-final-plan.md` with one-diagram summary, ownership matrix, merge sequence Gantt, hot-files matrix, failure recovery decision tree, 5 deferred open questions.
- Total subagents: 24. Total wall-clock: ~2 hours. Output: 12 files in `ai/crossplane-v1-v2-un-fuckify/`.

### Example 2: Sketched — hypothetical Helm chart v3→v4 migration

- 3 sonnet impact tracers: chart-consumer manifests, values overrides, terraform helm_release calls.
- 4 opus planners: SEG-A chart pin bump, SEG-B values reshuffle (v4 renamed many keys), SEG-C consumer notification, SEG-D test rewrites.
- 8 opus reviewers, 4 sonnet R2 revisions.
- Pre-committed decision: which subchart consolidation path to follow (v4 supports both; pick the one matching repo's existing patterns).
- Synthesis identifies that SEG-B's values reshuffle dominates the timeline; SEG-A and SEG-D can parallelize after SEG-B's values-mapping document is final.

## Anti-patterns

- **Using opus for impact tracing.** Wasteful — the work is mechanical reference-counting. Sonnet is right for this.
- **Using sonnet for segment planning.** Insufficient — plans involve design tradeoffs and need opus's reasoning depth.
- **Skipping the orchestrator-side impact-trace review.** Sonnet tracers sometimes count wrong (this session: deletionPolicy count was off by 1). The orchestrator's spot-check catches these before they propagate into segment plans.
- **Letting round-2 authors re-decide contested cross-segment values.** They diverge again. Pre-commit the values; tell each round-2 author to use the values verbatim. (See companion skill.)
- **Dispatching round-3 reviewers "just in case" when alignment is clean.** Wasteful; trust the convergence signal from round-2 + alignment check.
- **Writing the final synthesis as a subagent task.** The synthesis must integrate every plan's tradeoffs and resolve cross-segment disagreements — the orchestrator has the full context; the subagent doesn't.

## Acceptance criteria

1. The final plan contains a one-diagram master flowchart that names every wave and every segment.
2. Every segment plan in the package is at status `POST-REVIEW-R1` or later.
3. Every cross-segment decision is uniformly applied across all segment plans (grep test: the pre-committed value appears identically in every segment file that references it).
4. The merge sequence is unambiguous: an engineer following the Gantt should know exactly what to merge next at any point.
5. The plan includes an explicit list of deferred open questions for the executor.

## Files this skill creates / modifies

- `ai/<migration-name>/00-situation.md` — root cause + evidence + scope.
- `ai/<migration-name>/10-impact-*.md` — one per concern area.
- `ai/<migration-name>/20-plan-SEG-*-*.md` — one per segment.
- `ai/<migration-name>/30-review-SEG-*-R1<A|B>-*.md` — two per segment.
- `ai/<migration-name>/40-final-plan.md` — synthesis.
