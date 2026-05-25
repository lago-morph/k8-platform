#!/usr/bin/env bash
# Unit tests for scripts/wait-for-claim.sh and scripts/_lib/k8s-helpers.sh.
#
# Tests use a mock `kubectl` shim (TMP_BIN/kubectl) that consults fixture
# files under tests/unit/fixtures/wait-for-claim/ and emits jsonpath /
# events output appropriate to the call. The script-under-test is invoked
# with KUBECTL=<shim> KUBECONFIG=/dev/null to ensure no real cluster is
# contacted.
#
# Contracts defended (spec §6 + §6.4 adversarial review):
#   1. exits 0 within one poll cycle on Ready=True
#   2. exits 1 on timeout AND stdout contains '=== TIMEOUT DUMP:'
#   3. dump contains 'conditions:' AND 'recent cluster events' sections
#   4. empty .status.conditions does NOT hang and prints
#      '(conditions unavailable)'
#   5. bash -n on both scripts/wait-for-claim.sh and
#      scripts/_lib/k8s-helpers.sh
#   6. neither file references $UID (PR #59 readonly-builtin class)
#   Plus adversarial-review additions:
#   7. POLL_INTERVAL=1 env override actually shortens poll
#   8. cluster-scoped path (NS="") does not pass -n flag
#   9. exact-equality on Ready=True — a value of "TrueFalse" must NOT
#      satisfy the wait (PR #67)
#  10. timeout dump body ≤ 3072 bytes
#  11. script exits non-zero even from a caller without `set -e`
#  12. shellcheck clean on both files (if shellcheck is on PATH; skipped
#      otherwise so the test stays portable to dev sandboxes)

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

FIXTURES="tests/unit/fixtures/wait-for-claim"
SCRIPT="scripts/wait-for-claim.sh"
LIB="scripts/_lib/k8s-helpers.sh"

# ---------------------------------------------------------------------------
# Mock kubectl
# ---------------------------------------------------------------------------
# The shim writes its argv to $MOCK_ARGS_LOG (one line per invocation) and
# responds based on:
#   - $MOCK_FIXTURE          path to a *.json claim fixture
#   - $MOCK_READY_AFTER_CALL switch to 'claim-ready.json' after this many
#                            get-condition calls (default: never)
#   - $MOCK_READY_VALUE      string to return for the Ready condition
#                            (overrides fixture; "TrueFalse" used to
#                            defend exact-equality)
# All other kubectl calls return empty success.

MOCK_DIR="$(mktemp -d -t wfc-mock-XXXXXX)"
trap 'rm -rf "$MOCK_DIR"' EXIT

cat > "$MOCK_DIR/kubectl" <<'SHIM'
#!/usr/bin/env bash
# Mock kubectl for test_wait_for_claim.sh
set -u

LOG="${MOCK_ARGS_LOG:-/dev/null}"
echo "$*" >> "$LOG"

# Increment per-call counter
COUNTER_FILE="${MOCK_COUNTER_FILE:-/dev/null}"
n=0
if [[ "$COUNTER_FILE" != "/dev/null" && -f "$COUNTER_FILE" ]]; then
  n=$(<"$COUNTER_FILE")
fi
n=$((n + 1))
if [[ "$COUNTER_FILE" != "/dev/null" ]]; then
  echo "$n" > "$COUNTER_FILE"
fi

fixture="${MOCK_FIXTURE:-}"
ready_after="${MOCK_READY_AFTER_CALL:-0}"
ready_override="${MOCK_READY_VALUE:-}"

# Decide effective fixture based on call number
if [[ "$ready_after" -gt 0 && "$n" -ge "$ready_after" ]]; then
  fixture="${MOCK_READY_FIXTURE:-tests/unit/fixtures/wait-for-claim/claim-ready.json}"
fi

# Parse what kubectl is being asked to do.
# We only care about:
#   get <kind>/<name> [-n <ns>] -o jsonpath=...
#   get events ...
# Everything else returns empty success.

mode=""
jsonpath=""
for arg in "$@"; do
  case "$arg" in
    get) mode="get" ;;
    events) mode="events" ;;
    -o) ;;
    jsonpath=*) jsonpath="${arg#jsonpath=}" ;;
  esac
done

# Inspect jsonpath to decide what to print
case "$jsonpath" in
  *'@.type=="Ready"'*)
    if [[ -n "$ready_override" ]]; then
      printf '%s' "$ready_override"
    else
      # Extract from fixture using python (always present in this repo's CI)
      python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for c in (d.get("status", {}) or {}).get("conditions", []) or []:
    if c.get("type") == "Ready":
        sys.stdout.write(c.get("status", ""))
        break
' "$fixture"
    fi
    exit 0
    ;;
  *'@.type=="Synced"'*)
    python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for c in (d.get("status", {}) or {}).get("conditions", []) or []:
    if c.get("type") == "Synced":
        sys.stdout.write(c.get("status", ""))
        break
' "$fixture"
    exit 0
    ;;
  *'spec.resourceRef.name'*)
    python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
ref = (d.get("spec", {}) or {}).get("resourceRef", {}) or {}
sys.stdout.write(ref.get("name", ""))
' "$fixture"
    exit 0
    ;;
  *'range .status.conditions'*)
    python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for c in (d.get("status", {}) or {}).get("conditions", []) or []:
    sys.stdout.write("  type=%s status=%s reason=%s msg=%s\n" % (
        c.get("type",""), c.get("status",""),
        c.get("reason",""), c.get("message","")))
' "$fixture"
    exit 0
    ;;
esac

# get events ... — emit a couple of fake event lines so the dump has body.
if [[ "$mode" == "events" ]]; then
  # Field-selector get-events for the XR or namespace events get the same
  # canned output here; the actual selector is recorded in the log for
  # assertions to inspect.
  cat <<'EVENTS'
2026-05-25T12:00:30Z Warning  FailedComposition  stuck-claim-abc34  cannot render composition: AccessDenied
2026-05-25T12:00:35Z Normal   Reconcile          stuck-claim-abc34  waiting for composite to become Ready
EVENTS
  exit 0
fi

# Default: silent success.
exit 0
SHIM
chmod +x "$MOCK_DIR/kubectl"

# Helper that invokes the script with the mock in place.
# Usage: run_script <fixture> [--ready-after N] [--ready-value V] -- <argv-to-script>
run_script() {
  local fixture="$1"; shift
  local ready_after=0 ready_value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ready-after) ready_after="$2"; shift 2 ;;
      --ready-value) ready_value="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  local args_log counter_file
  args_log=$(mktemp -p "$MOCK_DIR" args.XXXXXX)
  counter_file=$(mktemp -p "$MOCK_DIR" counter.XXXXXX)
  echo 0 > "$counter_file"
  MOCK_FIXTURE="$fixture" \
  MOCK_READY_AFTER_CALL="$ready_after" \
  MOCK_READY_VALUE="$ready_value" \
  MOCK_ARGS_LOG="$args_log" \
  MOCK_COUNTER_FILE="$counter_file" \
  KUBECTL="$MOCK_DIR/kubectl" \
  PATH="$MOCK_DIR:$PATH" \
    bash "$SCRIPT" "$@"
  local rc=$?
  # Stash log path for caller to inspect via $LAST_ARGS_LOG.
  LAST_ARGS_LOG="$args_log"
  return $rc
}

# ===========================================================================
# Test 1: Ready=True exits 0 within one poll cycle.
# ===========================================================================
echo "── test 1: exits 0 on Ready=True ──"
out=$(POLL_INTERVAL=1 run_script "$FIXTURES/claim-ready.json" -- \
        PlatformSecret ready-claim test-ns 10 2>&1)
rc=$?
assert_eq "ready_claim_exit_0" "0" "$rc"
assert_contains "ready_claim_output_marker" "Ready=True after" "$out"

# ===========================================================================
# Test 2: Not-ready times out, exits 1, dump header present.
# ===========================================================================
echo "── test 2: timeout exits 1, prints TIMEOUT DUMP header ──"
set +e
out=$(POLL_INTERVAL=1 run_script "$FIXTURES/claim-not-ready.json" -- \
        PlatformSecret stuck-claim test-ns 1 2>&1)
rc=$?
set -e
assert_eq "not_ready_exit_1" "1" "$rc"
assert_contains "not_ready_timeout_dump_header" \
  "=== TIMEOUT DUMP: PlatformSecret/stuck-claim ===" "$out"
assert_contains "not_ready_timeout_dump_footer" "=== END TIMEOUT DUMP ===" "$out"

# ===========================================================================
# Test 3: Dump contains conditions: AND recent cluster events sections.
# ===========================================================================
echo "── test 3: dump sections present ──"
assert_contains "dump_has_conditions_section" "conditions:" "$out"
assert_contains "dump_has_events_section" "recent cluster events" "$out"
assert_contains "dump_has_composition_events" "composition events" "$out"

# ===========================================================================
# Test 4: claim-no-conditions does not hang; emits (conditions unavailable).
# ===========================================================================
echo "── test 4: empty conditions does not hang ──"
set +e
# 3-second timeout in case the script ever loops on this fixture.
out=$(timeout 5 bash -c \
  'POLL_INTERVAL=1 MOCK_FIXTURE="'"$FIXTURES"'/claim-no-conditions.json" \
   MOCK_ARGS_LOG=/dev/null MOCK_COUNTER_FILE=/dev/null \
   KUBECTL="'"$MOCK_DIR"'/kubectl" PATH="'"$MOCK_DIR"':$PATH" \
   bash "'"$SCRIPT"'" PlatformSecret fresh-claim test-ns 1' 2>&1)
rc=$?
set -e
assert_eq "no_conditions_exit_1" "1" "$rc"
assert_contains "no_conditions_unavailable_msg" "(conditions unavailable)" "$out"

# ===========================================================================
# Test 5: bash -n on both files (syntax clean).
# ===========================================================================
echo "── test 5: bash -n syntax check ──"
if bash -n "$SCRIPT" 2>/dev/null; then
  _pass "syntax_clean_wait_for_claim"
else
  _fail "syntax_clean_wait_for_claim" "bash -n failed"
fi
if bash -n "$LIB" 2>/dev/null; then
  _pass "syntax_clean_k8s_helpers"
else
  _fail "syntax_clean_k8s_helpers" "bash -n failed"
fi

# ===========================================================================
# Test 6: No $UID reference in either file (PR #59 guard).
# ===========================================================================
echo "── test 6: no \$UID assignment in either file ──"
uid_hits=$(grep -nE '(\$\{?UID\}?|^[[:space:]]*UID=)' "$SCRIPT" "$LIB" || true)
if [[ -z "$uid_hits" ]]; then
  _pass "no_uid_reference"
else
  _fail "no_uid_reference" "found: $uid_hits"
fi

# ===========================================================================
# Test 7: POLL_INTERVAL=1 honored — script returns within ~2s on timeout=1.
# ===========================================================================
echo "── test 7: POLL_INTERVAL env override ──"
set +e
t_start=$(date +%s)
POLL_INTERVAL=1 run_script "$FIXTURES/claim-not-ready.json" -- \
  PlatformSecret stuck-claim test-ns 1 >/dev/null 2>&1
rc=$?
t_end=$(date +%s)
set -e
elapsed=$((t_end - t_start))
assert_eq "poll_interval_exit_1" "1" "$rc"
if [[ "$elapsed" -le 5 ]]; then
  _pass "poll_interval_under_5s"
else
  _fail "poll_interval_under_5s" "elapsed ${elapsed}s (expected ≤5s)"
fi

# ===========================================================================
# Test 8: Cluster-scoped path (NS="") does NOT pass -n flag.
# ===========================================================================
echo "── test 8: cluster-scoped path omits -n ──"
set +e
run_script "$FIXTURES/claim-not-ready.json" -- \
  Bucket some-bucket "" 1 >/dev/null 2>&1
set -e
# Grep the args log: any "get Bucket/some-bucket" invocation must NOT
# also contain " -n ".
if grep -E '^get Bucket/some-bucket' "$LAST_ARGS_LOG" | grep -q -- ' -n '; then
  _fail "cluster_scoped_no_ns_flag" "found -n in cluster-scoped call"
else
  _pass "cluster_scoped_no_ns_flag"
fi

# ===========================================================================
# Test 9: Exact-equality — "TrueFalse" Ready value must NOT satisfy.
# ===========================================================================
echo "── test 9: exact-equality on Ready=True ──"
set +e
out=$(POLL_INTERVAL=1 run_script "$FIXTURES/claim-not-ready.json" \
        --ready-value "TrueFalse" -- \
        PlatformSecret stuck-claim test-ns 1 2>&1)
rc=$?
set -e
assert_eq "true_substring_does_not_match" "1" "$rc"
assert_contains "true_substring_dump_emitted" "TIMEOUT DUMP" "$out"

# ===========================================================================
# Test 10: Timeout dump body ≤ 3072 bytes.
# ===========================================================================
echo "── test 10: dump body ≤ 3 KB ──"
set +e
out=$(POLL_INTERVAL=1 run_script "$FIXTURES/claim-not-ready.json" -- \
        PlatformSecret stuck-claim test-ns 1 2>&1)
set -e
# Extract just the dump block.
dump=$(printf '%s' "$out" | awk '/=== TIMEOUT DUMP:/,/=== END TIMEOUT DUMP ===/')
dump_bytes=${#dump}
if [[ "$dump_bytes" -le 3072 ]]; then
  _pass "dump_under_3kb"
else
  _fail "dump_under_3kb" "dump was $dump_bytes bytes (>3072)"
fi

# ===========================================================================
# Test 11: Caller without `set -e` still sees non-zero from `if !`.
# ===========================================================================
echo "── test 11: exit propagates to non -e caller ──"
caller_out=$(MOCK_FIXTURE="$FIXTURES/claim-not-ready.json" \
             MOCK_ARGS_LOG=/dev/null MOCK_COUNTER_FILE=/dev/null \
             KUBECTL="$MOCK_DIR/kubectl" PATH="$MOCK_DIR:$PATH" \
             POLL_INTERVAL=1 \
  bash -c "set -uo pipefail
           if bash '$SCRIPT' PlatformSecret stuck-claim test-ns 1 >/dev/null 2>&1; then
             echo CALLER_PASS
           else
             echo CALLER_FAIL
           fi")
assert_contains "non_e_caller_sees_failure" "CALLER_FAIL" "$caller_out"

# ===========================================================================
# Test 12: shellcheck clean (skip if shellcheck not on PATH).
# ===========================================================================
echo "── test 12: shellcheck ──"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$SCRIPT" 2>&1; then
    _pass "shellcheck_wait_for_claim"
  else
    _fail "shellcheck_wait_for_claim" "shellcheck reported issues"
  fi
  if shellcheck "$LIB" 2>&1; then
    _pass "shellcheck_k8s_helpers"
  else
    _fail "shellcheck_k8s_helpers" "shellcheck reported issues"
  fi
else
  echo "  (shellcheck not installed — skipping)"
fi

assert_summary
