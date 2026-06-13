#!/usr/bin/env bash
# Exercises the commit_sha guard + dual-transport detection added to
# scripts/pre-chainsaw-audit-hook.sh (retro 2026-06-12-236 Proposal 1).
#
# Feeds the hook crafted PreToolUse JSON on stdin and asserts the exit code:
#   0 = allow (tool proceeds), 2 = block. The guard runs BEFORE the static
# audit, so the malformed/nonexistent-SHA cases exit fast without touching
# the audit. The "valid SHA" case falls through to the real audit, which is
# green on the committed tree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool jq

ROOT="$(cd "$HERE/../.." && pwd)"
HOOK="$ROOT/scripts/pre-chainsaw-audit-hook.sh"
[ -f "$HOOK" ] || { fail "hook_present" "$HOOK missing"; summary; }

REAL_SHA="$(git -C "$ROOT" rev-parse HEAD)"
BOGUS_SHA="b3f0363c2f0cffffffffffffffffffffffffffff"   # 40-hex, no such commit
SHORT_SHA="b3f0363"                                     # abbreviation

run_hook() { # $1 = json ; echoes exit code
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" >/dev/null 2>&1
  echo $?
}

gh_dispatch() { # $1 = commit_sha (may be empty)
  jq -nc --arg sha "$1" '{
    tool_name: "mcp__github__actions_run_trigger",
    tool_input: { method: "run_workflow", owner: "lago-morph", repo: "k8s-platform",
                  workflow_id: "chainsaw.yml", ref: "some-branch",
                  inputs: ( if $sha == "" then {} else { commit_sha: $sha } end ) }
  }'
}

# 1. Non-chainsaw tool → never blocks.
rc=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}')
[ "$rc" = "0" ] && pass "non-chainsaw tool allowed" || fail "non-chainsaw tool allowed" "rc=$rc"

# 2. Read-only github query of chainsaw.yml (not run_workflow) → not blocked.
rc=$(run_hook '{"tool_name":"mcp__github__actions_run_trigger","tool_input":{"method":"rerun_failed_jobs","workflow_id":"chainsaw.yml"}}')
[ "$rc" = "0" ] && pass "non-dispatch chainsaw query allowed" || fail "non-dispatch chainsaw query allowed" "rc=$rc"

# 3. github dispatch with a bogus 40-hex SHA → BLOCK (the #235-neighbour bug).
rc=$(run_hook "$(gh_dispatch "$BOGUS_SHA")")
[ "$rc" = "2" ] && pass "bogus 40-hex commit_sha blocked" || fail "bogus 40-hex commit_sha blocked" "rc=$rc (want 2)"

# 4. github dispatch with an abbreviated SHA → BLOCK (verifier needs full head_sha).
rc=$(run_hook "$(gh_dispatch "$SHORT_SHA")")
[ "$rc" = "2" ] && pass "abbreviated commit_sha blocked" || fail "abbreviated commit_sha blocked" "rc=$rc (want 2)"

# 5. github dispatch with the real HEAD SHA → guard passes; audit runs green.
rc=$(run_hook "$(gh_dispatch "$REAL_SHA")")
[ "$rc" = "0" ] && pass "real HEAD commit_sha allowed (audit green)" || fail "real HEAD commit_sha allowed" "rc=$rc (want 0)"

# 6. github dispatch with NO commit_sha → legal (non-verifier run); audit runs green.
rc=$(run_hook "$(gh_dispatch "")")
[ "$rc" = "0" ] && pass "dispatch without commit_sha allowed" || fail "dispatch without commit_sha allowed" "rc=$rc (want 0)"

summary
