#!/usr/bin/env bash
# Unit test for tests/live/lib/account-mutex.sh (FINAL-PLAN §8, §14.8).
#
# Exercises the compare-and-set control flow with a FAKE DynamoDB (the lib's
# _mutex_ddb / _mutex_now / _mutex_lock_id seams) and a synthetic clock — no AWS,
# fully deterministic. The fake actually evaluates the ConditionExpressions
# (no-holder / lease-expired / run_id-match) so this is a behavioral test of the
# lease semantics, not just a static lint.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
# shellcheck disable=SC1091
. tests/lib/assert.sh

# ---- load the lib under test ---------------------------------------------
# shellcheck disable=SC1091
. tests/live/lib/account-mutex.sh

# ---- synthetic clock + fake DynamoDB (in-memory single lock row) ----------
FAKE_NOW=1000
_mutex_now() { echo "$FAKE_NOW"; }
_mutex_lock_id() { echo "test-account"; }

FAKE_HELD=0          # 0 = unheld, 1 = held
FAKE_RUNID=""
FAKE_EXPIRES=0

# Fake `aws dynamodb <op> ...`: parses --item/--key/--condition-expression/
# --expression-attribute-values and evaluates the condition against the in-memory
# row. Returns 0 (success) / 1 (ConditionalCheckFailed), matching the real API's
# exit-code contract that the lib relies on.
_mutex_ddb() {
  local op="$1"; shift
  local item="" key="" cond="" vals=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --item) item="$2"; shift 2 ;;
      --key) key="$2"; shift 2 ;;
      --condition-expression) cond="$2"; shift 2 ;;
      --expression-attribute-values) vals="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local new_run new_exp now rid
  case "$op" in
    put-item)
      new_run="$(printf '%s' "$item" | jq -r '.run_id.S')"
      new_exp="$(printf '%s' "$item" | jq -r '.lease_expires.N')"
      if printf '%s' "$cond" | grep -q "attribute_not_exists"; then
        # acquire: succeed iff unheld OR current lease expired (< :now)
        now="$(printf '%s' "$vals" | jq -r '.":now".N')"
        if [ "$FAKE_HELD" -eq 0 ] || [ "$FAKE_EXPIRES" -lt "$now" ]; then
          FAKE_HELD=1; FAKE_RUNID="$new_run"; FAKE_EXPIRES="$new_exp"; return 0
        fi
        return 1
      else
        # renew: succeed iff we hold it and run_id matches
        rid="$(printf '%s' "$vals" | jq -r '.":rid".S')"
        if [ "$FAKE_HELD" -eq 1 ] && [ "$FAKE_RUNID" = "$rid" ]; then
          FAKE_EXPIRES="$new_exp"; return 0
        fi
        return 1
      fi
      ;;
    delete-item)
      rid="$(printf '%s' "$vals" | jq -r '.":rid".S')"
      if [ "$FAKE_HELD" -eq 1 ] && [ "$FAKE_RUNID" = "$rid" ]; then
        FAKE_HELD=0; FAKE_RUNID=""; FAKE_EXPIRES=0; return 0
      fi
      return 1
      ;;
  esac
  return 0
}

# Fast, deterministic acquire (no real sleeping/looping in the held case).
MUTEX_LEASE_TTL=1800
MUTEX_ACQUIRE_TIMEOUT=0      # one attempt then give up (held => immediate timeout)
MUTEX_ACQUIRE_INTERVAL=0

echo "── account-mutex: invariant (age-floor > lease-TTL, §14.8) ───"
assert_eq "reaper age-floor (45m) strictly greater than lease-TTL (30m)" \
  "true" "$([ "$MUTEX_REAPER_AGE_FLOOR" -gt "$MUTEX_LEASE_TTL" ] && echo true || echo false)"

echo ""
echo "── account-mutex: acquire on an unheld account succeeds ──────"
mutex_acquire "run-A"; rc=$?
assert_eq "acquire unheld => 0" "0" "$rc"
assert_eq "lease now held by run-A" "run-A" "$FAKE_RUNID"

echo ""
echo "── account-mutex: a second run is BLOCKED while the lease is valid ──"
mutex_acquire "run-B"; rc=$?
assert_eq "acquire while held+valid => timeout (1)" "1" "$rc"
assert_eq "holder unchanged (still run-A)" "run-A" "$FAKE_RUNID"

echo ""
echo "── account-mutex: renew extends our own lease, not a stranger's ──"
FAKE_NOW=1500
mutex_renew "run-A"; rc=$?
assert_eq "owner renew => 0" "0" "$rc"
assert_eq "lease extended to now+TTL" "$((1500 + MUTEX_LEASE_TTL))" "$FAKE_EXPIRES"
mutex_renew "run-B"; rc=$?
assert_eq "non-owner renew => non-zero (lease lost)" "1" "$rc"

echo ""
echo "── account-mutex: a dead holder's EXPIRED lease is stealable ──"
# Advance the clock past run-A's lease; run-B should now steal it.
FAKE_NOW=$(( FAKE_EXPIRES + 1 ))
mutex_acquire "run-B"; rc=$?
assert_eq "acquire after holder lease expired => 0 (stolen)" "0" "$rc"
assert_eq "lease now held by run-B" "run-B" "$FAKE_RUNID"

echo ""
echo "── account-mutex: release only frees our own lease ───────────"
mutex_release "run-A"; rc=$?           # run-A no longer holds it -> no-op success
assert_eq "stale release is a no-op success" "0" "$rc"
assert_eq "run-B still holds the lease" "run-B" "$FAKE_RUNID"
mutex_release "run-B"; rc=$?
assert_eq "owner release => 0" "0" "$rc"
assert_eq "lease now free" "0" "$FAKE_HELD"

echo ""
echo "── account-mutex: acquire is a compare-and-set (atomicity guard) ──"
# The acquire path MUST carry a ConditionExpression (no read-then-write race).
assert_eq "acquire uses attribute_not_exists OR lease_expires guard" "true" \
  "$(grep -q 'attribute_not_exists(lock_id) OR lease_expires < :now' tests/live/lib/account-mutex.sh && echo true || echo false)"
assert_eq "renew/release guard on run_id match" "true" \
  "$(grep -q 'condition-expression "run_id = :rid"' tests/live/lib/account-mutex.sh && echo true || echo false)"

assert_summary
