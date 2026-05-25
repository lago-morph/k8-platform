#!/usr/bin/env bash
# 12_crossplane_trace_smoke.sh — live-cluster smoke test for scripts/crossplane-trace.sh.
#
# SKIPPED unless CROSSPLANE_TRACE_LIVE=1 — guards CI from accidentally
# running it against a clusterless environment.
#
# Contracts asserted (spec §7 integration):
#   1. exit 0 or 2 (never 1 — fail-soft per layer)
#   2. human-mode output ends with "=== END TRACE ==="
#   3. --json output parses with jq
#
# Spec: ai/brainstorming/specs/SPEC-S2-crossplane-trace.md

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

if [[ "${CROSSPLANE_TRACE_LIVE:-0}" != "1" ]]; then
  echo "12_crossplane_trace_smoke: SKIPPED — set CROSSPLANE_TRACE_LIVE=1 to run."
  exit 0
fi

SCRIPT="scripts/crossplane-trace.sh"
KIND_NAME="${TRACE_KIND_NAME:-PlatformSecret/smoke-claim}"
NS="${TRACE_NS:-default}"

echo "── live: human trace ──"
set +e
out=$(bash "$SCRIPT" "$KIND_NAME" -n "$NS" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 || "$rc" -eq 2 ]]; then
  _pass "smoke_exit_0_or_2"
else
  _fail "smoke_exit_0_or_2" "got rc=$rc"
fi
assert_contains "smoke_end_marker" "=== END TRACE ===" "$out"

echo "── live: --json trace ──"
set +e
json_out=$(bash "$SCRIPT" "$KIND_NAME" -n "$NS" --json 2>/dev/null)
set -e
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$json_out" | jq . >/dev/null 2>&1; then
    _pass "smoke_json_parses"
  else
    _fail "smoke_json_parses" "jq parse failed"
  fi
fi

assert_summary
