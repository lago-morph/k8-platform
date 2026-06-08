# ADR: No nightly or non-gating test lanes — deterministic gates or delete

- **ID**: ADR-cd4edb9a7c
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-08
- **Source retrospective**: ../2026-06-08-184.md
- **PRs covered**: #184

## Context

This session a single focused task (give the sandbox `kubectl`) kept tripping over the
test gate rather than the feature. The chainsaw gate went red three times on a
pre-existing flake — `claim-deletion-cleanup` does a one-shot `aws secretsmanager
describe-secret` immediately after deleting the XR, racing AWS Secrets Manager's
eventually-consistent deletion — and the reflex each time was to re-dispatch it and
explain why it "didn't really matter". Separately, the repo carried a
`CHAINSAW_INCLUDE_REALAWS` / "REAL-AWS / NIGHTLY" mechanism (`tests/chainsaw/run.sh`)
that *excluded* real behavioral scenarios from the gating run and deferred them to a
nightly that nothing blocks on, with render-fixtures + a unit test + a manual runbook
standing in for behavioral coverage. Both are the same failure: a check nobody acts on
when it's red. The owner named it directly — "you don't pay attention to it half the
time when it's red" — and directed that it be excised, building on ADR-0006
(build-coupled behavioral verification).

## Decision

Every behavioral test gates fail-closed at its proper execution surface; a check that
flakes for reasons unrelated to the change is made deterministic or deleted — there is
no nightly or otherwise non-gating lane to relegate it to. Concretely: deterministic,
no-cloud checks gate on push/PR; real-cloud behavioral checks gate on the
`workflow_dispatch` live suite (fail-closed, coupled to the build per ADR-0006). A
flaky gating check is a defect — fix it with a bounded poll that accepts every valid
terminal state (e.g. ASM deletion: accept `NotFound` *or* a set `DeletedDate`), or
remove it. Re-running is legitimate only for a genuinely external infra blip, and the
flaky check still gets filed and fixed.

## Alternatives considered

- **Keep the nightly/`CHAINSAW_INCLUDE_REALAWS` lane for slow real-AWS tests.** Rejected:
  it is decoupled from the build and substitutes lints + a manual runbook for behavioral
  proof — the exact antipattern ADR-0006 forbids, and the mechanism that let the flake
  hide. ADR-0006's surfaces (push static / dispatch live, fail-closed) already cover
  "this test is slow" without a schedule.
- **Quarantine flaky checks to a tracked non-gating lane.** Rejected here: a quarantine
  that doesn't block is still a check nobody acts on; the owner explicitly dislikes
  non-gating tests. Determinism-or-delete keeps the gate trustworthy.
- **Tolerate the flake and re-kick (status quo).** Rejected: it failed 3/3 this session,
  burned dispatch cycles, and trains everyone to distrust red.

## Consequences

- **Easier:** a red gate is always actionable — no triage of "real vs flake", no
  re-kick loops, no merging-around-red. Trust in CI is restored.
- **Harder:** real-cloud behavioral tests must be written deterministically (bounded
  polls, terminal-state acceptance) and run in the fail-closed dispatch suite, which
  costs dispatch time and some authoring care. Slow tests can no longer be parked on a
  schedule; they must earn their place in a gating surface or be cut.
- **Trade-off accepted:** more up-front rigor per behavioral test in exchange for a gate
  whose red is never ignored. This pairs with AGENTS §6.36 and the burndown in
  `docs/testing-debt-burndown.md`, which queues the concrete excision (delete the
  exclusion, the `REAL-AWS / NIGHTLY` tags, `test_chainsaw_realaws_gated.sh`, the
  golden-exempt; migrate RDS behavioral coverage into the gating live suite).

## References

- [`../2026-06-08-184.md`](../2026-06-08-184.md) — the source retrospective.
- [`./AGENTS-MD-e2e2a5161b-red-gate-is-real-no-nightly.md`](./AGENTS-MD-e2e2a5161b-red-gate-is-real-no-nightly.md) — the per-rule agents addition.
- Companion: ADR-1946fbb159 (test architecture: build-coupled behavioral verification) — `retrospective/2026-06-07-167/`.
- PR the decision was made in: #184. Burndown: `docs/testing-debt-burndown.md`; OI-2026-05-28-1 + OI-2026-06-06-4 in `docs/open-issues.md`.
