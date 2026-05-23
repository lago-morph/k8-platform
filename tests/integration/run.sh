#!/usr/bin/env bash
# Integration test orchestrator. Runs every NN_*.sh script in numeric order,
# captures pass/fail/skip per test, and reports a summary.
#
# All scripts use a shared RUN_ID so cleanup is easy if needed:
#   kubectl get all -A -l test.k8-platform/integration=true

set -uo pipefail
cd "$(dirname "$0")"

RUN_ID="${RUN_ID:-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6 || echo $$)}"
export RUN_ID

PASS=0; FAIL=0; SKIP=0
declare -a FAILED_TESTS=()

for script in $(ls -1 [0-9][0-9]_*.sh | sort); do
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  $script   (RUN_ID=$RUN_ID)"
  echo "════════════════════════════════════════════════════════════════"
  set +e
  bash "$script"
  rc=$?
  set -e
  case "$rc" in
    0)  PASS=$((PASS+1)); echo "── $script: ok ─────────────────────────" ;;
    2)  SKIP=$((SKIP+1)); echo "── $script: SKIP (precondition missing)" ;;
    *)  FAIL=$((FAIL+1)); FAILED_TESTS+=("$script"); echo "── $script: FAIL (exit=$rc) ─────────────────────────" ;;
  esac
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  summary"
echo "════════════════════════════════════════════════════════════════"
echo "  pass: $PASS"
echo "  skip: $SKIP"
echo "  fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  failed tests:"
  for t in "${FAILED_TESTS[@]}"; do echo "    - $t"; done
  exit 1
fi
exit 0
