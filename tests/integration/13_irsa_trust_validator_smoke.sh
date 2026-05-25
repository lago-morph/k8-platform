#!/usr/bin/env bash
# 13: scripts/irsa_trust_validator.py --all live-cluster smoke test.
# SPEC-S3 §6. Fleet sweep MUST report 0 MISMATCH on a freshly applied
# management cluster — any MISMATCH means a latent Bug 5.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/test-lib.sh
. "$HERE/lib/test-lib.sh"

require_kube
require_aws

SCRIPT="$HERE/../../scripts/irsa_trust_validator.py"
if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: missing $SCRIPT"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 not on PATH"
  exit 1
fi

if ! python3 -c "import boto3" >/dev/null 2>&1; then
  skip "boto3 not installed — install via 'pip install boto3' for live mode"
fi

# Case 1: --all on the live cluster should complete and print SUMMARY.
note "running irsa_trust_validator.py --all"
set +e
OUT=$(python3 "$SCRIPT" --all 2>&1)
RC=$?
set -e
echo "$OUT"

if [ "$RC" -ne 0 ]; then
  ng "validator --all exited $RC (no --ci, should be 0)"
  exit 1
fi
ok "validator --all exits 0 without --ci"

if ! echo "$OUT" | grep -q "=== SUMMARY:"; then
  ng "missing === SUMMARY: line"
  exit 1
fi
ok "summary line present"

# Case 2: zero MISMATCH on a healthy cluster.
if echo "$OUT" | grep -qE "^MISMATCH"; then
  ng "MISMATCH present on live cluster — latent Bug 5 recurrence"
  echo "$OUT" | grep -E "^MISMATCH" | sed 's/^/  /'
  exit 1
fi
ok "no MISMATCH on live cluster"

# Case 3: --ci on a healthy cluster exits 0.
set +e
python3 "$SCRIPT" --all --ci >/dev/null 2>&1
CI_RC=$?
set -e
if [ "$CI_RC" -ne 0 ]; then
  ng "validator --all --ci exit=$CI_RC (expected 0 on healthy fleet)"
  exit 1
fi
ok "validator --all --ci exits 0"

echo ""
echo "  validator output (last 30 lines):"
echo "$OUT" | tail -30 | sed 's/^/    /'
