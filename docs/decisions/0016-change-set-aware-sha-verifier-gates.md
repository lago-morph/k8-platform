# 0016 — Change-set-aware applicability for fail-closed SHA-verifier gates

- **ID**: ADR-c87dd95a8c
- **Status**: Accepted (owner-directed adoption 2026-07-06)
- **Date**: 2026-07-06 (drafted in the docs-track retrospective; adopted by owner direction)
- **Source retrospective**: [`../../retrospective/2026-07-06-256.md`](../../retrospective/2026-07-06-256.md)
- **PRs covered**: #256
- **Mechanical enforcement**: `.github/scripts/required-profile-for-changes.sh`
  (the three-tier `full` / `verify-only` / `none` decision) +
  `tests/unit/test_live_evidence_gate.sh` (pins all three tiers plus the
  gate-machinery circularity case); the gate workflows
  `chainsaw-verify.yml` / `live-evidence-verify.yml` compute the change
  set against `origin/main` before asserting evidence

## Context

The repo runs two fast, fail-closed "SHA-verifier" gates —
`chainsaw-verify.yml` and `live-evidence-verify.yml` — that do no heavy
work themselves; they assert that a prior green heavy run (chainsaw, or
`terraform-test.yml apply-and-verify`) exists for the exact HEAD SHA
before a PR may merge. Each is scoped by a push **path filter** meant to
fire only when chainsaw-gated or live-config paths change. In PR #256 a
docs-only branch tripped both gates: rebasing onto a `main` that had
advanced past the branch's original base carried that main's recent
`crossplane/**` and `policies/**` history through the ref-update diff,
so the push path filters matched and demanded chainsaw + live evidence
for a change set that touched none of it. The gate was not wrong to be
fail-closed; it was keying applicability off the wrong signal (the
trigger diff, which is a property of the push mechanics, not of the
branch's actual content).

## Decision

The SHA-verifier gates decide applicability from the **merge-base change
set** (`git diff origin/main...HEAD`), not the push path filter; a new
`none` tier green-skips when the change set touches no gated surface.

`required-profile-for-changes.sh` now emits three tiers: `full`
(`crossplane/**` or `policies/**` — ArgoCD syncs these to the live hub
with no apply-and-verify dispatch), `verify-only`
(`terraform/management/**` or `tests/live/**`), and `none` (everything
else, including docs and the gate machinery itself). The live-evidence
gate exits 0 on `none`; the chainsaw verifier applies the same
merge-base guard. Gate-machinery edits are deliberately `none` —
demanding a heavy run to change the gate's own decision logic is
circular, and the git credential cannot push workflow files regardless;
`tests/unit/test_live_evidence_gate.sh` plus review own that
correctness. The path filters remain as a cheap pre-filter (they decide
*whether the job starts*), but the change set decides *whether the job
is applicable* once started.

## Alternatives considered

- **Recreate the branch so the push diff is only the new commits.**
  Rejected as a workaround: it exploits trigger semantics, leaves the
  over-firing armed for every future rebased PR, and reads as
  re-kicking a gate to green — which the repo's done-contract forbids.
- **Dispatch the demanded heavy runs.** Rejected: costly chainsaw and
  live-account runs to validate a docs diff, treating a spurious demand
  as legitimate.
- **Drop the path filters and always run the verifier body.** Rejected:
  the filters usefully avoid starting the job on unrelated pushes; the
  fix is to make the *body* self-check applicability, not to remove the
  pre-filter.

## Consequences

- **Easier:** docs-only and other non-gated PRs stop being blocked by
  gates that have nothing to verify; rebasing onto a moved main is safe;
  the gate's applicability is now a function of branch content, which is
  what the header always claimed it was.
- **Harder / accepted:** the gate scripts now checkout with full history
  (`fetch-depth: 0`) and run a `git diff` — a few seconds added to a
  sub-5-minute job. The `none` tier widens the surface the tests must
  pin, which they now do.
- **Preserved:** fail-closed behavior for real `full`/`verify-only`
  change sets is unchanged; `none` never applies to a branch that
  actually edits gated paths.

## References

- [`../../retrospective/2026-07-06-256.md`](../../retrospective/2026-07-06-256.md) — the source retrospective (Phase 5).
- `.github/scripts/required-profile-for-changes.sh` — the three-tier decision.
- `tests/unit/test_live_evidence_gate.sh` — pins all three tiers plus the machinery-circularity case.
- PR #256 commits `6e50be8`, `38bb8e3`, `61e5ace`.
