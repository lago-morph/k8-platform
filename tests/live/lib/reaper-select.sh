#!/usr/bin/env bash
# reaper-select.sh — friendly-fire-proofing DECISION logic for the live-suite
# reaper (FINAL-PLAN §8). This file holds ONLY the pure "should this resource be
# reaped?" predicate + the structural protected-id guard, with NO AWS calls and NO
# deletes, so the scariest part of the reaper (what it will destroy) is fully
# unit-testable in isolation (tests/unit/test_reaper_select.sh).
#
# The reaper runs FIRST (before a run provisions) to clear leaked resources from
# dead prior runs, but it is friendly-fire-proofed: it reaps a candidate ONLY when
# EVERY guard passes. The guards, in precedence order:
#   1. structural deny-list  — long-lived platform singletons are NEVER reaped,
#      regardless of tags/age. A DENY-list (not an allow-match) so an untagged or
#      mislabeled protected resource is still safe (fail-safe).
#   2. must be ours          — must carry a `live-verify` run-id tag; an untagged
#      resource is not the suite's and is never touched.
#   3. not the current run   — never reap the in-flight run's own resources.
#   4. no active lease       — never reap a run-id that still holds the account
#      mutex lease (a live holder mid-flight); checked via the mutex store.
#   5. past the age-floor     — only reap resources older than REAPER_AGE_FLOOR,
#      which (§14.8) is strictly greater than the mutex lease-TTL, so a just-
#      created resource from a concurrent run is never reaped.
# The actual enumerate-and-delete (tags:GetResources + tag-conditioned deletes,
# dry-run first) lives in the reaper entrypoint and calls this predicate; the
# IAM policy itself ALSO tag-conditions every delete (defence in depth).

# Age-floor: 45m default, MUST stay > the mutex lease-TTL (30m) per §14.8 so a
# dead holder's lease expires (its resources become reapable) but a live mid-flight
# op is never reaped.
REAPER_AGE_FLOOR="${REAPER_AGE_FLOOR:-2700}"

# Structural deny-list: substrings of resource identifiers that are NEVER reaped.
# The long-lived platform singletons (the hub + spoke clusters and anything named
# for them). Space-separated; matched as substrings so e.g. an IAM role
# `k8-platform-cluster-k8-platform-services` is caught by `k8-platform-services`.
REAPER_PROTECTED_IDS="${REAPER_PROTECTED_IDS:-k8-platform-mgmt k8-platform-services}"

# reaper_is_protected <resource_id> -> 0 (true) if on the structural deny-list.
reaper_is_protected() {
  local id="$1" p
  for p in $REAPER_PROTECTED_IDS; do
    case "$id" in *"$p"*) return 0 ;; esac
  done
  return 1
}

# reaper_decide <resource_id> <tag_runid> <current_runid> <age_seconds> <runid_has_active_lease:0|1>
#   Prints "REAP <reason>" or "PROTECT <reason>". Returns 0 to reap, 1 to protect.
#   Pure: no AWS calls, no side effects. The entrypoint supplies the inputs.
reaper_decide() {
  local id="$1" tag_runid="$2" cur="$3" age="$4" active="$5"

  # 1. structural deny-list FIRST (highest precedence, overrides everything).
  if reaper_is_protected "$id"; then
    echo "PROTECT structural-deny-list ($id is a protected platform singleton)"
    return 1
  fi
  # 2. must carry a live-verify run-id tag (untagged => not the suite's).
  if [ -z "$tag_runid" ] || [ "$tag_runid" = "None" ] || [ "$tag_runid" = "null" ]; then
    echo "PROTECT no live-verify run-id tag ($id is not a suite-created resource)"
    return 1
  fi
  # 3. never reap the current run's own resources.
  if [ "$tag_runid" = "$cur" ]; then
    echo "PROTECT belongs to the current run ($cur)"
    return 1
  fi
  # 4. never reap a run-id that still holds an active mutex lease (live holder).
  if [ "$active" != "0" ]; then
    echo "PROTECT run-id $tag_runid holds an active lease (live holder, mid-flight)"
    return 1
  fi
  # 5. age-floor: only reap resources older than the floor.
  if [ "$age" -lt "$REAPER_AGE_FLOOR" ]; then
    echo "PROTECT younger than age-floor (${age}s < ${REAPER_AGE_FLOOR}s; a concurrent run may still be using it)"
    return 1
  fi

  echo "REAP stale leak run-id=$tag_runid age=${age}s (no active lease, past the ${REAPER_AGE_FLOOR}s age-floor)"
  return 0
}
