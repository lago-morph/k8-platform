# ADR: Scope-and-grow the live-evidence gate

- **ID**: ADR-a0d1c09eb6
- **Status**: Draft (not yet adopted to docs/decisions/)
- **Date**: 2026-06-08
- **Source retrospective**: ../2026-06-08-190.md
- **PRs covered**: #188, #190

## Context

ADR-0006 mandates a fail-closed live-evidence gate that RED-s any config reconciled
without fresh behavioral proof under the real IRSA identity. But the full behavioral
coverage set is ~14 composed-MR kinds, and authoring + live-validating all of them is a
multi-session effort. The naive readings are both bad: (a) ship the gate "off" until every
kind has a check (the gate never gates, and the nightly-lane disease excised in #188 creeps
back as "we'll turn it on later"); or (b) ship the gate "on" claiming full coverage it does
not have (it green-lights kinds with no real oracle — the "manifest says X" lie ADR-0006
kills). A third tension surfaced while wiring #190: a check returns SKIP when its kind isn't
provisioned in the account, and the orchestrator *promotes* a SKIP to a FAIL when git declares
the kind (expect-full). So broadening the declared set faster than the account actually
provisions resources makes the gate RED for reasons unrelated to a real regression.

## Decision

Ship the live-evidence gate covering a single proven kind and broaden `LIVE_EXPECT_FULL`
only as fast as the live account actually provisions each kind, never narrowing the
expected-coverage set to make a run green. The gate is on and fail-closed from day one; its
*coverage* grows monotonically as each per-kind behavioral check lands and the corresponding
registry `defended_by` flips off `pending:P*`.

## Alternatives considered

- **Gate off until full coverage exists.** Rejected: a gate that doesn't gate is the
  non-gating-lane antipattern #188 just excised; "turn it on later" never happens.
- **Gate on, declaring full coverage immediately.** Rejected: it green-lights kinds with no
  behavioral oracle, reintroducing the exact "manifest says X" failure ADR-0006 exists to
  catch.
- **Narrow `LIVE_EXPECT_FULL` to whatever happens to be green on a given run.** Rejected as
  green-washing: it lets a missing/unprovisioned kind silently drop out of the expected set,
  so a real regression (a kind that *should* exist but doesn't) reads green.

## Consequences

- The gate is trustworthy from the first merge: every kind it claims to defend has a real
  passing behavioral check, and every git-declared kind that is absent goes RED.
- Coverage debt is explicit and tracked: the coverage registry's `pending:P*` markers WARN
  (not FAIL) until the behavioral test lands, then become a hard gate — the team can see
  exactly how much of the set is genuinely defended at any time.
- The cost is discipline: broadening `LIVE_EXPECT_FULL` is coupled to two facts at once —
  a passing check exists AND the account provisions the kind — so the person broadening it
  must verify both, not just write the check.

## References

- [`../2026-06-08-190.md`](../2026-06-08-190.md) — the source retrospective.
- `docs/decisions/0006-test-architecture-build-coupled-behavioral-verification.md` — ADR-0006, the parent decision this refines.
- `tests/coverage/registry.yaml` — the `pending:P*` / `defended_by` mechanism.
- `.github/scripts/live-verify-run.sh` — where `LIVE_EXPECT_FULL` is declared.
- PRs the decision was made in: #188 (carried the RDS coverage forward), #190 (built the gate scope-and-grow).
