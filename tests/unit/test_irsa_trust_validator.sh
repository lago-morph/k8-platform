#!/usr/bin/env bash
# Unit tests for scripts/irsa_trust_validator.py (SPEC-S3).
# Pure-offline: uses JSON fixtures via IRSA_VALIDATOR_MOCK_DIR.
# Defends against Bug 5 (PR #66/#67/#68) — IRSA SA-name drift.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/test-helpers.sh
. "$HERE/lib/test-helpers.sh"

ROOT="$HERE/../.."
SCRIPT="$ROOT/scripts/irsa_trust_validator.py"
FIX="$ROOT/tests/unit/fixtures/irsa_trust_validator"

require_tool python3

[ -f "$SCRIPT" ] || { echo "missing $SCRIPT"; exit 2; }
[ -d "$FIX" ] || { echo "missing $FIX"; exit 2; }

# run_validator <fixture-dir-name> <extra-args...>
# stdout captured to $LAST_OUT, exit code to $LAST_RC.
LAST_OUT=""
LAST_RC=0
run_validator() {
  local fix_name="$1"; shift
  LAST_OUT=$(IRSA_VALIDATOR_MOCK_DIR="$FIX/$fix_name" \
    python3 "$SCRIPT" "$@" 2>&1)
  LAST_RC=$?
}

assert_contains() {
  local name="$1" needle="$2"
  if echo "$LAST_OUT" | grep -qF -- "$needle"; then
    pass "$name"
  else
    fail "$name" "missing substring: $needle"
    echo "---- captured output ----"; echo "$LAST_OUT"; echo "----"
  fi
}

assert_not_contains() {
  local name="$1" needle="$2"
  if echo "$LAST_OUT" | grep -qF -- "$needle"; then
    fail "$name" "unexpected substring present: $needle"
    echo "---- captured output ----"; echo "$LAST_OUT"; echo "----"
  else
    pass "$name"
  fi
}

assert_rc() {
  local name="$1" want="$2"
  if [ "$LAST_RC" -eq "$want" ]; then
    pass "$name"
  else
    fail "$name" "exit code: got $LAST_RC, want $want"
    echo "---- captured output ----"; echo "$LAST_OUT"; echo "----"
  fi
}

# ---- --help exits 0 with usage ----------------------------------------
echo "── case: --help ─────────────────────────────────────────────"
HELP_OUT=$(python3 "$SCRIPT" --help 2>&1); HELP_RC=$?
if [ "$HELP_RC" -eq 0 ]; then pass "--help exits 0"
else fail "--help exits 0" "got $HELP_RC"; fi
if echo "$HELP_OUT" | grep -q -- "--all" \
   && echo "$HELP_OUT" | grep -q -- "--role" \
   && echo "$HELP_OUT" | grep -q -- "--cluster" \
   && echo "$HELP_OUT" | grep -q -- "--ci"; then
  pass "--help advertises required flags"
else
  fail "--help advertises required flags" "missing one of --all/--role/--cluster/--ci"
fi

# ---- case: full match-all (PR #11 case: SUMMARY 0 MISMATCH) -----------
echo "── case: match-all ──────────────────────────────────────────"
run_validator match-all --all --ci
assert_rc "match-all exits 0 in --ci" 0
assert_contains "match-all has MATCH line" "MATCH    irsa-external-dns"
assert_contains "match-all summary 0 MISMATCH" "0 MISMATCH"
assert_contains "match-all has SUMMARY" "=== SUMMARY:"

# ---- case: mismatch-pr66 (sub points at SA that does not exist) -------
echo "── case: mismatch-pr66 (Bug 5 exact replica) ────────────────"
run_validator mismatch-pr66 --all --ci
assert_rc "mismatch-pr66 exits 1 in --ci" 1
assert_contains "mismatch-pr66 has MISMATCH line" "MISMATCH"
assert_contains "mismatch-pr66 shows sa-exists: no" "sa-exists:  no"
assert_contains "mismatch-pr66 shows the PR #66 sub" \
  "system:serviceaccount:crossplane-system:upbound-provider-family-aws"
assert_contains "mismatch-pr66 surfaces hash-suffixed pod-sa" \
  "provider-family-aws-24aaab54a3a0"

# Same fixture without --ci → still MISMATCH but exit 0 (per spec §5.4).
run_validator mismatch-pr66 --all
assert_rc "mismatch-pr66 without --ci exits 0" 0
assert_contains "mismatch-pr66 without --ci still shows MISMATCH" "MISMATCH"

# ---- case: stale-pod-pr68 (correct SA, wrong pod SA) ------------------
echo "── case: stale-pod-pr68 (PR #68 stale-pod sub-class) ────────"
run_validator stale-pod-pr68 --all --ci
assert_rc "stale-pod-pr68 exits 1 in --ci" 1
assert_contains "stale-pod-pr68 MISMATCH despite annotation ok" "MISMATCH"
assert_contains "stale-pod-pr68 annotation-ok: yes" "annotation-ok: yes"
assert_contains "stale-pod-pr68 pod-sa shows old hash" \
  "provider-family-aws-24aaab54a3a0"
assert_contains "stale-pod-pr68 wrong-SA arrow" \
  "← pod is running under wrong SA"

# ---- case: multi-subject (ArgoCD pattern: 2 SAs per role) -------------
echo "── case: multi-subject (ArgoCD two-SA pattern) ──────────────"
run_validator multi-subject --all --ci
assert_rc "multi-subject exits 1 in --ci (one sub missing)" 1
assert_contains "multi-subject shows argocd-server MATCH" \
  "system:serviceaccount:argocd:argocd-server"
assert_contains "multi-subject shows application-controller line" \
  "system:serviceaccount:argocd:argocd-application-controller"
# Both subjects in output; one MATCH, one MISMATCH.
N_MATCH=$(echo "$LAST_OUT" | grep -c "^MATCH" || true)
N_MISMATCH=$(echo "$LAST_OUT" | grep -c "^MISMATCH" || true)
if [ "$N_MATCH" -ge 1 ] && [ "$N_MISMATCH" -ge 1 ]; then
  pass "multi-subject has both MATCH and MISMATCH"
else
  fail "multi-subject has both MATCH and MISMATCH" \
       "got MATCH=$N_MATCH MISMATCH=$N_MISMATCH"
fi

# ---- case: getrole-error (fail-soft per role) -------------------------
echo "── case: getrole-error (fail-soft fleet sweep) ──────────────"
run_validator getrole-error --all --ci
assert_rc "getrole-error exits 0 in --ci (0 MISMATCH)" 0
assert_contains "getrole-error has ERROR line for broken role" \
  "ERROR    irsa-broken"
assert_contains "getrole-error shows underlying iam:GetRole failure" \
  "iam:GetRole failed"
# Critical: the second (good) role must still process — proves fail-soft.
assert_contains "getrole-error still processes irsa-external-dns" \
  "MATCH    irsa-external-dns"
assert_contains "getrole-error summary reports 1 ERROR + 1 MATCH" \
  "1 MATCH  0 MISMATCH  0 WARN  1 ERROR"

# ---- case: unparseable-sub (WARN, not abort) --------------------------
echo "── case: unparseable-sub (malformed trust sub) ──────────────"
run_validator unparseable-sub --all --ci
assert_rc "unparseable-sub exits 0 (WARN is informational)" 0
assert_contains "unparseable-sub emits WARN" "WARN"
assert_contains "unparseable-sub names the unparseable sub" \
  "WARN: unparseable sub claim: not-a-valid-sub-claim"

# ---- case: --role single-role mode ------------------------------------
echo "── case: --role single-role mode ────────────────────────────"
LAST_OUT=$(IRSA_VALIDATOR_MOCK_DIR="$FIX/match-all" \
  python3 "$SCRIPT" --role irsa-external-dns 2>&1)
LAST_RC=$?
assert_rc "--role mode exits 0" 0
assert_contains "--role mode processes the named role" \
  "MATCH    irsa-external-dns"
assert_contains "--role mode header still emitted" "=== IRSA TRUST VALIDATOR"

# Single bad-role ARN should report ERROR + exit 1 only with --ci.
# Re-use getrole-error fixture's broken role.
LAST_OUT=$(IRSA_VALIDATOR_MOCK_DIR="$FIX/getrole-error" \
  python3 "$SCRIPT" --role arn:aws:iam::123456789012:role/irsa-broken 2>&1)
LAST_RC=$?
assert_rc "--role with bad ARN exits 0 without --ci" 0
assert_contains "--role bad ARN line prefixed ERROR" "ERROR    irsa-broken"

summary
