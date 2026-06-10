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
RUN_SCRIPTS=()   # every script run_suite executed — input to the completeness guard at the bottom

run_suite() {
  local script="$1"
  RUN_SCRIPTS+=("$script")
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

# L31: cross-file version-pin pairs held equal (argo chart/app pin etc.)
run_suite tests/unit/test_version_pin_consistency.sh
run_suite tests/unit/test_compute_gates.sh
run_suite tests/unit/test_irsa_helm_linkage.sh
run_suite tests/unit/test_argocd_controller_irsa.sh
run_suite tests/unit/test_irsa_trust_validator.sh
run_suite tests/unit/test_iam_required_actions.sh
run_suite tests/unit/test_eks_module_defaults.sh
run_suite tests/unit/test_kube_access.sh
run_suite tests/unit/test_helm_render.sh
run_suite tests/unit/test_post_comment.sh
run_suite tests/unit/test_kyverno_policy_lint.sh
run_suite tests/unit/test_kyverno_crd_kinds_qualified.sh
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
# burndown item 5: ADR-number collision backstop (pairs with the
# session-start fetch-and-warn + scripts/next-adr-number.sh)
run_suite tests/unit/test_adr_numbering.sh
# phase-3 spoke foundation (auto-007)
run_suite tests/unit/test_platform_spoke_appproject.sh
run_suite tests/unit/test_external_dns_disjoint_filters.sh
run_suite tests/unit/test_spoke_values_no_ephemeral.sh
run_suite tests/unit/test_hello_chart_render.sh
run_suite tests/unit/test_spoke_apps.sh
# ADR-0010: the cluster-facts contract lint (ApplicationSets may reference only
# contract keys; no hand-overlay markers; cloud-agnostic workload guard)
run_suite tests/unit/test_cluster_facts_contract.sh
# phase-4 observability (REQ-OBS-01..05)
run_suite tests/unit/test_hub_addons_appproject.sh
run_suite tests/unit/test_observability_apps.sh
# phase-6 first workload cluster (REQ-WL-01..05)
run_suite tests/unit/test_workload1_apps.sh
# management ingress cert coverage (origin/main)
run_suite tests/unit/test_management_ingress_cert_coverage.sh
# phase-5 auth (Keycloak)
run_suite tests/unit/test_keycloak_apps.sh
# phase-5 database (XDatabase XRD + RDS Composition, Keycloak DB)
run_suite tests/unit/test_xdatabase_xrd.sh
run_suite tests/unit/test_xdatabase_rds_composition.sh
run_suite tests/unit/test_keycloak_db_secret_contract.sh
run_suite tests/unit/test_keycloak_db_xr.sh
# auto-008 phase-3 spoke GitOps access (XSpokeAccess XRD + Composition + XR)
run_suite tests/unit/test_xspokeaccess.sh
# auto-013 test-overhaul P1: derived coverage manifest (FINAL-PLAN §4.5)
run_suite tests/unit/test_coverage_deriver.sh
run_suite tests/unit/test_live_orchestrator.sh
run_suite tests/unit/test_live_evidence_gate.sh
run_suite tests/unit/test_verifier_role_no_wildcards.sh
run_suite tests/unit/test_skip_register.sh
# burndown item 4: the live suite is WIRED/GATING/SCOPED into terraform-test.yml
run_suite tests/unit/test_live_suite_wired.sh
# auto-014 P3: account-mutex (DynamoDB lease) lib for serialized mutating runs
run_suite tests/unit/test_account_mutex.sh
# auto-014 P3: reaper friendly-fire-proofing decision logic (no AWS, no deletes)
run_suite tests/unit/test_reaper_select.sh
# auto-015-001 (OI-2026-06-08-1): IAM Resource:* narrowing — Sid-anchored source
# regression lint + the merge gate (RED until spoke validation commits the sentinel)
run_suite tests/unit/test_iam_resource_scoping.sh
run_suite tests/unit/test_iam_tightening_gate.sh
# auto-015 P5: guard-fired negative checks (hermetic, no cluster, no AWS)
run_suite tests/unit/test_negatives_guard_fired.sh
# auto-015 P4: instantiate-and-verify engine + the two instantiate checks
# (fake kubectl + fake aws; no real cluster, no real AWS)
run_suite tests/unit/test_instantiate_lib.sh
# auto-015 P3: reaper entrypoint (enumerate→decide→dry-run→delete; faked AWS)
run_suite tests/unit/test_reaper_run.sh
# forensics round 2 — repo-content lints (ai/LESSONS.md L9/L19/L25):
# SPEC-B5 account-ID hardcode lint; committed-prompt ban; root-clutter freeze
run_suite tests/unit/test_no_account_id_hardcoded.sh
run_suite tests/unit/test_no_next_session_prompt_files.sh
run_suite tests/unit/test_root_file_allowlist.sh

# ── completeness guard (fail-closed) ─────────────────────────────────────
# unit-tests.yml calls this runner the "catch-all … source of truth for
# completeness": a test file absent from the run_suite list above is gated
# NOWHERE — it exists, reads as coverage, and never runs (L30; retro
# 2026-06-10-218: test_cluster_facts_contract.sh passed locally and ran
# zero times in the suite until enumerated). A deliberate exclusion must
# carry a `# run_suite-exempt: <reason>` line in its header.
for f in tests/unit/test_*.sh; do
  ran=0
  for s in "${RUN_SCRIPTS[@]}"; do [ "$s" = "$f" ] && { ran=1; break; }; done
  [ "$ran" -eq 1 ] && continue
  if grep -q '^# run_suite-exempt: ..*' "$f"; then
    echo "NOTICE: $f not enumerated — $(grep -m1 '^# run_suite-exempt:' "$f")"
    continue
  fi
  echo "FAIL: $f exists but is not enumerated in tests/unit/run.sh."
  echo "      A test that never runs is silent non-coverage. Add"
  echo "      'run_suite $f' above, or a '# run_suite-exempt: <reason>'"
  echo "      line to the file's header if the exclusion is deliberate."
  OVERALL=1
done

echo ""
if [ "$OVERALL" -eq 0 ]; then
  echo "ALL UNIT TESTS PASSED"
else
  echo "SOME UNIT TESTS FAILED"
fi
exit "$OVERALL"
