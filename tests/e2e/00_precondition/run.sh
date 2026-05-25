#!/usr/bin/env bash
# E2e precondition gate (SPEC-S4 §5).
# Asserts the live environment matches terraform.tfvars before any
# destructive e2e test runs against the wrong sandbox.
#
# Usage:
#   tests/e2e/00_precondition/run.sh
#
# Exits 0 if account and region match terraform.tfvars.json.
# Exits 1 with a clear message if they diverge.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

echo "── e2e precondition gate (SPEC-S4) ────────────────────────────────"

# Collect live environment state
ENV=$("$REPO_ROOT/scripts/whereami.sh" --json) || {
  echo "FAIL: whereami.sh failed (credentials absent or timed out)." >&2
  exit 1
}

ACTUAL_ACCOUNT=$(echo "$ENV" | jq -r '.account')
ACTUAL_REGION=$(echo "$ENV"  | jq -r '.region')

echo "  live account : $ACTUAL_ACCOUNT"
echo "  live region  : $ACTUAL_REGION"

# If terraform.tfvars.json exists, compare account and region
TFVARS="$REPO_ROOT/terraform/terraform.tfvars.json"
if [[ -f "$TFVARS" ]]; then
  EXPECTED_ACCOUNT=$(jq -r '.account_id // empty' "$TFVARS" 2>/dev/null || true)
  EXPECTED_REGION=$(jq  -r '.aws_region   // empty' "$TFVARS" 2>/dev/null || true)

  if [[ -n "$EXPECTED_ACCOUNT" && "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]]; then
    echo "FAIL: wrong account. Expected $EXPECTED_ACCOUNT, got $ACTUAL_ACCOUNT" >&2
    exit 1
  fi
  if [[ -n "$EXPECTED_REGION" && "$ACTUAL_REGION" != "$EXPECTED_REGION" ]]; then
    echo "FAIL: wrong region. Expected $EXPECTED_REGION, got $ACTUAL_REGION" >&2
    exit 1
  fi
  echo "  tfvars match : ✓"
else
  echo "  tfvars       : not found (skipping account/region comparison)"
fi

echo "── precondition gate PASSED ────────────────────────────────────────"
exit 0
