#!/usr/bin/env bash
# Unit test for tests/live/lib/reaper-run.sh (FINAL-PLAN §8, P3). Exercises the
# enumerate → decide → dry-run → delete control flow with a FAKE tag:GetResources
# API, a synthetic clock, a fake mutex-lease check, and a RECORDING delete — no
# AWS, deterministic. The pure reap/protect decision is covered by
# test_reaper_select.sh; THIS proves the I/O shell wires it correctly:
#   - dry-run reports but NEVER deletes;
#   - a REAP verdict in live mode deletes exactly the leaked ARN;
#   - every PROTECT branch (singleton / current-run / active-lease / young /
#     age-unknown) results in NO delete;
#   - _reaper_delete routes by ARN service.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
# shellcheck disable=SC1091
. tests/lib/assert.sh
# shellcheck disable=SC1091
. tests/live/lib/reaper-run.sh

# ---- deterministic config + seam fakes -----------------------------------
REAPER_AGE_FLOOR=2700
REAPER_PROTECTED_IDS="k8-platform-mgmt k8-platform-services"
NOW=1000000000
_reaper_now() { echo "$NOW"; }

# Fake lease check: a run-id is "active" iff listed in $ACTIVE_RUNIDS.
ACTIVE_RUNIDS=""
_reaper_runid_has_active_lease() {
  case " $ACTIVE_RUNIDS " in *" $1 "*) echo 1 ;; *) echo 0 ;; esac
}

# Recording delete: append each ARN actually deleted to $DELETED.
DELETED=""
_reaper_delete() { DELETED="$DELETED $1"; return 0; }

# Canned enumerate output (TSV: ARN<TAB>runid<TAB>created_epoch), set per case.
ENUM=""
_reaper_enumerate() { printf '%s' "$ENUM"; }

OLD=$(( NOW - (REAPER_AGE_FLOOR + 600) ))     # created long ago → past the floor
YOUNG=$(( NOW - (REAPER_AGE_FLOOR - 600) ))   # created recently → under the floor

run_reaper() { DELETED=""; reaper_run "run-self" >/dev/null 2>&1; }

echo "── reaper-run: clean account (no candidates) → nothing deleted, rc=0 ──"
ENUM=""; REAPER_DRY_RUN=0
reaper_run "run-self" >/dev/null 2>&1; rc=$?
assert_eq "clean sweep returns 0" "0" "$rc"
DELETED=""; run_reaper
assert_eq "no candidates → no deletes" "" "$DELETED"

echo ""
echo "── reaper-run: a stale leak — dry-run REPORTS but never deletes ──"
ENUM="arn:aws:secretsmanager:us-east-1:111:secret:live-verify/abc"$'\t'"run-dead"$'\t'"$OLD"
REAPER_DRY_RUN=1; run_reaper
assert_eq "dry-run never deletes even a reapable leak" "" "$DELETED"

echo ""
echo "── reaper-run: a stale leak — live mode deletes exactly it ──"
REAPER_DRY_RUN=0; run_reaper
assert_eq "live mode deletes the stale leak ARN" \
  " arn:aws:secretsmanager:us-east-1:111:secret:live-verify/abc" "$DELETED"

echo ""
echo "── reaper-run: a protected singleton is NEVER deleted (even live) ──"
ENUM="arn:aws:iam::111:role/k8-platform-cluster-k8-platform-services"$'\t'"run-dead"$'\t'"$OLD"
REAPER_DRY_RUN=0; run_reaper
assert_eq "protected singleton → no delete" "" "$DELETED"

echo ""
echo "── reaper-run: the current run's own resource is never deleted ──"
ENUM="arn:aws:secretsmanager:us-east-1:111:secret:live-verify/self"$'\t'"run-self"$'\t'"$OLD"
REAPER_DRY_RUN=0; run_reaper
assert_eq "current-run resource → no delete" "" "$DELETED"

echo ""
echo "── reaper-run: a run-id holding an ACTIVE lease is never deleted ──"
ENUM="arn:aws:secretsmanager:us-east-1:111:secret:live-verify/live"$'\t'"run-live"$'\t'"$OLD"
ACTIVE_RUNIDS="run-live"; REAPER_DRY_RUN=0; run_reaper
assert_eq "active-lease holder → no delete" "" "$DELETED"
ACTIVE_RUNIDS=""

echo ""
echo "── reaper-run: a YOUNG resource (under the age-floor) is protected ──"
ENUM="arn:aws:secretsmanager:us-east-1:111:secret:live-verify/young"$'\t'"run-dead"$'\t'"$YOUNG"
REAPER_DRY_RUN=0; run_reaper
assert_eq "younger than age-floor → no delete" "" "$DELETED"

echo ""
echo "── reaper-run: a MISSING created-tag (age unknown) is protected (fail-safe) ──"
ENUM="arn:aws:secretsmanager:us-east-1:111:secret:live-verify/notag"$'\t'"run-dead"$'\t'"0"
REAPER_DRY_RUN=0; run_reaper
assert_eq "age-unknown (created=0) → fail-safe PROTECT, no delete" "" "$DELETED"

echo ""
echo "── reaper-run: mixed batch — only the one true leak is deleted ──"
ENUM="$(printf '%s\n%s\n%s' \
  "arn:aws:iam::111:role/k8-platform-mgmt-x"$'\t'"run-dead"$'\t'"$OLD" \
  "arn:aws:secretsmanager:us-east-1:111:secret:live-verify/leak"$'\t'"run-dead"$'\t'"$OLD" \
  "arn:aws:secretsmanager:us-east-1:111:secret:live-verify/self"$'\t'"run-self"$'\t'"$OLD")"
REAPER_DRY_RUN=0; run_reaper
assert_eq "mixed batch deletes only the true leak" \
  " arn:aws:secretsmanager:us-east-1:111:secret:live-verify/leak" "$DELETED"

echo ""
echo "── reaper-run: _reaper_delete routes by ARN service (real dispatch) ──"
# The REAL _reaper_delete redirects its `aws` calls to /dev/null, so the fake aws
# records to a FILE (the explicit `>>` wins over the caller's >/dev/null). Each
# case runs in a subshell that re-sources the lib (restoring the real dispatch).
ROUTEFILE="$(mktemp)"
route_of() {
  : > "$ROUTEFILE"
  (
    # shellcheck disable=SC1091
    . tests/live/lib/reaper-run.sh
    aws() { echo "aws $*" >> "$ROUTEFILE"; }       # list-calls → empty stdout (loops don't iterate)
    _reaper_delete "$1" >/dev/null 2>&1
  )
  cat "$ROUTEFILE"
}
assert_contains "secret ARN → secretsmanager delete-secret" "secretsmanager delete-secret" \
  "$(route_of "arn:aws:secretsmanager:us-east-1:111:secret:live-verify/x")"
assert_contains "role ARN → iam delete-role" "iam delete-role" \
  "$(route_of "arn:aws:iam::111:role/live-verify-scratch")"
assert_contains "oidc ARN → iam delete-open-id-connect-provider" "delete-open-id-connect-provider" \
  "$(route_of "arn:aws:iam::111:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/X")"

# Unknown service: no aws delete at all (fail-safe). The _reaper_log note goes to
# stderr, captured here; the route file stays empty.
ROUTE_UNKNOWN="$(
  # shellcheck disable=SC1091
  . tests/live/lib/reaper-run.sh
  aws() { echo "aws $*" >> "$ROUTEFILE"; }
  : > "$ROUTEFILE"
  _reaper_delete "arn:aws:rds:us-east-1:111:db:live-verify-xyz" 2>&1
)"
assert_contains "unknown service → fail-safe no-op note" "no delete handler" "$ROUTE_UNKNOWN"
assert_eq "unknown service → no aws delete call recorded" "true" \
  "$([ ! -s "$ROUTEFILE" ] && echo true || echo false)"
rm -f "$ROUTEFILE"

assert_summary
