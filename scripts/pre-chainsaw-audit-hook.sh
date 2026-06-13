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

# Filter: only run for mcp__*__execute calls that are a workflow_dispatch
# of chainsaw.yml. Read-only queries (list_workflow_runs,
# list_jobs_for_workflow_run, download_job_logs) also reference
# chainsaw.yml in their tool_input but do not provision anything, so the
# audit must NOT block them. Two dispatch transports are recognized:
#   * the jentic catalog execute (operation_uuid `op_2acb005c9f3704ad` for
#     actions/create-workflow-dispatch, verified 2026-05-23 per
#     .claude/skills/ext-github/resources/workflow_dispatch.json); and
#   * the attached GitHub MCP server's `mcp__github__actions_run_trigger`
#     with method `run_workflow` (the transport this repo's sessions
#     actually use — added 2026-06-13).
if ! printf '%s' "$input" | jq -e '
  (.tool_name // "") as $name
  | (.tool_input // {}) as $i
  | (   ($name | test("^mcp__.*__execute$"))
        and ($i | tostring | test("op_2acb005c9f3704ad"))
        and ($i | tostring | test("chainsaw\\.yml")) )
    or
    (   ($name == "mcp__github__actions_run_trigger")
        and (($i.method // "") == "run_workflow")
        and (($i.workflow_id // "") | test("chainsaw")) )
' >/dev/null 2>&1; then
  exit 0
fi

# Resolve repo root so the audit script can find its scan paths. The
# hook runs with cwd set by Claude Code; $CLAUDE_PROJECT_DIR is the
# documented contract for the project root.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# --- commit_sha validation (retro 2026-06-12-236 Proposal 1) --------------
# The chainsaw-verify gate matches a green run's head_sha to the PR HEAD
# EXACTLY. A dispatch carrying a mistyped/hallucinated commit_sha fires a
# run against a commit the verifier will never match — no error, just a
# gate that can never go green (this session burned a cancel+re-dispatch on
# exactly that: `b3f0363c2f0c…` typed for `b3f0363c33c…`). Catch it before
# the dispatch leaves: a commit_sha input must be a full 40-hex SHA that
# resolves to a commit the sandbox can see. Pure-local on purpose — a
# blocking hook must stay fast and deterministic, and a SHA the sandbox
# can't resolve is almost always a typo; "push/fetch it first" is the right
# advice either way. (A dispatch with no commit_sha is legal — non-verifier
# runs — so only validate when present.)
DISPATCH_SHA=$(printf '%s' "$input" | jq -r '
  [ .tool_input | .. | .commit_sha? // empty ]
  | map(select(type == "string" and . != "")) | first // ""' 2>/dev/null)
if [ -n "$DISPATCH_SHA" ]; then
  if ! printf '%s' "$DISPATCH_SHA" | grep -qE '^[0-9a-f]{40}$'; then
    echo "ERROR: chainsaw dispatch commit_sha '$DISPATCH_SHA' is not a full 40-hex SHA." >&2
    echo "The chainsaw-verify gate matches head_sha exactly — pass the full HEAD SHA (git rev-parse HEAD), not an abbreviation or branch name." >&2
    exit 2
  fi
  if ! git cat-file -e "${DISPATCH_SHA}^{commit}" 2>/dev/null; then
    echo "ERROR: chainsaw dispatch commit_sha '$DISPATCH_SHA' does not resolve to a commit the sandbox can see." >&2
    echo "Almost always a typo. Finalize + push the commit, confirm 'git rev-parse HEAD', then dispatch that exact SHA (the verifier will never match a commit that does not exist)." >&2
    exit 2
  fi
fi

echo "── pre-chainsaw-audit-hook: chainsaw.yml dispatch detected; running scripts/pre-chainsaw-audit.sh ──" >&2

if bash scripts/pre-chainsaw-audit.sh >&2; then
  exit 0
fi

echo >&2
echo "ERROR: scripts/pre-chainsaw-audit.sh failed — blocking chainsaw dispatch." >&2
echo "Per AGENTS.md §6.13, fix the flagged issues before re-dispatching." >&2
exit 2
