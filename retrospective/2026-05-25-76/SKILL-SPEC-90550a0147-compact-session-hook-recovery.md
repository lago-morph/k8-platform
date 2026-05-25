# Spec: `compact-session-hook-recovery`

- **ID**: SKILL-SPEC-90550a0147
- **Source retrospective**: ../2026-05-25-76.md

## Intent

Diagnose and resolve a broken `PostToolUse` hook that blocks all non-Read tool calls in a compacted or resumed Claude Code session. In compact sessions, the hook's stdin may be empty or unparseable, causing a `jq` null return that silently leaves a gate flag in place. This skill provides a fast diagnosis path (using only Read) and the minimal fix, avoiding the multi-hour dead session that results from not recognizing the failure mode.

## Trigger

**Direct triggers:**
- Every non-Read tool call returns `BLOCKED: You have not Read AGENTS.md yet` even after reading AGENTS.md.
- `Bash`, `Write`, `Edit`, `Agent` calls are all denied in a session that started from a compact summary.
- `/tmp/agents-md-unread` exists after multiple AGENTS.md reads.

**Proactive triggers:**
- A session begins with `SessionStart:compact hook success` in a system-reminder (compact continuation) and the first Bash call fails with the BLOCKED message.

**Negative triggers:**
- Fresh (non-compact) session where the first Read of AGENTS.md successfully cleared the flag (Bash works normally). No action needed.

## Inputs

- The error message: `BLOCKED: You have not Read AGENTS.md yet`
- Access to `~/.claude/settings.json` (via Read)
- The `/tmp/agents-md-unread` flag file (verifiable via Read)

## Outputs

- Diagnosis: confirmation that the PostToolUse hook's `jq` null-return is the root cause.
- Immediate workaround: user runs `rm -f /tmp/agents-md-unread`.
- Permanent fix: updated PostToolUse hook command in `~/.claude/settings.json`.

## Workflow

1. **Confirm the flag exists.** Use Read on `/tmp/agents-md-unread`. If it returns content (even empty/1-line), the flag is present and the hook is the problem.

2. **Read `~/.claude/settings.json`.** Confirm the PostToolUse hook command. Look for `jq -r '.tool_input.file_path'` without a null fallback (`// empty`).

3. **Communicate the diagnosis to the user.** With only AskUserQuestion available (Bash is blocked), explain:
   - The root cause: compact session delivers empty stdin to the hook; `jq` returns `null`; `case "null" in */AGENTS.md)` doesn't match; flag never cleared.
   - The immediate fix: `rm -f /tmp/agents-md-unread` in their terminal.
   - The permanent fix: update the hook command.

4. **After the user clears the flag** (or switches to a machine where the flag doesn't exist), **verify tools are unblocked** with a trivial Bash call (`echo test`).

5. **Apply the permanent fix to `~/.claude/settings.json`.** Replace the PostToolUse hook command with the null-guarded version:

   ```json
   "command": "INPUT=$(cat); FP=$(echo \"$INPUT\" | jq -r '.tool_input.file_path // empty'); [ -z \"$FP\" ] && exit 0; case \"$FP\" in */AGENTS.md|AGENTS.md) rm -f /tmp/agents-md-unread ;; esac; exit 0"
   ```

   Key changes:
   - `jq -r '.tool_input.file_path // empty'` — returns empty string instead of `null` when the key is absent.
   - `[ -z "$FP" ] && exit 0` — early exit when stdin was empty/unparseable; allows all tools through rather than blocking them.

6. **Commit the settings change** on a branch and open a PR.

## Concrete examples

### Example 1: diagnosis with only Read available (2026-05-25 session)

```
# Tool call: Read /tmp/agents-md-unread
# Result: file exists, 1 line (created by touch in SessionStart hook)
# → Flag is present

# Tool call: Read ~/.claude/settings.json
# Result: PostToolUse command has jq -r '.tool_input.file_path' — no null guard
# → Root cause confirmed

# AskUserQuestion: explain the issue, request rm -f /tmp/agents-md-unread
# User runs the command
# Tool call: Bash echo test → succeeds
# → Unblocked
```

### Example 2: permanent fix applied to settings.json

Before:
```json
"command": "INPUT=$(cat); FP=$(echo \"$INPUT\" | jq -r '.tool_input.file_path'); case \"$FP\" in */AGENTS.md|AGENTS.md) rm -f /tmp/agents-md-unread ;; esac; exit 0"
```

After:
```json
"command": "INPUT=$(cat); FP=$(echo \"$INPUT\" | jq -r '.tool_input.file_path // empty'); [ -z \"$FP\" ] && exit 0; case \"$FP\" in */AGENTS.md|AGENTS.md) rm -f /tmp/agents-md-unread ;; esac; exit 0"
```

## Anti-patterns

- **Re-reading AGENTS.md repeatedly hoping the hook will fire.** The hook receives empty stdin regardless of how many times AGENTS.md is read. More reads don't help. Diagnose instead.
- **Assuming it's a permissions issue.** The BLOCKED message looks like a permissions denial, but the root cause is a file-system flag, not a Claude permission setting.
- **Waiting for the user to figure it out.** Explain the root cause clearly with AskUserQuestion so the user knows exactly what command to run. Don't leave them guessing.
- **Skipping the permanent fix.** Clearing the flag with `rm` is a one-session workaround. The next compact session will hit the same problem unless the hook is patched.

## Acceptance criteria

- [ ] Root cause confirmed: `jq -r '.tool_input.file_path'` without null guard in `~/.claude/settings.json`
- [ ] Immediate workaround communicated: user given the exact `rm -f /tmp/agents-md-unread` command
- [ ] Tools unblocked: `Bash echo test` succeeds after flag removal
- [ ] Permanent fix applied: `~/.claude/settings.json` PostToolUse command uses `// empty` + early-exit guard
- [ ] Fix committed on a branch and PR opened

## Files this skill creates / modifies

- `~/.claude/settings.json` — PostToolUse hook command patched with null guard
