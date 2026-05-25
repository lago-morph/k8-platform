# ADR: Capability discovery via extension of existing auto-invoked composites

- **ID**: ADR-38c8fd4626
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-75.md
- **PRs covered**: #75

## Context

During the top-15 immediate-changes review in PR #75, the initial top-10 list was scored on three criteria: easy to implement, addresses a known retro pain, fits existing workflows. The user pushed back: *"instructing an agent to do anything is extremely fragile. For the ones that set up logging and monitoring, what tells a future agent to actually use those capabilities?"* This crystallized a discipline that had been implicit but not stated:

**Producing data and telling an agent to look at it is the same as not producing it.** The retros are full of evidence: phase-2-diagnose.yml was authored ad-hoc because no one remembered the existing audit log group had the answer; PRs #66/#67/#68 burned 30-60 minute debug loops walking IRSA chains that CloudTrail already recorded; the "Apply complete: 0 added" silent no-op (PR #67) was caught by a human noticing the count, not by any documented checking discipline.

The fragility is structural: a future agent in the middle of a debug loop is cognitively loaded; they will reach for what they always reach for, not for a new file documented in `docs/runbook.md`. Documentation-as-discovery has a recurring miss rate that approaches 100% for tools used "remember to check X".

## Decision

New observability, diagnosis, or verification capabilities MUST be discovered by future agents through **extension of an already-auto-invoked composite** — a skill listed in AGENTS.md §7 (like `crossplane-claim-verify` or `terraform-ci-watch`), a workflow that runs on every push (like `unit-tests.yml`), or a test runner that auto-discovers conforming files (like `tests/unit/run.sh`). New capabilities MUST NOT rely on documentation that asks an agent to remember a new file, run a new command, or check a new dashboard.

Concretely: if a PR adds a CloudWatch log group, the same PR must add (a) a saved `aws_cloudwatch_query_definition` resource so the query appears in the console, AND (b) a script that runs the query, invoked from an existing skill's failure path or an existing test's error output. If a PR adds a new lint, it must drop a file into `tests/unit/test_<name>.sh` so `tests/unit/run.sh` auto-discovers it — never wire it into a new workflow.

## Alternatives considered

- **Status quo (documentation in runbooks).** Rejected. The retros directly demonstrate the failure mode: every diagnose loop discovers ad hoc that the data needed already exists somewhere, but only after the loop is already 30-60 minutes in.
- **A "remember to check" rule in AGENTS.md.** Rejected. Adding a rule that says "remember to check X" recurses on the same fragility — the user's pushback in PR #75 was explicitly that even AGENTS.md rules don't reliably fire mid-debug-loop.
- **A new "session start checklist" tool.** Rejected. Adds friction to every session start in exchange for catching capabilities used 1% of the time. The ROI is wrong; the better target is the moment-of-need, which is what extension-of-existing-composite achieves.
- **Per-rule Kyverno-style policies that scan for missing consumers.** Considered, deferred. The conformance-check pattern is correct in principle (`a producer without a consumer is a lint failure`), but the implementation cost in this sandbox is high and the rule itself catches the bug class — the policy is a future hardening.

## Consequences

**Easier:**
- Every new capability gets used reliably without the agent remembering it exists.
- Failure paths (skill error branches, test failure output, workflow-level catch hooks) become the natural home for diagnostic data.
- The number of "new file documented but never used" failure modes drops to near zero.

**Harder:**
- Every observability or verification PR requires identifying which existing composite to extend — a real architectural choice rather than a sprinkle of documentation.
- Some capabilities don't fit cleanly into any existing composite, forcing either (a) finding a creative home, (b) extending a composite slightly out of its original purpose, or (c) deferring the capability until a suitable composite exists.

**Trade-off accepted:**
- Higher per-PR design cost (the author must answer "where does this fire automatically?") in exchange for capabilities that are actually used.

## References

- [`../2026-05-25-75.md`](../2026-05-25-75.md) — the source retrospective.
- See also: AGENTS-MD-5be7f693c1 (observability producers ship with their consumers — the operational form of this ADR).
- PRs: #75 (the top-15 review where the principle was named; the 15 specs all conform to it).
- Related: AGENTS.md §7 lists the existing auto-invoked skills (`crossplane-claim-verify`, `terraform-ci-watch`) that are the canonical extension points.
