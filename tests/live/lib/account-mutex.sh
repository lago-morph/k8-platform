#!/usr/bin/env bash
# account-mutex.sh — DynamoDB-backed ACCOUNT mutex for the live suite (FINAL-PLAN
# §8, §14.8). P3 prerequisite: before any default-on MUTATION (instantiate /
# negative tiers, or the reaper's destructive sweep), a run must hold the account
# lease, so two concurrent runs — or a run and the reaper — never collide on the
# shared account.
#
# Backing store: a single-row DynamoDB lock (terraform/management/verifier_role.tf
# `aws_dynamodb_table.live_verify_lock`, hash_key `lock_id`). One row PER ACCOUNT
# (`lock_id` defaults to the caller's AWS account id) holds the current `run_id`
# and `lease_expires` (epoch seconds). The scoped verifier/reaper role grants
# exactly dynamodb:GetItem/PutItem/DeleteItem on this table (zero-wildcard policy).
#
# Atomicity is a DynamoDB ConditionExpression (compare-and-set), NOT a read-then-
# write race:
#   acquire : put iff (no holder) OR (holder's lease has expired)  -> steals a dead
#             or suspended holder's lease; a LIVE holder with a valid lease blocks.
#   renew   : extend lease_expires iff we are still the holder (run_id matches).
#   release : delete the row iff we are the holder (run_id matches).
#
# Lease invariant (§14.8): the reaper's age-floor (>=45m) MUST be strictly greater
# than the lease-TTL (>= the slowest held op), so a dead holder's lease expires and
# is reclaimable, but a live mid-flight op (e.g. an EKS build) is NEVER reaped. A
# run suspended longer than the TTL loses its lease and MUST re-acquire before
# trusting prior resources.
#
# Test seam: `_mutex_ddb`, `_mutex_now`, `_mutex_lock_id` are overridable so
# tests/unit/test_account_mutex.sh can exercise the control flow with a fake
# DynamoDB and a synthetic clock (no AWS, deterministic).

# ---- config (fail-safe defaults) -----------------------------------------
MUTEX_TABLE="${MUTEX_TABLE:-k8-platform-live-verify-lock}"
# Lease TTL: default 30m. MUST stay < the reaper age-floor (45m). Bounded below by
# the slowest op a holder performs while holding the lease (renew before expiry).
MUTEX_LEASE_TTL="${MUTEX_LEASE_TTL:-1800}"
# Reaper age-floor the lease-TTL must stay under (asserted by the unit test).
MUTEX_REAPER_AGE_FLOOR="${MUTEX_REAPER_AGE_FLOOR:-2700}"
# Bounded acquire wait (a run never blocks forever on a busy account). This is the
# mutex lease-wait, measured SEPARATELY from the wall-clock budget (§14.9).
MUTEX_ACQUIRE_TIMEOUT="${MUTEX_ACQUIRE_TIMEOUT:-300}"
MUTEX_ACQUIRE_INTERVAL="${MUTEX_ACQUIRE_INTERVAL:-10}"
MUTEX_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# ---- overridable seams (real implementations) ----------------------------
# All DynamoDB access funnels through here so the unit test can fake it.
_mutex_ddb() { aws dynamodb "$@" --region "$MUTEX_REGION" --output json; }
_mutex_now() { date -u +%s; }
# lock_id defaults to the AWS account id (one lease per account, §8).
_mutex_lock_id() { echo "${MUTEX_LOCK_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null)}"; }

_mutex_log() { echo "  [mutex] $*" >&2; }

# ---- public API ----------------------------------------------------------

# mutex_acquire <run_id>
#   Returns 0 once the account lease is held by <run_id>; 1 on bounded timeout.
mutex_acquire() {
  local run_id="$1" lock_id deadline now expires
  [ -n "$run_id" ] || { _mutex_log "acquire: empty run_id"; return 2; }
  lock_id="$(_mutex_lock_id)"
  [ -n "$lock_id" ] || { _mutex_log "acquire: could not resolve lock_id (account)"; return 2; }
  deadline=$(( $(_mutex_now) + MUTEX_ACQUIRE_TIMEOUT ))
  while :; do
    now="$(_mutex_now)"
    expires=$(( now + MUTEX_LEASE_TTL ))
    # Compare-and-set: acquire iff unheld OR the current lease is expired.
    if _mutex_ddb put-item \
         --table-name "$MUTEX_TABLE" \
         --item "{\"lock_id\":{\"S\":\"$lock_id\"},\"run_id\":{\"S\":\"$run_id\"},\"lease_expires\":{\"N\":\"$expires\"}}" \
         --condition-expression "attribute_not_exists(lock_id) OR lease_expires < :now" \
         --expression-attribute-values "{\":now\":{\"N\":\"$now\"}}" >/dev/null 2>&1; then
      _mutex_log "acquired account lease lock_id=$lock_id run_id=$run_id lease=${MUTEX_LEASE_TTL}s"
      return 0
    fi
    if [ "$now" -ge "$deadline" ]; then
      _mutex_log "acquire TIMEOUT after ${MUTEX_ACQUIRE_TIMEOUT}s (another run holds the account lease)"
      return 1
    fi
    sleep "$MUTEX_ACQUIRE_INTERVAL"
  done
}

# mutex_renew <run_id> — extend the lease iff we still hold it. 0 ok, non-zero lost.
mutex_renew() {
  local run_id="$1" lock_id now expires
  lock_id="$(_mutex_lock_id)"; now="$(_mutex_now)"; expires=$(( now + MUTEX_LEASE_TTL ))
  if _mutex_ddb put-item \
       --table-name "$MUTEX_TABLE" \
       --item "{\"lock_id\":{\"S\":\"$lock_id\"},\"run_id\":{\"S\":\"$run_id\"},\"lease_expires\":{\"N\":\"$expires\"}}" \
       --condition-expression "run_id = :rid" \
       --expression-attribute-values "{\":rid\":{\"S\":\"$run_id\"}}" >/dev/null 2>&1; then
    return 0
  fi
  _mutex_log "renew FAILED — we no longer hold the lease (run_id=$run_id); MUST re-acquire before trusting prior resources"
  return 1
}

# mutex_release <run_id> — delete the row iff we hold it. Idempotent-ish (a lost
# lease release is a no-op success: someone else owns it, nothing for us to free).
mutex_release() {
  local run_id="$1" lock_id
  lock_id="$(_mutex_lock_id)"
  if _mutex_ddb delete-item \
       --table-name "$MUTEX_TABLE" \
       --key "{\"lock_id\":{\"S\":\"$lock_id\"}}" \
       --condition-expression "run_id = :rid" \
       --expression-attribute-values "{\":rid\":{\"S\":\"$run_id\"}}" >/dev/null 2>&1; then
    _mutex_log "released account lease lock_id=$lock_id run_id=$run_id"
    return 0
  fi
  _mutex_log "release no-op (lease not held by run_id=$run_id — expired or stolen)"
  return 0
}
