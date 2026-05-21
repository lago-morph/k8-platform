#!/usr/bin/env bash
# Compute per-step gate booleans from (event, phase, action).
#
# Usage:
#   compute-gates.sh <event> <phase> <action>
#
#   <event>  github.event_name — e.g. push | workflow_dispatch | workflow_call
#   <phase>  base | management | test  (ignored for push events)
#   <action> see ai/testing-guidelines.md §6 + §8  (ignored for push events)
#
# Output (one key=value per line, suitable for $GITHUB_OUTPUT):
#   base_init      base_plan      base_apply      base_verify      base_destroy
#   mgmt_init      mgmt_plan      mgmt_apply      mgmt_verify      mgmt_destroy
#   test_unit      test_e2e
#
# Semantics:
#   push events  → base_init + base_plan + mgmt_init + mgmt_plan (plan-both)
#   phase=base  + action ∈
#       plan              → base_init, base_plan
#       apply             → base_init, base_plan, base_apply
#       verify            → base_init, base_verify
#       apply-and-verify  → base_init, base_plan, base_apply, base_verify
#       destroy           → base_init, base_destroy
#   phase=management + same action set, on the mgmt_* gates
#   phase=test  + action ∈
#       test-unit         → test_unit
#       test-e2e          → test_e2e
#
# Shared by:
#   - .github/workflows/terraform-test.yml (the live workflow)
#   - tests/unit/test_compute_gates.sh    (unit tests)

set -euo pipefail

EVENT="${1:-}"
PHASE="${2:-}"
ACTION="${3:-}"

bi=false; bp=false; ba=false; bv=false; bd=false
mi=false; mp=false; ma=false; mv=false; md=false
tu=false; te=false

if [ "$EVENT" = "push" ]; then
  bi=true; bp=true; mi=true; mp=true
else
  case "$PHASE" in
    base)
      bi=true
      case "$ACTION" in
        plan)             bp=true ;;
        apply)            bp=true; ba=true ;;
        verify)           bv=true ;;
        apply-and-verify) bp=true; ba=true; bv=true ;;
        destroy)          bi=true; bd=true ;;
        *) echo "compute-gates: invalid action '$ACTION' for phase base" >&2; exit 2 ;;
      esac
      ;;
    management)
      mi=true
      case "$ACTION" in
        plan)             mp=true ;;
        apply)            mp=true; ma=true ;;
        verify)           mv=true ;;
        apply-and-verify) mp=true; ma=true; mv=true ;;
        destroy)          mi=true; md=true ;;
        *) echo "compute-gates: invalid action '$ACTION' for phase management" >&2; exit 2 ;;
      esac
      ;;
    test)
      case "$ACTION" in
        test-unit) tu=true ;;
        test-e2e)  te=true ;;
        *) echo "compute-gates: invalid action '$ACTION' for phase test" >&2; exit 2 ;;
      esac
      ;;
    "")
      echo "compute-gates: phase required when event is not 'push'" >&2; exit 2 ;;
    *)
      echo "compute-gates: invalid phase '$PHASE'" >&2; exit 2 ;;
  esac
fi

cat <<EOF
base_init=$bi
base_plan=$bp
base_apply=$ba
base_verify=$bv
base_destroy=$bd
mgmt_init=$mi
mgmt_plan=$mp
mgmt_apply=$ma
mgmt_verify=$mv
mgmt_destroy=$md
test_unit=$tu
test_e2e=$te
EOF
