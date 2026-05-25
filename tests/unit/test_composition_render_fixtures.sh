#!/usr/bin/env bash
# SPEC-S9 §6.1 — assert every crossplane/xrds/*/render-fixtures/
# directory has the required files and that `crossplane render` against
# them matches the committed golden.
#
# Skip-with-warning when:
#   - the `crossplane` CLI is not on PATH (local dev without the tool)
#   - expected.yaml is absent (bootstrap-pending state, allowed until
#     the golden is generated on a host with crossplane installed —
#     deviation from SPEC-S9 §6.1 documented in the originating PR body)
#
# Hard failure when:
#   - input.yaml is missing
#   - crossplane CLI is present but the rendered output does not match
#     expected.yaml
#
# This runs in tests/unit/run.sh on every push via unit-tests.yml.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

HELPER="scripts/composition-render.sh"

if [ ! -x "$HELPER" ]; then
  _fail "composition_render_helper_executable" "$HELPER missing or not executable"
  assert_summary
fi
_pass "composition_render_helper_executable"

# Determinism sub-test: byte-for-byte identical render across two
# back-to-back invocations. Defended contract: normalize_stream is
# pure; render itself is deterministic given a pinned UID input.
have_crossplane=1
if ! command -v crossplane >/dev/null 2>&1; then
  have_crossplane=0
  echo "  WARNING: crossplane CLI not on PATH — render tests will skip."
  echo "           Install crossplane to fully verify SPEC-S9; see"
  echo "           tests/chainsaw/run.sh for the install pattern."
fi

shopt -s nullglob
FIXTURES_DIRS=(crossplane/xrds/*/render-fixtures)
shopt -u nullglob

if [ "${#FIXTURES_DIRS[@]}" -eq 0 ]; then
  _fail "render_fixtures_dirs_exist" "no crossplane/xrds/*/render-fixtures/ found"
  assert_summary
fi
_pass "render_fixtures_dirs_exist"

for fixtures in "${FIXTURES_DIRS[@]}"; do
  name=$(basename "$(dirname "$fixtures")")
  xrd="crossplane/xrds/${name}.yaml"
  comp="crossplane/compositions/${name}.yaml"

  # ---- Static checks (run regardless of CLI presence) -----------------
  if [ -f "$xrd" ]; then
    _pass "${name}_xrd_present"
  else
    _fail "${name}_xrd_present" "$xrd missing"
    continue
  fi

  if [ -f "$comp" ]; then
    _pass "${name}_composition_present"
  else
    _fail "${name}_composition_present" "$comp missing"
    continue
  fi

  if [ -s "$fixtures/input.yaml" ]; then
    _pass "${name}_input_yaml_present"
  else
    _fail "${name}_input_yaml_present" "$fixtures/input.yaml missing or empty"
    continue
  fi

  # ---- Render check (requires crossplane CLI) -------------------------
  if [ "$have_crossplane" -eq 0 ]; then
    echo "  SKIP: ${name}_render_matches_golden (crossplane CLI absent)"
    continue
  fi

  if [ ! -s "$fixtures/expected.yaml" ]; then
    echo "  SKIP: ${name}_render_matches_golden (expected.yaml not yet bootstrapped)"
    echo "        Run: $HELPER --xrd $xrd --comp $comp --fixtures $fixtures/"
    echo "        and redirect output to $fixtures/expected.yaml to bootstrap."
    continue
  fi

  out=$("$HELPER" --xrd "$xrd" --comp "$comp" --fixtures "$fixtures/" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    _pass "${name}_render_matches_golden"
  else
    _fail "${name}_render_matches_golden" "exit $rc; output:
$out"
  fi

  # Determinism re-render: render twice, compare. Asserts the
  # normalize_stream output is byte-identical across runs.
  out2=$("$HELPER" --xrd "$xrd" --comp "$comp" --fixtures "$fixtures/" 2>&1)
  if [ "$out" = "$out2" ]; then
    _pass "${name}_render_deterministic"
  else
    _fail "${name}_render_deterministic" "two back-to-back renders differ"
  fi
done

assert_summary
