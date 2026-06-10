#!/usr/bin/env bash
# SPEC-B5: fail on 12-digit AWS-account-ID-shaped literals in tracked source.
#
# AGENTS.md ("never hardcode account-derived values" — archived v1 §8.1) is
# mechanically enforced here: the AWS test account rotates between sessions,
# so a committed account ID is a stale lie the next session pays to discover.
# Design doc: ai/brainstorming/specs/SPEC-B5-account-id-hardcode-lint.md
# Lessons register: ai/LESSONS.md L9.
#
# Exemption (inline, same line, reason required):
#   # noqa: account-id - <reason>     (also //, <!-- ... --> forms)
#
# Documented deviations from SPEC-B5 as written:
#   * `123456789012` (the canonical AWS documentation dummy) is globally
#     exempt: JSON/YAML test fixtures cannot carry comment markers.
#   * 12-digit literals with >=8 leading zeros (000000000000-style render-
#     fixture dummies) are exempt for the same reason.
#   * Historical/archived trees are out of scope (they are durable records,
#     like git history per SPEC-B5 §3): ai/brainstorming/, ai/archive/,
#     ai/crossplane-v1-v2-un-fuckify/, docs/archive/, and the grandfathered
#     root session artifacts (run-summary*, overnight-summary, handoff-
#     followups*, run-envelope*). retrospective/, forensics/, logs/ and
#     summary/ were never in SPEC-B5's scan scope.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

ID_RE='\b[0-9]{12}\b'
MARKER_RE='[Nn][Oo][Qq][Aa]:[[:space:]]*account-id'
FIXDIR="tests/unit/fixtures/account_id_lint"

# classify_line <line-content>
#   prints: OK | VIOLATION | NO_REASON
classify_line() {
  local line="$1"
  if printf '%s' "$line" | grep -qE "$MARKER_RE"; then
    # Reason = text after the marker's dash, minus an HTML-comment close.
    local reason
    reason=$(printf '%s' "$line" \
      | sed -E "s/.*${MARKER_RE}[[:space:]]*-?[[:space:]]*//; s/-->.*$//")
    if printf '%s' "$reason" | grep -q '[A-Za-z]'; then
      echo OK
    else
      echo NO_REASON
    fi
    return
  fi
  # UUID tails (8-4-4-4-12 with an all-digit last segment) are not account
  # IDs — strip whole UUIDs before tokenizing.
  local stripped
  stripped=$(printf '%s' "$line" | sed -E \
    's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}//g')
  # All matched tokens must be exempt dummies for the line to pass.
  local tok
  while IFS= read -r tok; do
    case "$tok" in
      123456789012) continue ;;            # canonical AWS docs dummy
      00000000*)    continue ;;            # render-fixture dummy convention
      *) echo VIOLATION; return ;;
    esac
  done < <(printf '%s' "$stripped" | grep -oE "$ID_RE")
  echo OK
}

# scan_findings  — emits "file:lineno:CLASS" for every non-OK match line
# in the real repo scope.
scan_findings() {
  git grep -nE "$ID_RE" -- \
    ai terraform crossplane argocd scripts tests .github docs clusters \
    platform-services ':(glob)*' \
    ':(exclude)ai/brainstorming/**' \
    ':(exclude)ai/archive/**' \
    ':(exclude)ai/crossplane-v1-v2-un-fuckify/**' \
    ':(exclude)docs/archive/**' \
    ':(exclude)'"$FIXDIR"'/**' \
    ':(exclude)run-summary*.md' \
    ':(exclude)overnight-summary.md' \
    ':(exclude)handoff-followups-*.md' \
    ':(exclude)run-envelope-*.md' \
    2>/dev/null \
  | while IFS= read -r hit; do
      local file="${hit%%:*}" rest="${hit#*:}"
      local lineno="${rest%%:*}" content="${rest#*:}"
      local class
      class=$(classify_line "$content")
      [ "$class" = "OK" ] || echo "${file}:${lineno}:${class}"
    done
}

# fixture_findings <fixture-file> — count of non-OK lines in one fixture
fixture_findings() {
  local f="$1" n=0 line class
  while IFS= read -r line; do
    class=$(classify_line "$line")
    [ "$class" = "OK" ] || n=$((n + 1))
  done < "$f"
  echo "$n"
}

echo "test_no_account_id_hardcoded (SPEC-B5)"

# --- self-test first: a broken regex matters more than the scan result -----
assert_eq "selftest: bare 12-digit ID flagged" \
  "1" "$(fixture_findings "$FIXDIR/should_fail_bare_id.txt")"
assert_eq "selftest: ID embedded in FQDN flagged (handoff regression)" \
  "1" "$(fixture_findings "$FIXDIR/should_fail_in_fqdn.txt")"
assert_eq "selftest: noqa marker with reason passes" \
  "0" "$(fixture_findings "$FIXDIR/should_pass_allowlisted.txt")"
assert_eq "selftest: timestamps/ports/SHAs not flagged" \
  "0" "$(fixture_findings "$FIXDIR/should_pass_non_id_digits.txt")"
assert_eq "selftest: dummy-zeros + canonical dummy not flagged" \
  "0" "$(fixture_findings "$FIXDIR/should_pass_dummy_ids.txt")"
assert_eq "selftest: marker without a reason is itself a failure" \
  "1" "$(fixture_findings "$FIXDIR/should_fail_marker_no_reason.txt")"

if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "self-test failed — not scanning the repo with a broken classifier"
  assert_summary
fi

[ "${1:-}" = "--self-test" ] && assert_summary

# --- real-repo scan ---------------------------------------------------------
FINDINGS=$(scan_findings)
if [ -z "$FINDINGS" ]; then
  _pass "repo scan: no hardcoded account-id-shaped literals"
else
  while IFS= read -r f; do
    case "$f" in
      *:NO_REASON)
        _fail "repo scan: ${f%:*}" \
          "noqa: account-id marker present but reason missing — add '- <reason>'" ;;
      *)
        _fail "repo scan: ${f%:*}" \
          "hardcoded 12-digit account-id-shaped literal. The account rotates (ai/environment.md §1). Remove it, use discovery (data sources / variables / outputs), or append: # noqa: account-id - <reason>. See SPEC-B5." ;;
    esac
  done <<< "$FINDINGS"
fi

assert_summary
