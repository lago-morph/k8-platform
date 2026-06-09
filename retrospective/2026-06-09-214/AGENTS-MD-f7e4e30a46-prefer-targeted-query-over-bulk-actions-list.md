# agent instruction

**Prefer targeted API queries over bulk list responses for large GitHub Actions state.** Do not call `mcp__github__actions_list` or equivalent bulk-list endpoints to find the status or run-id of a specific workflow run — these responses can exceed 390 KB and will overflow the context window. Instead, use a targeted query (e.g. `mcp__github__actions_get` with a known run-id, a filtered `gh run list --workflow` call, or parsing a previously-saved file for the few fields needed).

*Grounded in: auto-016 — `mcp__github__actions_list` returned ~390 KB JSON that overflowed the context; the agent recovered by parsing a saved file.*

# justification

In auto-016 a call to `mcp__github__actions_list` returned approximately 390 KB of JSON — the full run history for all workflows in the repository. This overflowed the available context window and forced the agent to recover by locating a previously-saved file and parsing the few fields needed (run-id, status, conclusion) from that file instead. The detour cost several tool call round-trips and risked losing in-progress state.

The list endpoint aggregates every run across every workflow; it is almost never the right tool for "what is the status of run X" or "what is the run-id for the most recent dispatch of workflow Y." The targeted alternatives are cheaper by two orders of magnitude: `mcp__github__actions_get` with a known run-id returns a single object, and `gh run list --workflow <file> --limit 5` returns a handful of rows. Either fits in a few hundred bytes.

The marginal cost of adopting this rule: replace one `actions_list` call with a run-id lookup or a scoped `gh run list`. The cost of not adopting it: a 390 KB response that consumes the majority of the available context window and forces a recovery path, with a real risk of truncating the conversation history mid-run in an unattended session.
