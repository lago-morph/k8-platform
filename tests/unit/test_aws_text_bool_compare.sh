#!/usr/bin/env bash
# Lint: never compare an `aws … --output text` boolean to a lowercase literal.
#
# Red-first origin (retro 2026-06-12-236 Proposal 3 / PR #235): the RDS live
# check asked AWS "is this instance in the default VPC?" via
# `--output text` (which prints Python-capitalized `False`/`True`) and compared
# the result to lowercase `"false"`. The compare never matched, so a
# correctly base-VPC-placed instance was reported as the default-VPC bug — a
# green thing reported red, the worst kind of oracle failure.
#
# Precise, low-false-positive dataflow check (per file): a variable assigned
# from `$(aws … --output text …)` is "tainted" UNLESS the substitution
# normalizes case (`tr`, `,,`/`^^`, or `--output json | jq`). A tainted
# variable compared case-sensitively to a lowercase `true`/`false` literal is
# the bug. The fix (add `| tr '[:upper:]' '[:lower:]'` to the capture, or use
# `--output json | jq`) clears the taint and the lint passes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

ROOT="$HERE/../.."
cd "$ROOT"

if [ "$#" -ge 1 ]; then
  FILES=$(find "$1" -name '*.sh' 2>/dev/null | sort)
else
  FILES=$(git ls-files 'scripts/**/*.sh' 'tests/**/*.sh')
fi
[ -n "$FILES" ] || { fail "files_discovered" "no shell files in scope"; summary; }

VIOLATIONS=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue

  # Pass 1: collect tainted variable names — assigned from an aws --output
  # text capture that is NOT case-normalized in the same substitution.
  tainted=" "
  while IFS= read -r line; do
    case "$line" in
      *aws*--output' 'text*|*aws*--output=text*) : ;;
      *) continue ;;
    esac
    # case-normalized in the same capture? then it is safe.
    case "$line" in
      *' tr '*|*',,}'*|*'^^}'*|*'--output json'*|*'--output=json'*) continue ;;
    esac
    # extract an assigned var name:  name="$(... | name=$(...
    var=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p')
    [ -n "$var" ] && tainted="${tainted}${var} "
  done < "$f"

  [ "$tainted" = " " ] && continue

  # Pass 2: flag any tainted var compared case-sensitively to true/false.
  while IFS= read -r line; do
    for var in $tainted; do
      case "$line" in
        *"\"\$$var\""*|*"\$$var"*) : ;;
        *) continue ;;
      esac
      case "$line" in
        *'= "true"'*|*'= "false"'*|*'!= "true"'*|*'!= "false"'*|\
        *'== "true"'*|*'== "false"'*|*'= true'*|*'= false'*|*'!= true'*|*'!= false'*)
          fail "aws_text_bool ($f: \$$var)" "compared an 'aws --output text' boolean to a lowercase literal — capitalize-safe it (| tr '[:upper:]' '[:lower:]' or --output json | jq): ${line# }"
          VIOLATIONS=$((VIOLATIONS + 1)) ;;
      esac
    done
  done < "$f"
done < <(printf '%s\n' "$FILES")

[ "$VIOLATIONS" -eq 0 ] && pass "no aws --output text boolean compared to a lowercase literal"

summary
