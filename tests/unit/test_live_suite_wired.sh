#!/usr/bin/env bash
# Static "wired / gating / scoped" lint over .github/workflows/terraform-test.yml
# (FINAL-PLAN §4.2 auto-013; burndown item 4). The live behavioral suite is only
# valuable if CI actually RUNS it, lets its exit code FAIL the build, and runs it
# under the scoped verifier/reaper role (not the admin job creds). This lint makes
# all three mechanical so a future edit can't silently un-wire / neuter / privilege
# the live step without going RED here (the push/PR floor; ADR-0006).

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

WF=".github/workflows/terraform-test.yml"

if [ ! -f "$WF" ]; then
  _fail "workflow_present" "missing $WF"
  assert_summary
fi

WF_TEXT="$(cat "$WF")"

# 1. WIRED — the apply-and-verify path invokes the live orchestrator.
if printf '%s' "$WF_TEXT" | grep -qE 'tests/live/run\.sh'; then
  _pass "wired (terraform-test.yml invokes tests/live/run.sh)"
else
  _fail "wired" "terraform-test.yml does not invoke tests/live/run.sh — the live suite is not run in CI"
fi

# 2. GATING — build success is a function of run.sh's exit code.
#    Forbid neutralizing the invocation with `|| true` or backgrounding `&`.
if printf '%s' "$WF_TEXT" | grep -E 'tests/live/run\.sh' | grep -qE '\|\|[[:space:]]*true|&[[:space:]]*$'; then
  _fail "gating_no_swallow" "the tests/live/run.sh invocation is neutralized (|| true / backgrounded &) — its RED can't fail the build"
else
  _pass "gating (run.sh exit code is not swallowed)"
fi

# 2b. GATING — no global silent kill-switch.
if printf '%s' "$WF_TEXT" | grep -qE '^\s*if:\s*false\b'; then
  _fail "gating_no_kill_switch" "workflow contains 'if: false' — a step is silently disabled"
else
  _pass "gating (no 'if: false' kill-switch)"
fi

# 3. SCOPED — the live suite runs under the assumed verifier/reaper role (with the
#    required live-verify session tag), NOT the admin job creds. We assert the
#    scoped-assume is present rather than trying to lexically bound the step.
if printf '%s' "$WF_TEXT" | grep -qE 'sts[[:space:]]+assume-role' \
   && printf '%s' "$WF_TEXT" | grep -qE 'live-verify'; then
  _pass "scoped (live suite assumes the verifier/reaper role with a live-verify tag)"
else
  _fail "scoped" "no 'aws sts assume-role ... live-verify' — the live step must run under the scoped role, not admin creds"
fi

assert_summary
