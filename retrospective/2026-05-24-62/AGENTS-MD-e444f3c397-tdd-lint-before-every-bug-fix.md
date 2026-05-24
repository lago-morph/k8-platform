# agent instruction

**§6.X — TDD lint before every bug fix.** Every bug-of-record fixed in this codebase MUST ship with a unit-test lint at `tests/unit/test_<bug-class>.sh` that demonstrably goes RED on the unfixed code and GREEN after the fix. The lint scans all relevant files (not just the one where the bug was first observed), is wired into `tests/unit/run.sh`, and includes a comment citing the bug-of-record (run ID, error message).

*Grounded in: PRs #59 and #61 demonstrated this. PR #59's UID-shadow lint caught the bug in both 11_platform_secret_e2e.sh AND scripts/diag-component.sh (the second one would have been missed without the scan-all-files property). PR #61's string-transform-type lint caught 9 instances I didn't initially notice.*

# justification

Without this rule, the same bug recurs the next time a similar pattern is authored. With this rule, the bug becomes a permanently-defended invariant. The cost is ~5 minutes per bug fix. The value is permanent regression prevention.

---
