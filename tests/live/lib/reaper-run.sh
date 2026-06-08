#!/usr/bin/env bash
# reaper-run.sh — the live-suite reaper ENTRYPOINT (FINAL-PLAN §8, P3). It wires
# the PURE reaper-select.sh predicate (tests/live/lib/reaper-select.sh) to live
# AWS: a tag:GetResources enumerate → per-candidate age + active-lease resolution
# → a dry-run report → tag-conditioned per-service deletes.
#
# WHY this split: reaper-select.sh holds the scary "should this be deleted?" logic
# with NO AWS and NO deletes (unit-proven in isolation). reaper-run.sh is the thin
# I/O shell around it — every AWS touch funnels through an overridable `_reaper_*`
# seam so tests/unit/test_reaper_run.sh exercises the enumerate→decide→delete
# control flow with a FAKE tag API, a synthetic clock, and a recording delete (no
# AWS, deterministic), exactly as test_account_mutex.sh fakes DynamoDB.
#
# SAFETY (defence in depth, three independent layers):
#   1. reaper_decide reaps a candidate ONLY when EVERY guard passes (structural
#      deny-list, must-be-ours tag, not-current-run, no-active-lease, past age-floor).
#   2. REAPER_DRY_RUN defaults to 1 (report only). run.sh sets it to 0 ONLY inside
#      the explicit full+mutating engagement — never by default.
#   3. The verifier/reaper IAM policy itself tag-conditions every delete on the
#      `live-verify` run-id tag, so even a logic bug under the scoped role cannot
#      delete an untagged resource.
#
# Age comes from a `live-verify-created` epoch tag the instantiate harness (P4)
# stamps alongside `live-verify=<run_id>`. A missing/zero created-tag yields age 0
# (⇒ younger-than-floor ⇒ PROTECT) — fail-safe: an age we cannot establish never
# reaps.

set -uo pipefail

_REAPER_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The pure predicate (reaper_decide / reaper_is_protected).
# shellcheck source=/dev/null
. "$_REAPER_RUN_DIR/reaper-select.sh"
# The mutex store accessors (_mutex_ddb / _mutex_lock_id seams) for the live-lease
# check. Sourced via the SAME seam run.sh uses, so a unit test that fakes the mutex
# fakes it here too (no real-lib re-source clobbering the fake).
# shellcheck source=/dev/null
. "${LIVE_MUTEX_LIB:-$_REAPER_RUN_DIR/account-mutex.sh}"

# ---- config (fail-safe defaults) -----------------------------------------
REAPER_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
REAPER_TAG_KEY="${REAPER_TAG_KEY:-live-verify}"
REAPER_CREATED_TAG_KEY="${REAPER_CREATED_TAG_KEY:-live-verify-created}"
# Dry-run unless EXPLICITLY disabled. run.sh sets 0 only in full+mutating.
REAPER_DRY_RUN="${REAPER_DRY_RUN:-1}"

_reaper_now() { date -u +%s; }
_reaper_log() { echo "  [reaper] $*" >&2; }

# ---- overridable AWS seams (real implementations) ------------------------

# _reaper_enumerate — list suite-tagged resources. Emits one TSV row per resource:
#   <ResourceARN>\t<live-verify runid>\t<live-verify-created epoch>
_reaper_enumerate() {
  aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=$REAPER_TAG_KEY" \
    --region "$REAPER_REGION" --output json 2>/dev/null \
  | jq -r --arg ck "$REAPER_CREATED_TAG_KEY" '
      .ResourceTagMappingList[]?
      | . as $r
      | ($r.Tags | map({(.Key): .Value}) | add // {}) as $t
      | [ $r.ResourceARN,
          ($t["live-verify"] // ""),
          ($t[$ck] // "0") ] | @tsv'
}

# _reaper_runid_has_active_lease <runid> — echoes 1 iff <runid> currently holds
# the account mutex lease (holder match AND lease not expired), else 0. Reads the
# single lock row through the mutex store's own seam.
_reaper_runid_has_active_lease() {
  local runid="$1" lock_id row holder exp now
  [ -n "$runid" ] || { echo 0; return; }
  lock_id="$(_mutex_lock_id)"
  row="$(_mutex_ddb get-item --table-name "$MUTEX_TABLE" \
           --key "{\"lock_id\":{\"S\":\"$lock_id\"}}" 2>/dev/null)" || { echo 0; return; }
  holder="$(printf '%s' "$row" | jq -r '.Item.run_id.S // ""' 2>/dev/null)"
  exp="$(printf '%s' "$row" | jq -r '.Item.lease_expires.N // "0"' 2>/dev/null)"
  now="$(_reaper_now)"
  if [ "$holder" = "$runid" ] && [ "${exp:-0}" -gt "$now" ] 2>/dev/null; then
    echo 1
  else
    echo 0
  fi
}

# _reaper_delete <arn> — per-service, tag-conditioned delete of one resource.
# Returns 0 on success. Unknown services are a no-op success (fail-safe: the
# reaper never guesses a destructive call it has no explicit handler for).
_reaper_delete() {
  local arn="$1"
  case "$arn" in
    *:secretsmanager:*:secret:*)
      aws secretsmanager delete-secret --secret-id "$arn" \
        --force-delete-without-recovery --region "$REAPER_REGION" >/dev/null 2>&1 ;;
    *:iam::*:role/*)
      _reaper_delete_iam_role "${arn##*/}" ;;
    *:iam::*:oidc-provider/*)
      aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn" >/dev/null 2>&1 ;;
    *)
      _reaper_log "no delete handler for $arn (skipped — fail-safe)"; return 0 ;;
  esac
}

# IAM role deletion requires emptying the role first (detach managed policies,
# delete inline policies) before delete-role will succeed.
_reaper_delete_iam_role() {
  local name="$1" p
  for p in $(aws iam list-attached-role-policies --role-name "$name" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    [ -n "$p" ] && aws iam detach-role-policy --role-name "$name" --policy-arn "$p" >/dev/null 2>&1
  done
  for p in $(aws iam list-role-policies --role-name "$name" \
               --query 'PolicyNames[]' --output text 2>/dev/null); do
    [ -n "$p" ] && aws iam delete-role-policy --role-name "$name" --policy-name "$p" >/dev/null 2>&1
  done
  aws iam delete-role --role-name "$name" >/dev/null 2>&1
}

# ---- public entrypoint ----------------------------------------------------

# reaper_run [current_run_id]
#   Enumerate suite-tagged resources, decide each via reaper_decide, print the
#   dry-run verdict, and (only when REAPER_DRY_RUN=0) perform the tag-conditioned
#   delete for REAP verdicts. Always returns 0 — a clean account (no candidates)
#   is success, and an individual delete failure is logged but never aborts the
#   sweep (the suite must still run). Real errors surface in the log.
reaper_run() {
  local cur="${1:-${RUN_ID:-none}}"
  local now arn runid created age active verdict rc
  local reaped=0 protected=0 any=0
  now="$(_reaper_now)"
  _reaper_log "sweep start (run_id=$cur, dry_run=$REAPER_DRY_RUN, tag-key=$REAPER_TAG_KEY)"
  # `|| [ -n "$arn" ]` processes a final line that lacks a trailing newline.
  while IFS=$'\t' read -r arn runid created || [ -n "$arn" ]; do
    [ -z "$arn" ] && continue
    any=1
    # Age from the created-tag; non-numeric/zero ⇒ age 0 ⇒ PROTECT (fail-safe).
    if printf '%s' "$created" | grep -Eq '^[0-9]+$' && [ "$created" -gt 0 ]; then
      age=$(( now - created ))
    else
      age=0
    fi
    active="$(_reaper_runid_has_active_lease "$runid")"
    verdict="$(reaper_decide "$arn" "$runid" "$cur" "$age" "$active")"; rc=$?
    echo "  [reaper] $verdict :: $arn" >&2
    if [ "$rc" -eq 0 ]; then
      reaped=$((reaped+1))
      if [ "$REAPER_DRY_RUN" = "1" ]; then
        _reaper_log "DRY-RUN would delete $arn"
      elif _reaper_delete "$arn"; then
        _reaper_log "deleted $arn"
      else
        _reaper_log "delete FAILED for $arn (logged; sweep continues)"
      fi
    else
      protected=$((protected+1))
    fi
  done < <(_reaper_enumerate)
  [ "$any" = 0 ] && _reaper_log "no suite-tagged candidates found (clean account)"
  _reaper_log "sweep done — reap=$reaped protect=$protected dry_run=$REAPER_DRY_RUN"
  return 0
}
