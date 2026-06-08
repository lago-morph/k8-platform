#!/usr/bin/env bash
# Print the next free ADR number for docs/decisions/ (zero-padded, 4 digits).
#
# Why this exists: ADR numbers are sequential, and a stale sandbox clone (or
# a number reserved in another OPEN PR) has caused collisions — see
# docs/testing-debt-burndown.md item 5. This helper removes the guesswork for
# the local tree; the duplicate-number lint (tests/unit/test_adr_numbering.sh)
# is the fail-closed backstop.
#
# IMPORTANT: `git fetch origin main` FIRST so you see numbers already merged,
# and check open PRs for a number reserved-but-not-yet-merged — neither the
# local `ls` nor this script can see an unmerged ADR in someone else's PR.
#
# Usage: scripts/next-adr-number.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ADR_DIR="docs/decisions"

highest=$(find "$ADR_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.md' \
  | sed -n 's#.*/\([0-9][0-9][0-9][0-9]\)-.*#\1#p' \
  | sort -n | tail -1)
highest=${highest:-0000}

# Strip leading zeros for arithmetic (force base-10), then re-pad.
next=$((10#${highest} + 1))
printf '%04d\n' "$next"

# Reminders to stderr so the number itself stays the only stdout line.
echo "  (highest committed locally: ${highest}. Did you 'git fetch origin main' first?" >&2
echo "   Also check OPEN PRs — a number can be reserved there but not yet merged.)" >&2
