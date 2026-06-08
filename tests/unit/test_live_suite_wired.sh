#!/usr/bin/env bash
# Static "wired / gating / scoped" lint for the live-suite evidence producer
# (FINAL-PLAN §4.2 auto-013; burndown item 4). The live behavioral suite is only
# valuable if CI actually RUNS it, lets its exit code FAIL the build, and runs it
# under the scoped verifier/reaper role (not the admin job creds). The producer
# is a dedicated workflow (.github/workflows/live-verify.yml, like chainsaw.yml)
# whose body is .github/scripts/live-verify-run.sh. This lint makes all three
# properties mechanical so a future edit can't silently un-wire / neuter /
# privilege the producer without going RED here (the push/PR floor; ADR-0006).

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

WF=".github/workflows/live-verify.yml"
BODY=".github/scripts/live-verify-run.sh"

for f in "$WF" "$BODY"; do
  [ -f "$f" ] || { _fail "present_$f" "missing $f"; assert_summary; }
done

WF_TEXT="$(cat "$WF")"
BODY_TEXT="$(cat "$BODY")"

# 1. WIRED — the workflow invokes the producer body, and the body invokes the
#    live orchestrator. Both links must exist or the suite never runs in CI.
if printf '%s' "$WF_TEXT" | grep -qE 'live-verify-run\.sh' \
   && printf '%s' "$BODY_TEXT" | grep -qE 'tests/live/run\.sh'; then
  _pass "wired (live-verify.yml -> live-verify-run.sh -> tests/live/run.sh)"
else
  _fail "wired" "the live suite is not invoked end-to-end (workflow -> body -> run.sh)"
fi

# 2. GATING — build success is a function of run.sh's exit code: the invocation
#    is not neutralized with `|| true` or backgrounded with `&`.
if printf '%s' "$BODY_TEXT" | grep -E 'tests/live/run\.sh' | grep -qE '\|\|[[:space:]]*true|&[[:space:]]*$'; then
  _fail "gating_no_swallow" "the tests/live/run.sh invocation is neutralized (|| true / backgrounded &)"
else
  _pass "gating (run.sh exit code is not swallowed)"
fi

# 2b. GATING — no silent kill-switch in the workflow.
if printf '%s' "$WF_TEXT" | grep -qE '^\s*if:\s*false\b'; then
  _fail "gating_no_kill_switch" "live-verify.yml contains 'if: false' — the producer is silently disabled"
else
  _pass "gating (no 'if: false' kill-switch)"
fi

# 3. SCOPED — the suite runs under the assumed verifier/reaper role WITH the
#    required live-verify session tag, NOT the admin job creds.
if printf '%s' "$BODY_TEXT" | grep -qE 'sts[[:space:]]+assume-role' \
   && printf '%s' "$BODY_TEXT" | grep -qE 'live-verify'; then
  _pass "scoped (producer assumes the verifier/reaper role with a live-verify tag)"
else
  _fail "scoped" "no 'aws sts assume-role ... live-verify' — the suite must run scoped, not as admin"
fi

assert_summary
