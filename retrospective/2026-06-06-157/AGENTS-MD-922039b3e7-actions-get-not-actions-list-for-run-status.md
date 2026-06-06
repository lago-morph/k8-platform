# agent instruction

**Use `actions_get` (single run), not `actions_list`, for CI run status.** To check the status or conclusion of a specific workflow run, call `mcp__github__actions_get` with method `get_workflow_run` — it returns one run compactly. Do NOT call `mcp__github__actions_list` for status: it returns 380KB+ payloads that overflow the tool-result cap and must be sliced from a saved file. Reserve `actions_list` for when the list itself is genuinely needed, and then parse it from a persisted file.

*Grounded in: auto-009 — `actions_list` overflowed the tool-result cap on every call; `actions_get` returned the run status compactly.*

# justification

During auto-009's live-rebuild track the agent repeatedly needed one thing: the status/conclusion of a single in-flight workflow run. Reaching for `mcp__github__actions_list` returned 380KB+ payloads every time — large enough to overflow the tool-result cap, forcing the result to be persisted to a file and sliced back out before the one status field could be read. `mcp__github__actions_get` (`get_workflow_run`) returns exactly that one run compactly, so the right tool is a direct, cheap call. The asymmetry is stark: the wrong tool costs a cap overflow plus a save-and-slice round-trip on a poll loop that may run dozens of times across a live track, while the right tool costs a single small response. The rule is a one-line tool-selection reminder; without it an agent naturally lists-then-filters and pays the overflow tax on every poll.
