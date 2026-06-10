#!/usr/bin/env bash
# Lint: the repository root stays clean — new top-level files must be on the
# allowlist below.
#
# Forensics D3/D10: 16 ephemeral session artifacts accumulated at the repo
# root (run summaries, envelopes, follow-ups), creating contradictory belief
# states for fresh sessions ("which file is canonical?"). This lint freezes
# the grandfathered set and blocks NEW root clutter; session artifacts belong
# in their proper homes (ai/handoff.md, retrospective/, docs/).
# Lessons register: ai/LESSONS.md L17/L25; cleanup of the grandfathered set
# is structural item S6.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

echo "test_root_file_allowlist"

# Canonical root files.
ALLOW="
.gitignore
.pre-commit-config.yaml
AGENTS.md
CLAUDE.md
README.md
SUBSTRATE-READINESS.md
versions.env
"

# Grandfathered session artifacts (forensic exhibits — read-only, do NOT add
# to this list; relocation tracked as ai/LESSONS.md S6).
GRANDFATHERED="
handoff-followups-2026-05-28.md
overnight-summary.md
run-envelope-auto-016.md
run-summary-2026-05-25.md
run-summary-2026-05-26.md
run-summary-2026-05-28.md
run-summary-auto-009.md
run-summary-auto-010.md
run-summary-auto-011.md
run-summary-auto-012.md
run-summary-auto-013.md
run-summary-auto-014.md
run-summary-auto-015.md
run-summary-auto-016.md
run-summary.md
"

VIOLATIONS=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if ! printf '%s' "$ALLOW" | grep -qxF "$f" \
     && ! printf '%s' "$GRANDFATHERED" | grep -qxF "$f"; then
    VIOLATIONS="${VIOLATIONS}${f}
"
  fi
done < <(git ls-files ':(glob)*')

if [ -z "$VIOLATIONS" ]; then
  _pass "repo root contains only allowlisted files"
else
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    _fail "unexpected root file: $f" \
      "root is frozen (ai/LESSONS.md L25). Put docs in docs/ or ai/, session state in ai/handoff.md, retros in retrospective/ — or, if genuinely canonical, add it to ALLOW in this test with justification in the PR."
  done <<< "$VIOLATIONS"
fi

assert_summary
