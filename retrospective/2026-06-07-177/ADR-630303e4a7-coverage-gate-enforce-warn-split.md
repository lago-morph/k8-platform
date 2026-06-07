# ADR-630303e4a7 — Split the coverage gate: ENFORCE the deterministic drift gate, WARN the behavioral coverage

**Status:** proposed (draft from auto-013 retro)
**Date:** 2026-06-07
**Context PR:** #172 (Pipeline-mode coverage deriver)
**Supersedes/relates:** FINAL-PLAN §4.5 ("ships WARN-ONLY first" + the WARN→enforce flip lint)

## Context

FINAL-PLAN §4.5 says the derived coverage manifest "ships WARN-ONLY first" with a
mechanical WARN→enforce flip condition (round-3 devx M4), because "a mis-firing
gate that reds every PR is worse than the hand manifest." But it also wants
un-registered kinds to be CI-red. Read literally, "WARN-ONLY first" and "an
un-registered kind is CI-red" are in tension while the behavioral tests that
defend each kind do not yet exist (they land in P2/P4/P5).

## Decision

Split the single "coverage gate" into two gates with different enforcement:

1. **Extractor↔oracle DRIFT gate — ENFORCE immediately.** `derive-coverage.sh
   --check` compares the set derived from the committed Compositions against
   `tests/coverage/expected-coverage.txt`. This is fully deterministic: it reds
   *only* when a Composition's composed-MR set changes without the oracle being
   regenerated. It cannot misfire on unrelated PRs. `tests/coverage/mode` is
   `enforce`, and the WARN→enforce flip lint is satisfied (a green byte-identical
   fixture with the mode still `warn` would itself be a red diff).

2. **Behavioral `defended_by` coverage — WARN-ONLY until P2/P4/P5.** The registry
   marks each kind `defended_by: pending:P<n>` until its behavioral test ships;
   the unit test WARNs (does not fail) on pending markers. When all are real test
   IDs, this becomes a hard gate (DevX C2).

## Consequences

- The deterministic "you changed the MR set without updating coverage" signal is
  enforced from day one — stronger than the plan's literal "WARN-ONLY first",
  without the misfire risk the plan feared (that risk was specific to a
  test-existence gate, not a config-drift gate).
- The behavioral-coverage ratchet still tightens phase-by-phase as P2/P4/P5 land.
- Rewind: `echo warn > tests/coverage/mode` softens the drift gate to advisory
  (and would then require relaxing the fixture, which is not recommended).

## Alternatives considered

- **Both gates WARN-ONLY** (literal plan reading): rejected — leaves the
  deterministic, no-downside drift signal toothless for no benefit.
- **Both gates ENFORCE now:** rejected — would red every PR until P4 behavioral
  tests exist, the exact misfire the plan warns against.
