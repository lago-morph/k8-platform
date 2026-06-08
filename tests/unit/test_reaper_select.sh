#!/usr/bin/env bash
# Unit test for tests/live/lib/reaper-select.sh (FINAL-PLAN §8 friendly-fire-
# proofing). Exercises every guard branch of the pure reap/protect predicate with
# no AWS and no deletes — the safety logic is the scariest part of the reaper, so
# it is tested in isolation before any enumerate-and-delete is wired on top.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
# shellcheck disable=SC1091
. tests/lib/assert.sh
# shellcheck disable=SC1091
. tests/live/lib/reaper-select.sh

# Deterministic config for the test.
REAPER_AGE_FLOOR=2700
REAPER_PROTECTED_IDS="k8-platform-mgmt k8-platform-services"

OLD=$((REAPER_AGE_FLOOR + 60))     # past the age-floor
YOUNG=$((REAPER_AGE_FLOOR - 60))   # under the age-floor
CUR="run-self"

# decide_verdict <id> <tag_runid> <cur> <age> <active> -> "REAP"|"PROTECT"
decide_verdict() {
  local out; out="$(reaper_decide "$1" "$2" "$3" "$4" "$5")"
  printf '%s' "${out%% *}"
}

echo "── reaper-select: structural deny-list is absolute (overrides all) ──"
# A protected singleton, even if tagged with a stale run-id, old, and lease-free,
# is NEVER reaped.
assert_eq "protected hub cluster => PROTECT" "PROTECT" \
  "$(decide_verdict "k8-platform-mgmt" "run-stale" "$CUR" "$OLD" 0)"
assert_eq "IAM role named for the protected spoke => PROTECT" "PROTECT" \
  "$(decide_verdict "k8-platform-cluster-k8-platform-services" "run-stale" "$CUR" "$OLD" 0)"
assert_eq "reaper_is_protected substring match" "true" \
  "$(reaper_is_protected "arn:...:cluster/k8-platform-services/x" && echo true || echo false)"
assert_eq "reaper_is_protected rejects an unrelated id" "false" \
  "$(reaper_is_protected "live-verify-abc123-scratch-role" && echo true || echo false)"

echo ""
echo "── reaper-select: only the suite's own tagged resources are touched ──"
assert_eq "untagged resource => PROTECT" "PROTECT" \
  "$(decide_verdict "some-random-role" "" "$CUR" "$OLD" 0)"
assert_eq "tag 'None' => PROTECT" "PROTECT" \
  "$(decide_verdict "some-random-role" "None" "$CUR" "$OLD" 0)"

echo ""
echo "── reaper-select: never reap the current run or a live lease-holder ──"
assert_eq "belongs to current run => PROTECT" "PROTECT" \
  "$(decide_verdict "live-verify-scratch" "$CUR" "$CUR" "$OLD" 0)"
assert_eq "other run-id but lease ACTIVE => PROTECT" "PROTECT" \
  "$(decide_verdict "live-verify-scratch" "run-other" "$CUR" "$OLD" 1)"

echo ""
echo "── reaper-select: age-floor protects a concurrent run's fresh resource ──"
assert_eq "younger than age-floor => PROTECT" "PROTECT" \
  "$(decide_verdict "live-verify-scratch" "run-other" "$CUR" "$YOUNG" 0)"

echo ""
echo "── reaper-select: the ONE case that reaps — a stale leaked resource ──"
# other run-id, no active lease, past the age-floor, not protected, tagged.
assert_eq "stale leak (all guards pass) => REAP" "REAP" \
  "$(decide_verdict "live-verify-deadrun-scratch-role" "run-dead" "$CUR" "$OLD" 0)"

echo ""
echo "── reaper-select: age-floor invariant (§14.8: > mutex lease-TTL 30m) ──"
assert_eq "age-floor (45m) strictly greater than the mutex lease-TTL (1800s)" "true" \
  "$([ "$REAPER_AGE_FLOOR" -gt 1800 ] && echo true || echo false)"

assert_summary
