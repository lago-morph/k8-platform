#!/usr/bin/env bash
# AWS Resource Groups Tagging service has a strict character whitelist for tag
# values. Em-dash (U+2014) and other non-ASCII chars are rejected with
# `InvalidRequestException: Request rejected by the downstream tagging
# service. Please check that you're only using allowed characters.`
#
# Crossplane v2 propagates the XR's `spec.description` field into
# `spec.forProvider.tags.Description` on the underlying AWS MR. If a
# chainsaw scenario or example XR uses an em-dash in `description:`,
# AWS rejects the CreateSecret call, the MR never reaches Ready, and
# the scenario times out (245s @ chainsaw run 26544123347).
#
# This test scans every `description:` field in chainsaw scenarios and
# example XRs and asserts pure-ASCII content. It is the regression test
# for the bug surfaced by chainsaw run 26544123347 against
# `claude/v2-exec-hotfix-xrd-connsec` @ `6a47acf`.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

# Files whose `description:` values flow into AWS tags via the
# PlatformSecret Composition's `tags.Description` patch.
FILES=$(
  find tests/chainsaw/platform-secret \
       crossplane/claims \
       -name '*.yaml' -type f 2>/dev/null | sort
)

if [ -z "$FILES" ]; then
  _fail "files_discovered" "no chainsaw scenario or example claim YAMLs found"
  assert_summary; exit 1
fi
_pass "files_discovered ($(echo "$FILES" | wc -l | tr -d ' ') file(s))"

# AWS allows the following characters in tag values:
#   A-Z a-z 0-9 space . : / = + - _ @
# We assert: only ASCII printable + space + tab.
# A simpler shape: scan `description: "..."` values for any byte > 0x7F.
while IFS= read -r f; do
  # Extract the value of any `description:` field. The form in chainsaw
  # scenarios is:
  #   description: "..."
  #   or:
  #   description: ...
  bad=$(grep -nE '^\s*description:' "$f" \
        | LC_ALL=C grep -nP '[\x80-\xff]' \
        || true)
  if [ -n "$bad" ]; then
    _fail "ascii_tag_value_${f}" "non-ASCII characters found in 'description:' field of $f — AWS Tagging service will reject. Lines: $(echo "$bad" | head -3 | tr '\n' '|')"
  else
    _pass "ascii_tag_value_${f}"
  fi
done <<< "$FILES"

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
