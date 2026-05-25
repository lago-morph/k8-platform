# agent instruction

**PostToolUse hook compact-session stdin guard.** When authoring or editing a `PostToolUse` hook that reads `tool_input.file_path` from stdin via `jq`, use `jq -r '.tool_input.file_path // empty'` (not `.tool_input.file_path` alone) and add `[ -z "$FP" ] && exit 0` immediately after. Compact/resumed Claude Code sessions may deliver empty or unparseable stdin to the hook; without the guard `jq` returns the literal string `null`, no `case` pattern matches, the gate flag is never cleared, and every non-Read tool call is denied for the entire session.

The correct pattern for `~/.claude/settings.json`:

```json
"command": "INPUT=$(cat); FP=$(echo \"$INPUT\" | jq -r '.tool_input.file_path // empty'); [ -z \"$FP\" ] && exit 0; case \"$FP\" in */AGENTS.md|AGENTS.md) rm -f /tmp/agents-md-unread ;; esac; exit 0"
```

*Grounded in: 2026-05-25 session — unguarded hook blocked all Bash/Write/Edit calls for ~1 hour until machine switch.*

# justification

The existing hook used `jq -r '.tool_input.file_path'` with no null fallback. In a compact/resumed session the PostToolUse stdin was empty or differently structured, so `jq` returned the literal string `null`. The `case "$FP" in */AGENTS.md)` pattern does not match `null`, so `rm -f /tmp/agents-md-unread` never executed, and `/tmp/agents-md-unread` stayed present. Every Bash, Write, Edit, and Agent call was denied for the entire session — roughly 1 hour of dead time spent composing content via chat messages and AskUserQuestion instead of tool calls. The session only recovered when the user switched to a different machine where the flag file didn't exist.

The fix is two characters in the jq expression (`// empty`) plus one `exit 0` guard. The marginal cost: one extra line in the hook command. The marginal benefit: every compact session works correctly without manual intervention. The asymmetry is extreme — 1 line vs 1 hour per occurrence.
