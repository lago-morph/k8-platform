# AGENTS.md suggestion: Stacked PRs as the default for multi-step work

## Proposed addition

> **Stacked PRs.** When dependent work needs to start before a
> parent PR has merged, stack:
>
> 1. Create the parent PR off `main` as normal.
> 2. From the parent branch, create the child branch.
> 3. Open the child PR with `base = <parent branch>` (not `main`).
> 4. Once the parent merges, GitHub auto-rebases the child to `main`.
>
> Do not wait for a parent to merge before starting the child. State
> the dependency in the child PR's description.
>
> Naming convention for stacks: parent branch reflects the parent's
> purpose; child branches do not need to reference the parent
> (GitHub tracks it via `base`).
>
> *Grounded in: the 2026-05-23 session's multiple stacked PRs
> (#36 → handoff PR → retro PR), which let the user review and
> merge in parallel with the agent finishing the chain.*

## Why this earns its place in your agents file

Without stacked PRs, multi-step work serializes on reviewer
availability — each PR has to merge before the next can be
authored. That turns a one-day delivery into a multi-day one
because the agent sits idle between reviews.

Stacked PRs decouple authoring from merging. The reviewer gets a
clean per-PR diff (each PR contains one logical change), the agent
keeps moving, and GitHub handles the rebase automatically when the
parent merges. The cost is one extra step at PR-open time ("set
base = parent"); the benefit is wall-clock parallelism.
