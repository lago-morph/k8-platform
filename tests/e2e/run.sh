#!/usr/bin/env bash
# Entry point for the e2e-test suite. These tests require live AWS
# credentials in the environment (AWS_ACCESS_KEY_ID / SECRET_ACCESS_KEY
# / DEFAULT_REGION or AWS_REGION). They are read-only and cost nothing
# meaningful to run — strictly assertions about expected resources.
#
# Invoked by:
#   - .github/workflows/terraform-test.yml on (phase=test, action=test-e2e)
#   - developers: AWS_REGION=us-east-1 AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... tests/e2e/run.sh

set -uo pipefail
cd "$(dirname "$0")/../.."

# Normalise region env: workflow exports AWS_DEFAULT_REGION; some callers
# may set AWS_REGION instead. Mirror them so both names work in the suite.
if [ -z "${AWS_DEFAULT_REGION:-}" ] && [ -n "${AWS_REGION:-}" ]; then
  export AWS_DEFAULT_REGION="$AWS_REGION"
fi
if [ -z "${AWS_REGION:-}" ] && [ -n "${AWS_DEFAULT_REGION:-}" ]; then
  export AWS_REGION="$AWS_DEFAULT_REGION"
fi

OVERALL=0

run_suite() {
  local script="$1"
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  $script"
  echo "════════════════════════════════════════════════════════════"
  if bash "$script"; then
    echo "── $script PASSED ────────────────────────────────────────"
  else
    echo "── $script FAILED ────────────────────────────────────────"
    OVERALL=1
  fi
}

run_suite tests/e2e/test_aws_creds.sh
run_suite tests/e2e/test_route53_zone.sh
run_suite tests/e2e/test_state_backend.sh

echo ""
if [ "$OVERALL" -eq 0 ]; then
  echo "ALL E2E TESTS PASSED"
else
  echo "SOME E2E TESTS FAILED"
fi
exit "$OVERALL"
