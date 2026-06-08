#!/usr/bin/env bash
# Burndown item 5 backstop: catch ADR-number collisions at PR time.
#
# docs/decisions/ uses sequential NNNN- prefixes. When a session clones
# stale (before main gained a new ADR) it can pick a number already taken on
# main — the collision that "cost real time" (testing-debt-burndown item 5).
# The primary prevention is the session-start fetch-and-warn (.claude/hooks/
# session-start.sh); THIS lint is the fail-closed backstop: it fails if two
# committed ADRs share a number or a file is mis-named, so a slipped-through
# collision goes RED in CI instead of landing silently.
#
# Helper for authors: scripts/next-adr-number.sh prints the next free number.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

ADR_DIR="docs/decisions"

if [ ! -d "$ADR_DIR" ]; then
  _fail "adr_dir_present" "no $ADR_DIR directory"
  assert_summary
fi

# All ADR markdown files (README/index excluded — not numbered records).
ADR_FILES=$(find "$ADR_DIR" -maxdepth 1 -type f -name '*.md' \
  ! -iname 'README.md' ! -iname 'index.md' | sort)

if [ -z "$ADR_FILES" ]; then
  _fail "adr_files_present" "no ADR records found under $ADR_DIR"
  assert_summary
fi

# 1. Every ADR filename must match NNNN-<slug>.md (4-digit zero-padded prefix).
bad_names=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  base=$(basename "$f")
  case "$base" in
    [0-9][0-9][0-9][0-9]-*.md) : ;;   # ok
    *) bad_names="${bad_names}${base} " ;;
  esac
done <<EOF
$ADR_FILES
EOF

if [ -z "$bad_names" ]; then
  _pass "adr_filenames_well_formed (NNNN-<slug>.md)"
else
  _fail "adr_filenames_well_formed" "mis-named ADR file(s): ${bad_names}"
fi

# 2. No two ADRs may share a 4-digit number.
NUMS=$(printf '%s\n' "$ADR_FILES" | sed -n 's#.*/\([0-9][0-9][0-9][0-9]\)-.*#\1#p')
DUPS=$(printf '%s\n' "$NUMS" | sort | uniq -d)

if [ -z "$DUPS" ]; then
  COUNT=$(printf '%s\n' "$NUMS" | grep -c .)
  _pass "adr_numbers_unique (${COUNT} ADRs, no collisions)"
else
  # Name the colliding files for a fast fix.
  detail=""
  for n in $DUPS; do
    files=$(printf '%s\n' "$ADR_FILES" | grep "/${n}-" | tr '\n' ' ')
    detail="${detail}[${n}: ${files}] "
  done
  _fail "adr_numbers_unique" "duplicate ADR number(s): ${detail}-- run scripts/next-adr-number.sh"
fi

assert_summary
