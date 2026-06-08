#!/usr/bin/env bash
# SPEC-C4 §6.3 / §7.1.1 unit-test backstop.
#
# For every chainsaw scenario directory whose chainsaw-test.yaml
# contains an `apply:` block that creates a `platform.k8-platform.io/*`
# claim (i.e. triggers Composition rendering), assert that:
#
#   1. The scenario has a non-empty `expected/` subdirectory.
#   2. `expected/` contains at least one `*.yaml` file.
#
# Catches "author added a new scenario, forgot the golden file" at
# unit-test time (before chainsaw runs in heavy CI).

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

# Discover scenarios that touch a Composition (apply a platform.*/v1alpha1
# claim). Exclude meta directories (`_meta/`, `_lib/`, `_smoke/`,
# `meta-catch-fires/`) — those are harness scaffolding, not user
# Compositions.
SCENARIOS=$(
  grep -lrE "apiVersion:[[:space:]]+platform\.k8-platform\.io/v1alpha1" \
    tests/chainsaw 2>/dev/null \
  | grep -v '/_lib/' \
  | grep -v '/_smoke/' \
  | grep -v '/_meta/' \
  | grep -v '/meta-catch-fires/' \
  | sort -u
)

if [ -z "$SCENARIOS" ]; then
  _fail "scenarios_discovered" "no Composition-touching chainsaw-test.yaml files found"
  assert_summary; exit 1
fi
COUNT=$(echo "$SCENARIOS" | wc -l | tr -d ' ')
_pass "scenarios_discovered (${COUNT} scenarios)"

while IFS= read -r f; do
  dir=$(dirname "$f")
  scenario_name=$(echo "$dir" | sed 's|tests/chainsaw/||')

  # platform-cluster/00-xrd-establishes uses --dry-run=server and does
  # NOT trigger a live Composition render — explicitly exempt per spec
  # §12 rollout.
  #
  # xdatabase/00-xrd-establishes is the same shape (dry-run XRD/admission
  # contract, no live render), so it is exempt for the same reason.
  #
  # (The former xdatabase/01-claim-creates-rds and 02-deletion-cleanup
  # real-AWS scenarios were excised — AGENTS §6.36, OI-2026-06-06-4 — along
  # with the nightly/non-gating lane. The XDatabase render contract is still
  # enforced by crossplane/xrds/xdatabase/render-fixtures/ (SPEC-S9) +
  # tests/unit/test_xdatabase_rds_composition.sh; its gating live behavioral
  # coverage moves to tests/live/ with the live-suite capstone.)
  case "$dir" in
    *platform-cluster/00-xrd-establishes*|*xdatabase/00-xrd-establishes*)
      _pass "golden_exempt_${scenario_name} (XRD-establishment, no live render)"
      continue
      ;;
  esac

  if [ ! -d "$dir/expected" ]; then
    _fail "golden_dir_present_${scenario_name}" \
      "no expected/ directory under $dir (SPEC-C4 §6.3)"
    continue
  fi
  _pass "golden_dir_present_${scenario_name}"

  yaml_count=$(find "$dir/expected" -maxdepth 1 -name '*.yaml' -type f | wc -l | tr -d ' ')
  if [ "$yaml_count" -lt 1 ]; then
    _fail "golden_yaml_present_${scenario_name}" \
      "no *.yaml files under $dir/expected/ (SPEC-C4 §6.3)"
  else
    _pass "golden_yaml_present_${scenario_name} (${yaml_count} file(s))"
  fi
done <<< "$SCENARIOS"

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
