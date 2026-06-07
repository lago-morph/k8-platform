#!/usr/bin/env bash
# Compute per-step gate booleans from (phase, action).
#
# Usage:
#   compute-gates.sh <phase> <action>
#
#   <phase>  base | management | test
#   <action> see ai/testing-guidelines.md §6
#
# Output (one key=value per line, suitable for $GITHUB_OUTPUT):
#   base_init      base_plan      base_apply      base_verify      base_destroy
#   mgmt_init      mgmt_plan      mgmt_apply      mgmt_verify      mgmt_destroy
#   mgmt_live_verify
#   test_unit      test_e2e
#
# mgmt_live_verify is a DERIVED gate: true iff (mgmt_apply OR mgmt_verify).
# It exists so the live verification suite (tests/live/run.sh, a STEP in the
# apply-and-verify job) fires on ANY management apply, not only on an explicit
# `verify`/`apply-and-verify`. Without it a bare `action=apply` brings the
# management cluster up with ZERO live verification (FINAL-PLAN §4.1, round-3
# sre C2). The workflow gates the live-suite step on this single derived value
# so "you cannot apply the management cluster without the live suite running"
# is mechanically true and unit-tested here (the orchestrator's own committed
# source — the single thing the test reads).
#
# Semantics:
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

PHASE="${1:-}"
ACTION="${2:-}"

bi=false; bp=false; ba=false; bv=false; bd=false
mi=false; mp=false; ma=false; mv=false; md=false
ml=false   # mgmt_live_verify — derived below as (ma OR mv)
tu=false; te=false

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
    echo "compute-gates: phase required" >&2; exit 2 ;;
  *)
    echo "compute-gates: invalid phase '$PHASE'" >&2; exit 2 ;;
esac

# Derived: the live verification suite must run on ANY management apply as well
# as on an explicit verify. Keep this as the sole computation of the live-verify
# gate so the workflow has one value to consume and the unit test one to assert.
if [ "$ma" = "true" ] || [ "$mv" = "true" ]; then ml=true; fi

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
mgmt_live_verify=$ml
test_unit=$tu
test_e2e=$te
EOF
