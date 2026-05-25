#!/usr/bin/env bash
# SPEC-C4 §7.1.2 unit-test.
#
# Every golden file under tests/chainsaw/**/expected/*.yaml MUST NOT
# contain any of the volatile fields chainsaw cannot reliably match:
#
#   uid:, resourceVersion:, creationTimestamp:, managedFields:,
#   ownerReferences:
#
# These fields drift per run (UID-derived names, timestamps, owner refs
# with random suffixes — see SPEC-C4 §5 "Handling fields with random /
# timestamp / UID-derived values"). A golden that includes any of them
# will silently flake.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

GOLDENS=$(find tests/chainsaw -path '*/expected/*.yaml' -type f | sort)

if [ -z "$GOLDENS" ]; then
  _fail "goldens_discovered" "no goldens found under tests/chainsaw/**/expected/"
  assert_summary; exit 1
fi
COUNT=$(echo "$GOLDENS" | wc -l | tr -d ' ')
_pass "goldens_discovered (${COUNT} file(s))"

# Volatile field markers — match at the start of a line (possibly indented)
# followed by the field name and a colon. Comments are exempt.
VOLATILE_RE='^[[:space:]]*(uid|resourceVersion|creationTimestamp|managedFields|ownerReferences):'

while IFS= read -r f; do
  # Strip comments before scanning (a `# uid: ...` comment is fine).
  bad=$(sed 's/#.*$//' "$f" | grep -En "$VOLATILE_RE" || true)
  if [ -n "$bad" ]; then
    _fail "no_volatile_fields_${f}" "found volatile fields in $f: $(echo "$bad" | tr '\n' '|')"
  else
    _pass "no_volatile_fields_${f}"
  fi
done <<< "$GOLDENS"

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
