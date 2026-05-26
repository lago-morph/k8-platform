# Spec: `pre-commit-cross-segment-decisions`

- **ID**: SKILL-SPEC-5e8a3f2bd9
- **Source retrospective**: ../2026-05-26-100.md

## Intent

When parallel design subagents produce per-segment plans for a shared system, they often disagree on cross-cutting decisions — values, conventions, or interfaces that span segments. Adversarial reviewers reliably surface these disagreements as "REVISE-MAJOR" findings across multiple segments. The naive next step is to dispatch round-2 author revisions and hope each picks the same answer — but they won't, because each author only sees their own segment's review. This skill prescribes a forcing function: the orchestrator scans round-1 reviews for shared disagreements, decides each contested value once, and propagates the decision into every round-2 author's brief verbatim. In session 2026-05-26 this collapsed what would have been a round-3 from cross-segment divergence into zero — the 5 plans converged on the same answers in one revision round.

## Trigger

Direct triggers:
- "Reconcile the cross-cutting reviewer findings"
- "Pre-commit the contested decisions before round-2"

Proactive triggers (use without being asked):
- After round-1 adversarial review, the orchestrator notices ≥2 reviewers across different segments flagging the same shared value, interface, or convention with different recommendations.
- A round-1 reviewer explicitly cites a value from another segment's plan as inconsistent with their segment.
- Multiple segments' "open questions" sections converge on the same question.

Negative triggers:
- Single-segment plans with no shared decisions — there's nothing to pre-commit.
- The orchestrator genuinely doesn't have enough context to decide — ask the user; don't pre-commit guesses.

## Inputs

- The N per-segment plans (round-1 drafts).
- The 2N adversarial review reports (round-1).
- The orchestrator's knowledge of the repo's existing patterns, conventions, and constraints.

## Outputs

- A table of pre-committed decisions, one row per contested value:

  | Decision | Value | Rationale | Sources cited |
  |---|---|---|---|

- A round-2 author-revision brief template that includes the table verbatim, with instructions to apply the decisions verbatim and not relitigate.

## Workflow

1. **Scan round-1 reviews for shared disagreements.** Grep across all 2N review files for: identical filenames cited as in-conflict, identical field names or kinds with different proposed values, the phrase "should align with SEG-X" or equivalent, and any "open question" that recurs across segments.

2. **For each shared disagreement, list the candidate values.** Each segment's plan likely picked one. Each reviewer may have endorsed or rejected one. Make the option set explicit before deciding.

3. **For each contested value, decide.** Use one of these tie-breakers in order:
   - Existing repo pattern (search the codebase for the prevailing convention).
   - Upstream documentation (search for the canonical guidance).
   - Cost-of-reversal asymmetry (pick the option that's easier to undo).
   - Reviewer consensus (if 2-of-3 reviewers across segments converged on one option, that's the default).

4. **Cite sources for each decision.** A row without a citation is a guess; record it as such and flag for user review.

5. **Construct the round-2 author brief.** Include a "Pre-committed cross-segment decisions (USE THESE)" section near the top of the brief, with the decision table verbatim. State explicitly: "Do not relitigate these decisions — use the values verbatim throughout your revised plan."

6. **Dispatch round-2 author revisions** with the brief. Per the companion skill `multi-subagent-migration-plan`, sonnet is the appropriate model for revision work.

7. **After round-2, run an alignment check.** Grep each pre-committed value across every revised plan. If a plan deviates, that revision was sloppy — dispatch a corrective targeted at just that plan's deviating section, not a full round-3.

## Concrete examples

### Example 1: Crossplane v1→v2 migration (session 2026-05-26)

Round-1 reviewer findings across SEG-1/3/4 disagreed on:

- `providerConfigRef.kind` value (4 reviewers flagged: SEG-1B, SEG-3A, SEG-3B, SEG-4A).
- Provider tag (SEG-4B verified `v2.5.4` doesn't exist on upstream; latest is `v2.5.0`).
- XRD apiVersion for migrated XRDs (SEG-1B challenged the `apiextensions.crossplane.io/v1 + spec.scope: Namespaced` form as unsourced).
- Unit composition test sequencing (SEG-3A + SEG-5A both flagged the post-#98 red-main risk).
- #91 v1-residue scope (SEG-5B counted 6 affected files, plan had said 2).
- #94 disposition (SEG-5 said close, SEG-4 said partial salvage).
- CRD URL handling (SEG-4B noted v2 ships both legacy and v2 CRDs).

The orchestrator pre-committed 8 cross-segment decisions:

| Decision | Value | Rationale |
|---|---|---|
| Provider tag | `v2.5.0` | Verified via WebFetch of upstream tags page — v2.5.4 returns 404 |
| `providerConfigRef.kind` | `ClusterProviderConfig` | Repo's existing pattern: one shared `default` config across Compositions |
| XRD apiVersion | `apiextensions.crossplane.io/v2` | v2-specific group; the v1 form with `spec.scope: Namespaced` is silently ignored by v2.3 apiserver |
| `deletionPolicy` replacement | `managementPolicies: [Observe, Create, Update, Delete]` | v2 replacement for the deprecated field; preserves prior MR lifecycle behavior |
| Unit composition test sequencing | Stacked child PR off SEG-1's branch | Prevents red main between #98 merge and SEG-1 merge |
| #91 v1-residue scope | All 6 files via SEG-3/SEG-4 stacked PR | Reviewer's higher count was correct |
| #94 disposition | Close, with selective salvage of 3 deterministic goldens + 5 enforcer tests + Bug 4 fixture into SEG-4 PR-T3 | Reconciles SEG-4 + SEG-5 |
| CRD URL handling | Drop legacy `.aws.upbound.io_*.yaml` URLs entirely; replace with `.aws.m.upbound.io_*.yaml` | v2 ships both groups; rewriting only would install dual-mode CRDs |

Each was passed verbatim to the 5 round-2 author subagents. All 5 R2 plans applied the values without dispute. Cross-segment alignment check (grep for each value across all 5 plans) confirmed convergence. No round 3 needed.

### Example 2: Sketched — Helm chart v3→v4 with subchart consolidation

Round-1 reviewers across 3 segments disagreed on whether to consolidate the helm subcharts at the chart level (one umbrella chart) or the manifest level (one Application with multiple sources). Pre-commit: "consolidate at the manifest level — matches the existing ArgoCD pattern in this repo, and the chart-level consolidation would force a values.yaml migration that nothing else needs." Round-2 authors apply uniformly.

## Anti-patterns

- **Guessing the decision when sources don't support it.** If neither the existing pattern nor upstream docs support an answer, ask the user via `AskUserQuestion`. Pre-committing a guess just defers the bad decision into round-2.
- **Pre-committing on a single reviewer's recommendation.** Cross-cutting decisions need at least one source (existing pattern, upstream docs, or convergent reviewer signal). One reviewer's opinion isn't enough.
- **Letting round-2 authors "re-evaluate" pre-committed decisions.** The whole point of pre-commit is to remove that latitude. The brief must explicitly say "do not relitigate."
- **Skipping the post-R2 alignment check.** Authors sometimes drift even with verbatim decisions in their brief; a grep across all revised plans catches sloppy revisions cheaply.
- **Dispatching a full round-3 review when only one R2 plan deviated.** Cheaper to dispatch a targeted corrective on the deviation; full round-3 wastes opus tokens.

## Acceptance criteria

1. Every cross-cutting disagreement raised by ≥2 reviewers across different segments has a row in the pre-commit table.
2. Every row has a stated rationale and at least one source citation.
3. Every round-2 author brief contains the table verbatim near the top.
4. Post-R2 alignment check passes: each pre-committed value appears identically across every segment plan that references it.
5. If alignment check fails, the corrective is targeted at the deviating plan, not a full extra review round.

## Files this skill creates / modifies

- The orchestrator's working memory (no on-disk artifact unique to this skill).
- Round-2 author briefs receive the pre-commit table inline.
- Post-R2 alignment check produces no file; output is the orchestrator's go/no-go signal for synthesis.
