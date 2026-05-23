# AGENTS.md suggestion: TDD-on-bug-fix is unconditional

## Proposed addition

> **TDD discipline when fixing bugs.** When the agent finds any
> issue — CI failure, verify mismatch, runtime surprise,
> user-reported bug, anything — the order of operations is:
>
> 1. **Write a test that would have caught the bug.** Pick the test
>    layer closest to the bug's authoring time (e.g. an IAM-policy
>    completeness bug is a unit test, a runtime drift bug is a
>    Kyverno policy, a multi-step AWS flow bug is an integration
>    test). If the bug fits multiple layers, author the test in each.
> 2. **Run the test against the unfixed code.** Confirm it **fails**
>    (red). If the test passes against buggy code, the test does
>    not actually catch the bug — rewrite it before continuing.
> 3. **Implement the fix.**
> 4. **Verify both:** the new test now passes (green), AND the
>    original symptom (CI step, e2e check, etc.) is resolved.
> 5. **Commit the fix and the test together.** The PR diff must
>    show both so reviewers see what would have caught the
>    regression.
>
> Skipping any step is a procedure violation. Applies to every bug,
> including "obvious" ones — those are exactly the silent-failure
> class that tests prevent.
>
> Does **not** apply to pure refactors (no bug, no test) or net-new
> features (those follow the author-tests-alongside-features rule).
>
> *Grounded in: the 2026-05-23 phase-1 bring-up that took 6 fix
> attempts because regressions reappeared in adjacent forms.*

## Why this earns its place in your agents file

Without this rule, the agent's natural impulse on a bug is "find
the cause, fix, move on." That impulse loses the value of the
bug — the regression-catching test that would prevent it next time.
The 2026-05-23 phase-1 cycle paid this cost concretely: bugs 3, 6,
and 7 were all chart-value mismatches in different shapes; the
unit tests added in response to bug 7 would have caught 3 and 6
too if they'd been written then.

The marginal cost of writing the test first is 5–15 minutes; the
marginal value is permanent (every future regression-catching
session benefits). The asymmetry doesn't need defending — it just
needs codifying so the rule is the default rather than a virtuous
exception.
