# ADR: AWS account change halts AGENTS §6.6 throughput mode

- **ID**: ADR-bc9d85b7e8
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-24
- **Source retrospective**: ../2026-05-24-62.md
- **PRs covered**: (documented in handoff PR #62)

## Context

Mid-session the user announced an imminent account change (the prior account `309191981509` was being torn down). The agent's behavior in that moment was ambiguous — throughput mode says press on, but the new account's secrets weren't necessarily rotated yet, no Route53 zone was guaranteed, and IRSA/IAM scope might differ. Pressing on could have meant dispatching workflows that mutate the wrong account.

## Decision

Even under AGENTS §6.6 throughput-without-attention mode previously granted by the user, a change of AWS account (or its credentials) is a hard stop condition; the agent must re-confirm scope, secrets rotation, and Route53 hosted-zone presence with the user before resuming any dispatch.

## Alternatives considered

- **Treat account change as a continuation of throughput mode** — rejected because account-level scope is too broad to assume.
- **Halt all agent action until user manually re-grants throughput** — rejected as too heavy; account change is a narrow re-confirmation, not a full session reset.
- **Halt only the next mutating op, allow read-only operations** — partial; the rule should still require explicit re-grant before any mutating op resumes.

## Consequences

**Easier:** safer cross-account boundaries; agent's bookkeeping forced to refresh; one more checkpoint before destructive ops. **Harder:** one extra round-trip per account change (rare). **Trade-off:** small operator friction for catastrophic-error prevention.

## References

- [`../2026-05-24-62.md`](../2026-05-24-62.md) — the source retrospective.
- [`./SKILL-SPEC-3dd589f9a4-diagnose-before-mutate.md`](./SKILL-SPEC-3dd589f9a4-diagnose-before-mutate.md) — related skill spec.
- [`./SKILL-SPEC-92c9f7a0af-verify-evidence-not-exit-codes.md`](./SKILL-SPEC-92c9f7a0af-verify-evidence-not-exit-codes.md) — related skill spec.
- PRs the decision was made in: (documented in handoff PR #62).
