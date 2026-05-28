# ADR: Chainsaw scenario asserts on v2 XR conditions enumerate all 3 conditions

- **ID**: ADR-eb8acdc4a2
- **Status**: Draft (not yet adopted to docs/decisions/)
- **Date**: 2026-05-28
- **Source retrospective**: ../2026-05-28-113.md
- **PRs covered**: #105 (merged), #111 (open)

## Context

Crossplane v2 XRs emit 3 status conditions where v1 XRs typically emitted 1-2:
- `Synced` (status=True when reconciliation succeeds)
- `Ready` (status=True when all composed resources are ready)
- `Responsive` (status=True when the watch circuit is closed — `reason: WatchCircuitClosed`; new in v2)

Chainsaw uses kyverno-json as its match engine. For arrays, kyverno-json matches **element-wise at the same index** with **strict length comparison** by default. An assert listing 1 or 2 conditions against an actual array of 3 returns `lengths of slices don't match` before any element-level comparison happens.

The auto-003 chainsaw run [26544796570](https://github.com/lago-morph/k8-platform/actions/runs/26544796570) demonstrated this: all 3 platform-secret scenarios timed out at 245s (their assert deadline) with the error:

```
status.conditions: Invalid value:
  [Synced True ReconcileSuccess, Ready True Available, Responsive True WatchCircuitClosed]:
  lengths of slices don't match
```

The XR was healthy — Ready=True at t+16s — but the assert shape was wrong for v2.

## Decision

**Chainsaw `status.conditions:` asserts on v2 XR kinds MUST list all 3 conditions (Synced, Ready, Responsive) in the order Crossplane emits them, each with the expected `status: "True"`.**

This is the simplest path that works with kyverno-json's default array matching. The alternative (JMESPath expressions) is also valid for one-off cases but loses documentation value.

A unit test `tests/unit/test_chainsaw_xr_conditions_complete.sh` enforces this on every push by scanning every chainsaw scenario for `status.conditions:` blocks under v2 XR kinds and asserting all 3 condition types appear (added in PR #105 commit `8298c1f`).

## Alternatives considered

- **Use JMESPath / kyverno-json expression form `(conditions[?type == 'Ready'][0].status): "True"`.** Works, and is more robust against future Crossplane versions adding a 4th condition. Rejected as the default because it obscures the v2 contract for readers — listing all 3 conditions documents what a healthy v2 XR looks like.
- **Configure chainsaw to use partial-match for arrays.** Chainsaw 0.2.x doesn't expose this at the assertion level. Rejected as unavailable.
- **Assert only the conditions we care about and accept the failure.** Rejected — the failure mode (245s timeout with cryptic error) costs ~15 minutes to diagnose per occurrence. Spending ~30 seconds adding 1-2 condition lines per scenario is cheaper.

## Consequences

**Easier:**
- Authors writing new chainsaw scenarios have a clear rule and an explicit example of v2's condition shape.
- The v2 reconcile path is documented as a side effect of the assertion (future v2-to-v3 migrations have a sanity-check anchor).

**Harder:**
- When Crossplane adds a new condition type (e.g., `Authoritative` in some hypothetical v2.7), every chainsaw scenario asserting `status.conditions:` will need to be updated — and until it is, every scenario will fail with `lengths of slices don't match`. The mitigation: the unit test `test_chainsaw_xr_conditions_complete.sh` can be updated as part of the version bump.
- A new XR kind needs its condition shape verified (typically by inspecting one healthy XR in a kind cluster) before scenarios are authored.

**Trade-off accepted:** explicit-shape brittleness (must list all conditions; condition list updates couple to Crossplane minor versions) in exchange for human-readable scenarios + a clear regression contract. The alternative (JMESPath) hides the contract; the rule's value comes from making the contract obvious.

## References

- [`../2026-05-28-113.md`](../2026-05-28-113.md) — the source retrospective.
- [`./SKILL-SPEC-6c87b3a142-v2-condition-array-asserts.md`](./SKILL-SPEC-6c87b3a142-v2-condition-array-asserts.md) — the skill spec.
- [`./AGENTS-MD-c1eaa07eea-chainsaw-xr-conditions-complete.md`](./AGENTS-MD-c1eaa07eea-chainsaw-xr-conditions-complete.md) — the agents-file rule.
- PR #105 merge `41e661d` — included commit `8298c1f` with the fix + TDD test.
- chainsaw run 26544796570 — the failing run (this ADR's motivating evidence).
- chainsaw run 26545542710 — the next iteration, which exposed the script-shell-portability bug behind the conditions fix (see ADR-7c1d2fb4a3).
