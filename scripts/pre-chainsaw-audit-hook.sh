#!/usr/bin/env bash
# pre-chainsaw-audit-hook.sh — Claude Code PreToolUse hook wrapper for
# scripts/pre-chainsaw-audit.sh. Wired in .claude/settings.json so the
# audit fires automatically before any agent-initiated chainsaw dispatch.
#
# Reads the hook input JSON on stdin. Filters to mcp__*__execute tool
# calls whose tool_input references "chainsaw.yml" (typically
# workflow_id=chainsaw.yml in a GitHub Actions workflow_dispatch). For
# every other tool call, no-ops silently.
#
# On a chainsaw dispatch:
#   - runs scripts/pre-chainsaw-audit.sh
#   - exit 0 (audit clean) → hook returns 0; tool call proceeds
#   - exit non-zero (audit failed) → hook returns 2 with stderr
#     explaining why; Claude Code blocks the tool call and surfaces
#     the audit output to the agent
#
# Per AGENTS.md §6.13 / SKILL-SPEC-3a7d2e9f1c (pre-dispatch-static-audit).
# Skipping the audit is the recurring root cause of multi-iteration
# chainsaw CI loops (PR #111 burned four iterations).

set -uo pipefail

input=$(cat)

# Filter: only run for mcp__*__execute calls that mention chainsaw.yml
# anywhere in their tool_input payload. jq's `tostring` flattens the
# whole input subtree so we don't have to guess the param path the
# specific MCP server uses (workflow_id, ref, inputs.workflow_id, etc.).
if ! printf '%s' "$input" | jq -e '
  (.tool_name // "") as $name
  | (.tool_input // {}) as $i
  | ($name | test("^mcp__.*__execute$"))
    and ($i | tostring | test("chainsaw\\.yml"))
' >/dev/null 2>&1; then
  exit 0
fi

# Resolve repo root so the audit script can find its scan paths. The
# hook runs with cwd set by Claude Code; $CLAUDE_PROJECT_DIR is the
# documented contract for the project root.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

echo "── pre-chainsaw-audit-hook: chainsaw.yml dispatch detected; running scripts/pre-chainsaw-audit.sh ──" >&2

if bash scripts/pre-chainsaw-audit.sh >&2; then
  exit 0
fi

echo >&2
echo "ERROR: scripts/pre-chainsaw-audit.sh failed — blocking chainsaw dispatch." >&2
echo "Per AGENTS.md §6.13, fix the flagged issues before re-dispatching." >&2
exit 2
