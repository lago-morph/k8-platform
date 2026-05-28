# agent instruction

**When a webhook subscription is the agreed completion channel and 1.5x the expected ETA has elapsed with no event, do a single direct-API status query as a backup.** PR-activity subscriptions occasionally drop `workflow_run completed` events without dropping the surrounding `check_suite` failure events; silence on the channel does not mean the work is still running. Confirm with one direct-API call before assuming.

*Grounded in: 2026-05-28 PR #111 chainsaw run 26550478501 — completion event for the green run never delivered via `mcp__github__subscribe_pr_activity`; user noticed before agent did.*

# justification

PR #111 was subscribed via `mcp__github__subscribe_pr_activity` from the session's start. The verifier-workflow failure events for that PR delivered reliably (four of them, one per push). The chainsaw run for the final SHA `ef410ac` completed `success` at 02:17:38Z — and no webhook arrived. The agent's stated discipline was "wait for the completion webhook before any further status query" (AGENTS.md §6.10). It waited eight minutes; the user prompted "An action completed 8 minutes ago, was that what you were waiting for?" The risk surface of strict no-poll discipline is silent webhook loss: the agent stays blocked indefinitely. A single direct-API query, gated on "expected ETA + 50% has elapsed", costs one tool call and resolves the ambiguity without violating the no-foreground-polling spirit (still one query, not a polling loop). The asymmetry: one tool call vs an indefinite stall plus the social cost of the user noticing before the agent does.
