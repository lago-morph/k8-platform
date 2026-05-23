# AGENTS.md suggestion: Maintain a bug-class registry

## Proposed addition

> **§6.6 The bug-class registry.** `ai/TESTING-PLAN.md` contains a
> bug-to-test traceability matrix. After each session that
> surfaces a new bug class (defined as a failure not previously
> represented in the matrix), the agent adds a row before the PR
> is marked ready. The row contains: a one-sentence summary, the
> session date, the test layer that would have caught it, and the
> specific test file added.
>
> The matrix is a normative part of the adversarial-subagent brief
> (§6.4 input #3). Missing rows degrade adversarial-review quality
> for future phases.
>
> *Grounded in: the matrix introduced in PR #34's
> `ai/TESTING-PLAN.md`. Without the maintenance discipline it would
> rot within two phases.*

## Why this earns its place in your agents file

The bug-class registry is high-leverage *if* it's kept current —
it's the input to the adversarial-subagent brief and the basis for
the traceability claim in PRs. The registry decays fast if updates
aren't on the critical path of merging; making the update a
PR-readiness check is the cheapest way to keep it useful.
