#!/usr/bin/env bash
# Parse and validate .trigger-action.json.
#
# Usage:
#   parse-trigger.sh <path-to-json>
#
# Output:
#   On success: prints `phase=<v>` and `action=<v>` to stdout (one per line),
#   suitable for appending to $GITHUB_OUTPUT. Exits 0.
#   On failure: prints a human error to stderr, plus an `::error file=...`
#   annotation for GitHub Actions surface. Exits non-zero.
#
# Validation rules (must match ai/testing-guidelines.md §8):
#   phase ∈ {base, management, test}
#   action ∈
#     {plan, apply, verify, apply-and-verify, destroy}   when phase ∈ {base, management}
#     {test-unit, test-e2e}                              when phase = test
#   nonce is informational and not validated.
#
# This script is shared by:
#   - .github/workflows/agent-trigger.yml (the live trigger)
#   - tests/unit/test_parse_trigger.sh    (unit tests)
# Keep it dependency-light: bash + jq only.

set -euo pipefail

FILE="${1:-.trigger-action.json}"

err() {
  echo "::error file=${FILE}::$1" >&2
  echo "parse-trigger: $1" >&2
}

if [ ! -f "$FILE" ]; then
  err "trigger file not present at $FILE"
  exit 1
fi

if ! jq -e . "$FILE" >/dev/null 2>&1; then
  err "not valid JSON"
  exit 1
fi

PHASE=$(jq -r '.phase // empty' "$FILE")
ACTION=$(jq -r '.action // empty' "$FILE")

if [ -z "$PHASE" ]; then
  err "missing required field: phase"
  exit 1
fi

if [ -z "$ACTION" ]; then
  err "missing required field: action"
  exit 1
fi

case "$PHASE" in
  base|management|test) ;;
  *)
    err "invalid phase '$PHASE' (must be base|management|test)"
    exit 1 ;;
esac

case "$PHASE" in
  base|management)
    case "$ACTION" in
      plan|apply|verify|apply-and-verify|destroy) ;;
      *)
        err "invalid action '$ACTION' for phase '$PHASE' (must be plan|apply|verify|apply-and-verify|destroy)"
        exit 1 ;;
    esac
    ;;
  test)
    case "$ACTION" in
      test-unit|test-e2e) ;;
      *)
        err "invalid action '$ACTION' for phase 'test' (must be test-unit|test-e2e)"
        exit 1 ;;
    esac
    ;;
esac

echo "phase=$PHASE"
echo "action=$ACTION"
