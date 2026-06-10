#!/usr/bin/env bash
# Lint: no committed "next-session prompt" files.
#
# A runnable-looking agent prompt committed to the tree is a foot-gun: a
# future agent finds it, mistakes it for its current instructions, and
# executes work nobody asked for. Incident: auto-014 committed
# `ai/next-session-prompt-auto-015.md`; the owner flagged and deleted it
# (archived AGENTS v1 §6.38; ai/LESSONS.md L19). Durable cross-session state
# belongs in ai/handoff.md and docs/open-issues.md; prompts are printed in
# chat, never committed.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

echo "test_no_next_session_prompt_files"

# Filename-shape check across all tracked files (archives included — the
# foot-gun works wherever the file sits; historical *references* in retro
# text are fine, committed prompt FILES are not).
HITS=$(git ls-files | grep -iE '(next-session-prompt|kickoff-prompt|paste-this-to-start)' || true)

if [ -z "$HITS" ]; then
  _pass "no committed next-session/kickoff prompt files"
else
  while IFS= read -r f; do
    _fail "committed prompt file: $f" \
      "delete it; print prompts in chat (ai/LESSONS.md L19). State goes to ai/handoff.md / docs/open-issues.md."
  done <<< "$HITS"
fi

assert_summary
