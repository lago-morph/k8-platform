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
run_suite tests/unit/test_irsa_trust_validator.sh
run_suite tests/unit/test_iam_required_actions.sh
run_suite tests/unit/test_eks_module_defaults.sh
run_suite tests/unit/test_helm_render.sh
run_suite tests/unit/test_post_comment.sh
run_suite tests/unit/test_kyverno_policy_lint.sh
run_suite tests/unit/test_chainsaw_kind_config.sh
run_suite tests/unit/test_chainsaw_catch_block.sh
run_suite tests/unit/test_chainsaw_golden_files_present.sh
run_suite tests/unit/test_golden_no_volatile_fields.sh
run_suite tests/unit/test_golden_has_spec_forProvider.sh
run_suite tests/unit/test_chainsaw_assert_references_golden.sh
run_suite tests/unit/test_golden_region_uses_binding.sh
run_suite tests/unit/test_chainsaw_golden_catches_bug4.sh
run_suite tests/unit/test_chainsaw_tag_chars.sh
run_suite tests/unit/test_chainsaw_xr_conditions_complete.sh
run_suite tests/unit/test_chainsaw_script_shell_portable.sh
run_suite tests/unit/test_chainsaw_asm_cleanup.sh
run_suite tests/unit/test_platform_secret_xrd.sh
run_suite tests/unit/test_platform_secret_composition.sh
run_suite tests/unit/test_platform_cluster_xrd.sh
run_suite tests/unit/test_platform_cluster_composition.sh
run_suite tests/unit/test_composition_string_transform_type.sh
run_suite tests/unit/test_composition_render_fixtures.sh
run_suite tests/unit/test_composition_render_catches_bug4.sh
run_suite tests/unit/test_composition_render_diff_detected.sh
run_suite tests/unit/test_composition_render_no_golden_exit0.sh
run_suite tests/unit/test_composition_render_version_pin.sh
run_suite tests/unit/test_argocd_app_revision_pinned.sh
run_suite tests/unit/test_argocd_bootstrap.sh
run_suite tests/unit/test_diag_component.sh
run_suite tests/unit/test_shell_readonly_var_assignment.sh
run_suite tests/unit/test_integration_scripts_strict_mode.sh
run_suite tests/unit/test_whereami.sh
run_suite tests/unit/test_runbook_apply_zero_resources.sh
run_suite tests/unit/test_wait_for_claim.sh
run_suite tests/unit/test_crossplane_trace.sh
run_suite tests/unit/test_kubeconform_manifests.sh

echo ""
if [ "$OVERALL" -eq 0 ]; then
  echo "ALL UNIT TESTS PASSED"
else
  echo "SOME UNIT TESTS FAILED"
fi
exit "$OVERALL"
