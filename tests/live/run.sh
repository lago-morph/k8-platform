#!/usr/bin/env bash
# LIVE behavioral suite orchestrator (FINAL-PLAN §4.1/§4.2/§4.4).
#
# This is the inverted-skip orchestrator: where tests/integration/run.sh exits 0
# whenever FAIL==0 (so an all-skipped run on a rotated/empty account reads GREEN
# — the exact disease this overhaul kills), tests/live/run.sh treats
# ALL-SKIPPED ⇒ RED, per profile, and promotes a SKIP of a git-declared
# (expect-full) kind to a FAIL.
#
# Usage:
#   tests/live/run.sh [LIVE_MODE]
#     LIVE_MODE = mutating | readonly   (arg overrides env; unset => readonly)
#
# Environment:
#   LIVE_PROFILE   full (DEFAULT) | verify-only | off     (which TIERS run)
#   LIVE_MODE      mutating | readonly                    (read-only vs mutating
#                  within the live tiers; unset => readonly, fail-closed)
#   LIVE_CLUSTER   cluster-under-test name (for expect-full derivation + evidence)
#   LIVE_EXPECT_FULL   (test seam) space-separated kinds; overrides git derivation
#   LIVE_CHECKS_ROOT   (test seam) dir holding after/ instantiate/ negative/
#                                  (default tests/live/checks)
#   LIVE_SKIP_REGISTER (test seam) path to the register (default tests/live/SKIP_REGISTER.yaml)
#
# Exit codes (orchestrator):
#   0  clean pass
#   1  FAIL (a check failed, or ALL-SKIPPED/empty under the active profile)
#   3  expect-full violation (a git-declared kind was not verified by a pass)
#   2  reserved for "no kube-API at all" not-applicable abort is NOT used here —
#      a precondition abort is a FAIL (fail-closed), see below.

set -uo pipefail

LIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIVE_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$LIVE_DIR/lib/live-lib.sh"

# ---- config + fail-closed defaults ---------------------------------------

# DEFAULT PROFILE == full is a TESTED INVARIANT (FINAL-PLAN §4.2). This literal
# is the single committed source the unit test reads; changing it is a red diff.
LIVE_PROFILE_DEFAULT=full

LIVE_PROFILE="${LIVE_PROFILE:-$LIVE_PROFILE_DEFAULT}"
# LIVE_MODE: arg #1 overrides env; unset => readonly (fail-closed).
[ "${1:-}" != "" ] && LIVE_MODE="$1"
MODE="$(live_mode)"

CHECKS_ROOT="${LIVE_CHECKS_ROOT:-$LIVE_DIR/checks}"
REGISTER="${LIVE_SKIP_REGISTER:-$LIVE_DIR/SKIP_REGISTER.yaml}"

banner() { echo "════════ live-suite: $* ════════"; }

# ---- helpers (defined before use) ----------------------------------------

# register_has_valid_disable_all <register> — true iff a disable_all entry with
# non-empty reason/owner/expires that is NOT past today exists.
register_has_valid_disable_all() {
  local reg="$1"
  [ -f "$reg" ] || return 1
  local reason owner expires
  reason="$(yq -r '.disable_all.reason // ""' "$reg" 2>/dev/null)"
  owner="$(yq -r '.disable_all.owner // ""' "$reg" 2>/dev/null)"
  expires="$(yq -r '.disable_all.expires // ""' "$reg" 2>/dev/null)"
  [ -n "$reason" ] && [ -n "$owner" ] && [ -n "$expires" ] || return 1
  local today; today="$(date -u +%Y-%m-%d)"
  [ "$expires" \> "$today" ] || [ "$expires" = "$today" ]   # not expired
}

# derive_expect_full — the git-declared composed-MR kinds for the cluster under
# test (FINAL-PLAN §4.3: derived from GIT, never from the system under test).
# LIVE_EXPECT_FULL overrides for the unit harness.
derive_expect_full() {
  if [ -n "${LIVE_EXPECT_FULL+x}" ]; then
    printf '%s\n' $LIVE_EXPECT_FULL | sed '/^$/d' | sort -u
    return
  fi
  # The kind set comes from the committed Compositions (the coverage deriver);
  # whether a given cluster declares them is refined per-cluster in P2 (the
  # git-cluster-declaration parse). Until then, fail-closed: with no checks
  # populated the all-skip⇒RED rule already prevents a green-by-absence.
  local deriver="$REPO_ROOT/tests/coverage/derive-coverage.sh"
  [ -x "$deriver" ] && "$deriver" 2>/dev/null | sort -u || true
}

# ---- profile validation + the verify-only ⇒ readonly coupling ------------
# (FINAL-PLAN §4.2) The PROFILE chooses WHICH TIERS run; LIVE_MODE chooses
# read-only vs mutating WITHIN them. verify-only has no instantiate tier to
# mutate, so verify-only IMPLIES readonly, and verify-only+mutating is rejected.
case "$LIVE_PROFILE" in
  full) ;;
  verify-only)
    if [ "$MODE" = "mutating" ]; then
      echo "FAIL: LIVE_PROFILE=verify-only is incompatible with LIVE_MODE=mutating" >&2
      echo "      (verify-only drops the instantiate tier; there is nothing to mutate)." >&2
      exit 1
    fi
    MODE=readonly   # verify-only implies readonly
    ;;
  off)
    # off is RED-and-non-zero UNLESS a top-level disable_all register entry
    # (reason/owner/expires) exists. off/disable_all is a thin alias that writes
    # a SKIP_REGISTER-shaped entry — one durable disable path (round-3 devx M2).
    if register_has_valid_disable_all "$REGISTER"; then
      banner "PROFILE=off — DISABLED via an audited disable_all register entry"
      echo "  (this is a recorded, attributable choice; not a silent skip)"
      exit 0
    fi
    echo "FAIL: LIVE_PROFILE=off requires a valid top-level disable_all entry" >&2
    echo "      (reason/owner/expires, not expired) in $REGISTER. RED by design." >&2
    exit 1
    ;;
  *)
    echo "FAIL: unknown LIVE_PROFILE='$LIVE_PROFILE' (full|verify-only|off)" >&2
    exit 1
    ;;
esac

# ---- tier → profile map (FINAL-PLAN §4.2) --------------------------------
#   after        (read-only existence/convergence/health) runs in full + verify-only
#   instantiate  (cheap-hermetic create-and-verify)        runs in full only
#   negative     (guard-fired)                              runs in full only
ACTIVE_TIERS="after"
[ "$LIVE_PROFILE" = "full" ] && ACTIVE_TIERS="after instantiate negative"

# ---- run the active tiers -------------------------------------------------
banner "PROFILE=$LIVE_PROFILE MODE=$MODE TIERS='$ACTIVE_TIERS' CLUSTER='${LIVE_CLUSTER:-?}'"

RUN_ID="${RUN_ID:-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6 || echo $$)}"
export RUN_ID

PASS=0; SKIP=0; FAIL=0; EXPECTVIOL=0
COVERED_PASS=""          # group/kinds verified by a PASSING check
declare -a FAILED=()

run_check() {
  local script="$1"
  echo ""
  echo "──── $script (RUN_ID=$RUN_ID, MODE=$MODE) ────"
  local out rc
  set +e
  out="$(LIVE_MODE="$MODE" bash "$script" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  case "$rc" in
    "$LIVE_RC_PASS")
      PASS=$((PASS+1))
      # record covered kinds from this passing check
      local k
      while IFS= read -r k; do
        [ -n "$k" ] && COVERED_PASS="$COVERED_PASS
$k"
      done < <(printf '%s\n' "$out" | sed -n 's/^COVERS //p')
      ;;
    "$LIVE_RC_SKIP")       SKIP=$((SKIP+1)) ;;
    "$LIVE_RC_EXPECT_FULL") EXPECTVIOL=$((EXPECTVIOL+1)); FAILED+=("$script (expect-full)") ;;
    *)                     FAIL=$((FAIL+1)); FAILED+=("$script (exit=$rc)") ;;
  esac
}

CHECK_COUNT=0
for tier in $ACTIVE_TIERS; do
  dir="$CHECKS_ROOT/$tier"
  [ -d "$dir" ] || continue
  for script in $(find "$dir" -maxdepth 1 -name '*.sh' 2>/dev/null | sort); do
    CHECK_COUNT=$((CHECK_COUNT+1))
    run_check "$script"
  done
done

# ---- expect-full promotion: every git-declared kind must be verified -------
EXPECT_FULL="$(derive_expect_full)"
COVERED_SORTED="$(printf '%s\n' "$COVERED_PASS" | sed '/^$/d' | sort -u)"
MISSING_EXPECT=""
if [ -n "$EXPECT_FULL" ]; then
  MISSING_EXPECT="$(comm -23 <(printf '%s\n' "$EXPECT_FULL") <(printf '%s\n' "$COVERED_SORTED"))"
fi

# ---- tabulate (the inversion) ---------------------------------------------
echo ""
banner "summary  pass=$PASS skip=$SKIP fail=$FAIL expect-full-violations=$EXPECTVIOL checks=$CHECK_COUNT"

RC=0
# expect-full kinds with no passing coverage => promoted FAIL (reserved code 3)
if [ -n "$MISSING_EXPECT" ]; then
  echo "  EXPECT-FULL VIOLATION — git declares these kinds but no passing check verified them:" >&2
  printf '    - %s\n' $MISSING_EXPECT >&2
  RC=3
fi
if [ "$EXPECTVIOL" -gt 0 ]; then RC=3; fi
# any hard failure
if [ "$FAIL" -gt 0 ]; then
  echo "  FAILED checks:" >&2
  for t in "${FAILED[@]}"; do echo "    - $t" >&2; done
  [ "$RC" -eq 0 ] && RC=1
fi
# ALL-SKIPPED (or zero checks ran) under the active profile => RED. This is the
# per-profile anti-silent-regression floor: the suite cannot read green having
# verified nothing (FINAL-PLAN §4.2/§4.4).
if [ "$PASS" -eq 0 ] && [ "$RC" -eq 0 ]; then
  echo "  ALL-SKIPPED / NO-CHECKS under profile=$LIVE_PROFILE — RED by design." >&2
  echo "    (the live suite must not read green having verified nothing; populate" >&2
  echo "     the '$ACTIVE_TIERS' tier(s) or record an audited disable in $REGISTER)" >&2
  RC=1
fi

[ "$RC" -eq 0 ] && banner "PASS"
exit "$RC"
