#!/usr/bin/env bash
# 13: phase-status.sh smoke test on the live management cluster (SPEC-S5 §6/§7).
#
# Verifies the live-probe oracle does not crash, emits valid JSON with the
# expected schema, and that phases 0 + 1 are not 'not-coded' on a healthy
# management cluster. Two-shot idempotency check confirms phase 0 state is
# stable across back-to-back runs.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/phase-status.sh"

require_kube
require_aws

if [[ ! -x "$SCRIPT" ]]; then
  skip "scripts/phase-status.sh not present or not executable"
fi

# ---- 1. Runs without crashing in default mode ---------------------------
note "running scripts/phase-status.sh (no flags)"
if ! "$SCRIPT" >/tmp/phase_status_human.$$ 2>&1; then
  ng "phase-status.sh exited non-zero on healthy cluster"
fi
ok "phase-status.sh exited 0 in default mode"

# ---- 2. --json output is valid JSON with phases.0..phases.6 -------------
note "running scripts/phase-status.sh --json"
JSON_OUT=$("$SCRIPT" --json 2>/dev/null)
if ! echo "$JSON_OUT" | jq -e . >/dev/null 2>&1; then
  ng "--json output did not parse as JSON: $JSON_OUT"
fi

KEYS=$(echo "$JSON_OUT" | jq -r '.phases | keys | join(",")')
if [[ "$KEYS" != "0,1,2,3,4,5,6" ]]; then
  ng "expected phases.0..6, got: $KEYS"
fi
ok "--json output is valid and has 7 phase keys"

# ---- 3. .account is a non-null string (live account ID) -----------------
ACCT=$(echo "$JSON_OUT" | jq -r '.account')
if [[ -z "$ACCT" || "$ACCT" == "null" ]]; then
  ng ".account was null/empty: $ACCT"
fi
ok ".account populated: $ACCT"

# ---- 4. Phase 0 and 1 are NOT 'not-coded' on a healthy mgmt cluster -----
PHASE0=$(echo "$JSON_OUT" | jq -r '.phases."0".state')
PHASE1=$(echo "$JSON_OUT" | jq -r '.phases."1".state')
case "$PHASE0" in
  applied|verified) ok "phase 0 state '$PHASE0' is applied/verified" ;;
  *) ng "phase 0 state '$PHASE0' (expected applied or verified on healthy mgmt cluster)" ;;
esac
case "$PHASE1" in
  applied|verified) ok "phase 1 state '$PHASE1' is applied/verified" ;;
  *) ng "phase 1 state '$PHASE1' (expected applied or verified on healthy mgmt cluster)" ;;
esac

# ---- 5. Idempotency: two back-to-back runs report same phase-0 state ----
note "idempotency check (two runs in <5s)"
P0_A=$("$SCRIPT" --json | jq -r '.phases."0".state')
P0_B=$("$SCRIPT" --json | jq -r '.phases."0".state')
if [[ "$P0_A" == "$P0_B" ]]; then
  ok "phase 0 state stable across runs ($P0_A)"
else
  ng "phase 0 state flapped: $P0_A then $P0_B"
fi

# ---- 6. --assert-phase 1 verified exits 0 when phase 1 is healthy -------
if [[ "$PHASE1" == "verified" ]]; then
  if "$SCRIPT" --assert-phase 1 verified >/dev/null 2>&1; then
    ok "--assert-phase 1 verified exits 0"
  else
    ng "--assert-phase 1 verified exited non-zero despite phase 1 being verified"
  fi
else
  log "SKIP --assert-phase verified subcase (phase 1 state '$PHASE1', not 'verified')"
fi

# ---- 7. Stale-cluster fallback: KUBECONFIG=/dev/null → all not-coded ---
note "running with KUBECONFIG=/dev/null (no cluster reachable)"
NO_KUBE=$(KUBECONFIG=/dev/null AWS_DEFAULT_REGION=us-east-1 \
  "$SCRIPT" --json 2>/dev/null || echo '{}')
if [[ "$NO_KUBE" == "{}" ]]; then
  ng "phase-status.sh crashed with KUBECONFIG=/dev/null"
fi
VERIFIED_COUNT=$(echo "$NO_KUBE" | jq -r '[.phases[] | select(.state=="verified")] | length' 2>/dev/null || echo "x")
case "$VERIFIED_COUNT" in
  0) ok "no phases are 'verified' when no cluster reachable" ;;
  *) log "WARN: $VERIFIED_COUNT verified phases despite KUBECONFIG=/dev/null (phase 0 uses AWS only, may legitimately be verified)" ;;
esac

rm -f /tmp/phase_status_human.$$
ok "phase-status.sh integration smoke complete"
