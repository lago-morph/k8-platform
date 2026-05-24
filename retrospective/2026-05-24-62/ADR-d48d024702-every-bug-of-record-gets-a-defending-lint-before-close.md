# ADR: Every bug-of-record gets a defending lint before close

- **ID**: ADR-d48d024702
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-24
- **Source retrospective**: ../2026-05-24-62.md
- **PRs covered**: #59, #61

## Context

PRs #59 (bash `$UID` shadowing + missing `set -e`) and #61 (Composition `string` transform missing `type: Format`) both followed this pattern. The UID lint caught the bug in two files (`11_platform_secret_e2e.sh` AND `scripts/diag-component.sh`) — the second file would have been missed without the all-files scan. The composition lint caught 9 instances across two files. Without the lint, future agents authoring similar code re-introduce the bug class because no signal forbids it.

## Decision

Every bug fix PR in this codebase ships with a unit-test lint under `tests/unit/test_<bug-class>.sh` that demonstrably went RED on the unfixed code and GREEN after the fix, scans all relevant files (not just where the bug was first observed), and is wired into `tests/unit/run.sh`.

## Alternatives considered

- **Fix only without lint** — rejected because the bug class returns the next time similar code is authored, with no signal.
- **Lint only the instance, not the class** — rejected because the bug recurs when a new file introduces the pattern.
- **Lint after a few recurrences** — rejected because by then the precedent set is harder to navigate retroactively.

## Consequences

**Easier:** future agents have explicit invariant signals; bug classes don't silently recur. **Harder:** ~5 extra minutes per bug fix to author the lint. **Trade-off:** small per-fix cost for permanent regression prevention.

## References

- [`../2026-05-24-62.md`](../2026-05-24-62.md) — the source retrospective.
- [`./SKILL-SPEC-9149cdc0a6-tdd-lint-bug-class.md`](./SKILL-SPEC-9149cdc0a6-tdd-lint-bug-class.md) — related skill spec.
- PRs the decision was made in: #59, #61.
