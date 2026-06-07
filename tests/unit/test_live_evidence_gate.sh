#!/usr/bin/env bash
# Unit tests for the FAIL-closed live-evidence gate (FINAL-PLAN §4.3).
#
# Hermetic — injects mocked Actions-API evidence via LIVE_EVIDENCE_FIXTURE, so
# the gate LOGIC is exercised with no network. Asserts the gate is FAIL-closed,
# profile-aware (a change re-arms full; verify-only cannot masquerade as full),
# account/cluster-keyed, bootstrap-fresh, and that the config-only trigger maps
# crossplane/**/policies/** edits to a `full` requirement.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

GATE=.github/scripts/live-evidence-gate.sh
PROF=.github/scripts/required-profile-for-changes.sh
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

SHA=abc123def456
ACCT=695454131301
CLUS=k8-platform-mgmt

# write_fixture <name> <json-array>
fix() { printf '%s' "$2" > "$TMP/$1.json"; echo "$TMP/$1.json"; }

# gate_rc <fixture> <required-profile> [bootstrap-after] — run, echo exit code.
gate_rc() {
  local f="$1" req="$2" boot="${3:-}"
  local -a extra=(); [ -n "$boot" ] && extra=(--bootstrap-after "$boot")
  set +e
  LIVE_EVIDENCE_FIXTURE="$f" bash "$GATE" \
    --config-sha "$SHA" --account "$ACCT" --cluster "$CLUS" \
    --required-profile "$req" "${extra[@]}" >/dev/null 2>&1
  local rc=$?; set -e; echo "$rc"
}

GREEN_FULL=$(fix green_full "[{\"run_id\":1,\"sha\":\"$SHA\",\"account\":\"$ACCT\",\"cluster\":\"$CLUS\",\"profile\":\"full\",\"conclusion\":\"success\",\"created_at\":\"2026-06-07T07:00:00Z\"}]")
GREEN_VONLY=$(fix green_vonly "[{\"run_id\":2,\"sha\":\"$SHA\",\"account\":\"$ACCT\",\"cluster\":\"$CLUS\",\"profile\":\"verify-only\",\"conclusion\":\"success\",\"created_at\":\"2026-06-07T07:00:00Z\"}]")
EMPTY=$(fix empty "[]")

echo "── evidence: FAIL-closed on no evidence (bootstrap case) ─────"
assert_eq "no evidence ⇒ RED (exit 1)" 1 "$(gate_rc "$EMPTY" full)"

echo ""
echo "── evidence: a fresh green full run ⇒ GREEN ──────────────────"
assert_eq "full evidence satisfies full ⇒ exit 0" 0 "$(gate_rc "$GREEN_FULL" full)"
assert_eq "full evidence satisfies verify-only ⇒ exit 0" 0 "$(gate_rc "$GREEN_FULL" verify-only)"

echo ""
echo "── evidence: verify-only cannot masquerade as full ───────────"
assert_eq "verify-only evidence does NOT satisfy full ⇒ RED" 1 "$(gate_rc "$GREEN_VONLY" full)"
assert_eq "verify-only evidence satisfies verify-only ⇒ exit 0" 0 "$(gate_rc "$GREEN_VONLY" verify-only)"

echo ""
echo "── evidence: account / cluster / sha keying ──────────────────"
WRONG_ACCT=$(fix wrong_acct "[{\"run_id\":3,\"sha\":\"$SHA\",\"account\":\"000000000000\",\"cluster\":\"$CLUS\",\"profile\":\"full\",\"conclusion\":\"success\",\"created_at\":\"2026-06-07T07:00:00Z\"}]")
WRONG_CLUS=$(fix wrong_clus "[{\"run_id\":4,\"sha\":\"$SHA\",\"account\":\"$ACCT\",\"cluster\":\"other-cluster\",\"profile\":\"full\",\"conclusion\":\"success\",\"created_at\":\"2026-06-07T07:00:00Z\"}]")
WRONG_SHA=$(fix wrong_sha "[{\"run_id\":5,\"sha\":\"deadbeef\",\"account\":\"$ACCT\",\"cluster\":\"$CLUS\",\"profile\":\"full\",\"conclusion\":\"success\",\"created_at\":\"2026-06-07T07:00:00Z\"}]")
assert_eq "different account ⇒ RED" 1 "$(gate_rc "$WRONG_ACCT" full)"
assert_eq "different cluster ⇒ RED" 1 "$(gate_rc "$WRONG_CLUS" full)"
assert_eq "different sha ⇒ RED"     1 "$(gate_rc "$WRONG_SHA" full)"

echo ""
echo "── evidence: a failed run is not evidence ────────────────────"
FAILED=$(fix failed "[{\"run_id\":6,\"sha\":\"$SHA\",\"account\":\"$ACCT\",\"cluster\":\"$CLUS\",\"profile\":\"full\",\"conclusion\":\"failure\",\"created_at\":\"2026-06-07T07:00:00Z\"}]")
assert_eq "conclusion=failure ⇒ RED" 1 "$(gate_rc "$FAILED" full)"

echo ""
echo "── evidence: must be NEWER than account bootstrap ────────────"
# evidence at 07:00 but bootstrap at 08:00 ⇒ stale ⇒ RED (rotated account)
assert_eq "evidence older than bootstrap ⇒ RED" 1 "$(gate_rc "$GREEN_FULL" full 2026-06-07T08:00:00Z)"
assert_eq "evidence newer than bootstrap ⇒ GREEN" 0 "$(gate_rc "$GREEN_FULL" full 2026-06-07T06:00:00Z)"

echo ""
echo "── evidence: config-only trigger maps to a 'full' requirement ─"
assert_eq "crossplane/** edit ⇒ full"  full        "$(printf 'crossplane/compositions/platform-cluster.yaml\n' | "$PROF" -)"
assert_eq "policies/** edit ⇒ full"    full        "$(printf 'policies/audit/foo.yaml\n' | "$PROF" -)"
assert_eq "docs-only edit ⇒ verify-only" verify-only "$(printf 'README.md\nai/handoff.md\n' | "$PROF" -)"
assert_eq "mixed (incl crossplane) ⇒ full" full     "$(printf 'README.md\ncrossplane/xrds/x.yaml\n' | "$PROF" -)"

echo ""
echo "── evidence: usage errors ────────────────────────────────────"
assert_exit_code "missing required-profile ⇒ usage error" 2 bash "$GATE" --config-sha "$SHA" --account "$ACCT" --cluster "$CLUS"
assert_exit_code "bad profile value ⇒ usage error" 2 bash "$GATE" --config-sha "$SHA" --account "$ACCT" --cluster "$CLUS" --required-profile bogus

assert_summary
