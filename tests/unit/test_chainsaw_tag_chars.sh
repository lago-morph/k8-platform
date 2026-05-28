#!/usr/bin/env bash
# AWS Resource Groups Tagging service has a strict character whitelist for tag
# values. Em-dash (U+2014) and other non-ASCII chars are rejected with
# `InvalidRequestException: Request rejected by the downstream tagging
# service. Please check that you're only using allowed characters.`
#
# Crossplane v2 propagates the XR's `spec.description` field into
# `spec.forProvider.tags.Description` on the underlying AWS MR. If a
# chainsaw scenario, golden file, example XR, or render-fixture probe
# XR uses an em-dash in a `description:` (XR-level) or `Description:`
# (golden tag-value) field, AWS rejects the CreateSecret call, the MR
# never reaches Ready, and the scenario times out.
#
# This test scans every file that could contribute a tag-bound value
# to AWS and asserts pure-ASCII content in those fields. It is the
# regression test for the bug surfaced by chainsaw run 26544123347
# (auto-003 Strike 1) and the golden-content drift surfaced by run
# 26547209612 (auto-003 Strike 4).
#
# Scoped directories:
#   - tests/chainsaw/                       (scenarios, _meta, _smoke, goldens — recursively)
#   - crossplane/claims/                    (example XRs and the live PlatformCluster claim)
#   - crossplane/xrds/*/render-fixtures/    (render-fixture probe XRs)

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

FILES=$(
  {
    find tests/chainsaw -name '*.yaml' -type f 2>/dev/null
    find crossplane/claims -name '*.yaml' -type f 2>/dev/null
    find crossplane/xrds -path '*/render-fixtures/*.yaml' -type f 2>/dev/null
  } | sort -u
)

if [ -z "$FILES" ]; then
  _fail "files_discovered" "no chainsaw / claim / render-fixture YAMLs found"
  assert_summary; exit 1
fi
_pass "files_discovered ($(echo "$FILES" | wc -l | tr -d ' ') file(s))"

# Tag-bound field markers. Match the YAML key + value on the same line:
#   description: "<value>"     — XR-level tag value
#   Description: "<value>"     — direct golden tag value
# We strip YAML comments before scanning so a comment containing an
# em-dash (the documentation case) is not a violation.
TAG_FIELD_RE='^[[:space:]]*(description|Description):[[:space:]]+'

while IFS= read -r f; do
  # Strip comments before scanning. A line like:
  #   description: "good"  # comment with em-dash —
  # is OK; the comment never reaches AWS.
  bad=$(sed 's/#.*$//' "$f" \
        | grep -nE "$TAG_FIELD_RE" \
        | LC_ALL=C grep -nP '[\x80-\xff]' \
        || true)
  if [ -n "$bad" ]; then
    _fail "ascii_tag_value_${f}" \
      "non-ASCII characters found in 'description:' / 'Description:' tag-bound field of $f — AWS Tagging service will reject. Lines: $(echo "$bad" | head -3 | tr '\n' '|')"
  else
    _pass "ascii_tag_value_${f}"
  fi
done <<< "$FILES"

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
