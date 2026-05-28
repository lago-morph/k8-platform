# ADR: Hard-wire pre-chainsaw-audit via PreToolUse hook, not soft-wire via skill description

- **ID**: ADR-3920c7d919
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-28
- **Source retrospective**: ../2026-05-28-129.md
- **PRs covered**: #125, #128

## Context

`scripts/pre-chainsaw-audit.sh` exists and AGENTS.md §6.13 mandates running it before every chainsaw dispatch. The auto-003 chainsaw iteration loop (PR #111, four rounds of red) was the canonical example of what happens when the audit doesn't fire: each round peeled off one bug class the audit would have caught in seconds. After auto-003, the `pre-dispatch-static-audit` skill was authored to surface the audit on user-typed phrases like "dispatch chainsaw" or "run chainsaw".

The skill's triggers are user-facing. An agent that issues `mcp__*__execute` against `chainsaw.yml` directly — which is exactly the path the agent uses when the workflow is dispatched in throughput mode — does not produce text matching those triggers. The audit didn't fire in PR #111's session for this reason. The skill catalog could be re-tightened ("automatic-trigger language"), but that approach still relies on the agent reading the skill catalog at the right moment. The handoff for this session explicitly proposed two options: hard wiring (a PreToolUse hook) or soft wiring (better skill description).

## Decision

Wire `scripts/pre-chainsaw-audit.sh` into a PreToolUse hook in `.claude/settings.json` that filters `mcp__*__execute` calls by the actions/create-workflow-dispatch operation UUID (`op_2acb005c9f3704ad`) plus the `chainsaw.yml` literal, exiting 2 on audit-RED to block the dispatch.

The implementation lives in `.claude/settings.json` (hook configuration) and `scripts/pre-chainsaw-audit-hook.sh` (wrapper that reads the tool-call JSON on stdin, runs the audit, and propagates exit codes to the Claude Code hook engine).

## Alternatives considered

- **Soft wiring (tighten the skill description).** Cheaper to land; preserves user control over whether the audit runs. Rejected because the auto-003 root cause was exactly that the agent never read the skill description at dispatch time. A skill catalog is searched on prompt match; a hook fires on tool call. The hook layer is the only one that fires deterministically on the actual dispatch path.

- **Run the audit in CI as a chainsaw-verify precondition.** Would catch audit-RED PRs before merge, but would not prevent the wasted CI minutes of the dispatch itself. The static audit runs in seconds; the chainsaw run takes ~15 minutes. Catching audit failures pre-dispatch saves the CI minutes that motivated the rule.

- **A pre-commit hook on `git commit`.** Catches the bug at authoring time but not at dispatch time. An agent that authors clean files but then dispatches chainsaw against a different SHA still misses. The PreToolUse hook fires on the dispatch tool call regardless of what's in the working tree.

## Consequences

**Easier:** every agent-initiated chainsaw dispatch is gated by the audit. Audit-RED produces a stderr-with-actionable-message and exit 2; Claude Code surfaces both to the agent so the fix is targeted. The §6.13 rule is now mechanically enforced, not aspirationally enforced.

**Harder:** the hook adds startup latency to every `mcp__*__execute` call (audit + filter ~50ms). The filter must distinguish dispatch from read operations — see the `Pipe-test PreToolUse hook filters with dispatch and read shapes` rule (AGENTS-MD-78b8a7517e) for the test discipline. Mis-broad filters block read queries and force a debug round, as happened in PR #128.

**Trade-off accepted:** the hook's coupling to the jentic catalog's specific operation UUID (`op_2acb005c9f3704ad`). If jentic re-issues the UUID, the filter silently stops firing on dispatch. The mitigation is the recorded UUID in `.claude/skills/ext-github/resources/workflow_dispatch.json` plus the §6.12 "Last verified" date discipline.

## References

- [`../2026-05-28-129.md`](../2026-05-28-129.md) — the source retrospective.
- [`./AGENTS-MD-78b8a7517e-pipe-test-pretooluse-hook-filters.md`](./AGENTS-MD-78b8a7517e-pipe-test-pretooluse-hook-filters.md) — the discipline rule for testing hook filters.
- PRs the decision was made in: #125 (initial wiring), #128 (filter narrowed to dispatch UUID).
- AGENTS.md §6.13 — the prose rule the hook operationalizes.
- `retrospective/2026-05-28-116/SKILL-SPEC-3a7d2e9f1c-pre-dispatch-static-audit.md` — the prior skill spec the hook replaces.
