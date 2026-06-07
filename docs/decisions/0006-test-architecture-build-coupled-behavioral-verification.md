# 0006 — Test architecture: build-coupled behavioral verification under the real controller identity

- **ID**: ADR-1946fbb159
- **Status**: Accepted (implementation pending — the plan it records is approved but unbuilt)
- **Date**: 2026-06-07
- **Source retrospective**: [`../../retrospective/2026-06-07-167.md`](../../retrospective/2026-06-07-167.md)
- **PRs covered**: #167 (the plan), #166 (the stacked-PR rule it relies on)

## Context

auto-012 hit 8 live blockers found one-at-a-time (OI-2026-06-07-6) because the
test suite proves manifests *say* X, never that X *works*: `tests/unit/*.sh` are
static `yq`/`grep` lints, and the dynamic `chainsaw` layer runs on kind with a
fake cloud and GitHub-Actions **admin** keys — more privilege than production,
and never the restricted Crossplane identity that actually fails in reality. The
owner directed a full test-overhaul plan, produced through a multi-round
adversarial process (`planning/test-overhaul/FINAL-PLAN.md`, via the
`adversarial-plan-synthesis` skill). This ADR records the binding architectural
choices in that plan so they survive as a decision, separate from the (long)
plan doc.

## Decision

Adopt a layered test architecture whose **center is driving the real Crossplane
controller under its real IRSA identity** (`source: IRSA`) and verifying the real
cloud resource — the only oracle for the "unknown-missing-permission" class. Make
it **on by default and coupled to the build**, enforced **mechanically** by a
**fail-closed live-evidence gate** keyed on
`(deployed-config-SHA × account × cluster)` with an unforgeable Actions run-ID
(so even config-only GitOps changes can't reach the cluster unverified). Expose
enablement as a **`full` / `verify-only` / `off` profile selector** (default
`full` during development; `verify-only` keeps only cheap after-the-fact checks so
a proven bring-up isn't ~3 hours; a component change re-arms `full`). Keep two
execution surfaces only: **push/PR = static no-cluster checks**;
**`workflow_dispatch` = the live suite** (cluster work, even kind, is
dispatch-only). Preserve a hard **NON-GOAL**: no probe pod, no new AssumeRole
principal, no trust widening, no provider-SA token mount.
`simulate-principal-policy` is a floor only; negatives must prove the guard fired;
the verifier/reaper runs under a scoped zero-wildcard role, not the admin key.

## Alternatives considered

- **Keep the kind/fake-cloud/admin chainsaw as the gate.** Rejected: it
  validates config shape only and masks the restricted-identity failures (it runs
  with *more* privilege than prod), which is exactly what hid the 8 blockers.
- **Probe pod / new role assuming the controller's identity to test
  permissions.** Rejected by every review round: the trust policy only trusts the
  provider SA; a probe gets a false `AccessDenied`, and widening trust is the
  privilege bloat we test against.
- **Permission-completeness via `simulate-principal-policy` as the oracle.**
  Rejected as the oracle (circular on a `Resource:"*"` policy); kept only as a
  floor.
- **CI (push/PR) as the verification trigger.** Rejected (owner correction #2):
  CI is decoupled from the build; the live suite couples to the build and is
  dispatch-only.
- **Binary disable switch.** Rejected (owner correction #3) for a profile
  selector so a mature platform can run fast without forfeiting on-by-default.

## Consequences

- A real failure class becomes catchable at authoring time; "manifest says X"
  stops counting as a test. Costs: live-cluster test infrastructure, a v2 port of
  `crossplane-claim-verify` (prerequisite), a scoped verifier IAM role, and a
  fail-closed gate that will RED any config reconciled without fresh live
  evidence.
- A `verify-only` profile keeps routine mature bring-ups cheap; the FAIL-closed
  evidence is profile-stamped so `verify-only` can't masquerade as `full`.
- Several owner decisions remain open (FINAL-PLAN §14): the scoped role, the
  spoke CIDR allowlist/AccessEntry, tightening `Resource:"*"`, the ArgoCD
  controller policy.

## References

- [`../../planning/test-overhaul/FINAL-PLAN.md`](../../planning/test-overhaul/FINAL-PLAN.md) — the full plan this ADR records.
- [`../../retrospective/2026-06-07-167.md`](../../retrospective/2026-06-07-167.md) — source retrospective.
- [`../../retrospective/2026-06-07-167/ADR-1946fbb159-test-architecture.md`](../../retrospective/2026-06-07-167/ADR-1946fbb159-test-architecture.md) — the ADR draft.
- `.claude/skills/adversarial-plan-synthesis/SKILL.md` — the process that produced it.
- `docs/open-issues.md` OI-2026-06-07-6 (the diagnosis); `docs/decisions/0005-*` (ESO secret philosophy).
- PRs: #167 (plan), #166 (AGENTS.md §6.28).
