#!/usr/bin/env bash
# Entry point for the unit-test suite. Wires up all tests/unit/test_*.sh
# scripts, runs them, and exits non-zero if any test failed.
#
# Invoked by:
#   - .github/workflows/terraform-test.yml on (phase=test, action=test-unit)
#   - developers running tests locally: `tests/unit/run.sh`

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

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

run_suite tests/unit/test_compute_gates.sh
run_suite tests/unit/test_irsa_helm_linkage.sh
run_suite tests/unit/test_iam_required_actions.sh
run_suite tests/unit/test_eks_module_defaults.sh
run_suite tests/unit/test_helm_render.sh
run_suite tests/unit/test_post_comment.sh

echo ""
if [ "$OVERALL" -eq 0 ]; then
  echo "ALL UNIT TESTS PASSED"
else
  echo "SOME UNIT TESTS FAILED"
fi
exit "$OVERALL"
