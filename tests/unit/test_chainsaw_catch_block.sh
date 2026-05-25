#!/usr/bin/env bash
# SPEC-A4 enforcer: every chainsaw scenario MUST include the canonical
# `catch:` block from `tests/chainsaw/_lib/catch-block.yaml`.
#
# Checks for every `chainsaw-test.yaml` under `tests/chainsaw/`
# (excluding files under `tests/chainsaw/_lib/`):
#
#   1. `.spec.catch` is a non-empty list with length >= 3.
#   2. The list contains operations of type `describe`, `script`, AND
#      `events`.
#   3. Structural comparison against `_lib/catch-block.yaml`: the only
#      field that may differ is the first `describe.kind` (per-scenario
#      XR-kind override). Drift in any other field fails the test.
#   4. The meta-test scenario `tests/chainsaw/meta-catch-fires/` exists
#      and carries the canonical block (prevents accidental deletion).
#
# Pure-local: requires `yq` on PATH (either Mike Farah Go yq v4 — what
# CI installs — or Python yq / jq-style — what many local dev boxes
# carry by default). Detected at runtime.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

LIB=tests/chainsaw/_lib/catch-block.yaml
SENTINEL_KIND="__SPEC_A4_KIND__"

# ---- yq variant detection ------------------------------------------------
#
# Mike Farah's yq self-identifies as `yq (https://github.com/mikefarah/yq/)`.
# Python yq prints `yq <version>` only. Both export `yq` on PATH; the
# expression language is incompatible, so we branch.
if ! command -v yq >/dev/null 2>&1; then
  _fail "yq_available" "yq not on PATH (need Mike Farah Go yq v4 or Python yq)"
  assert_summary; exit 1
fi
_pass "yq_available"

YQ_VARIANT=python
if yq --version 2>&1 | grep -q mikefarah; then
  YQ_VARIANT=mikefarah
fi
_pass "yq_variant_detected (${YQ_VARIANT})"

# Per-variant primitives. Each emits a single canonical-form string for
# structural comparison: JSON, keys sorted, describe.kind normalized to
# the sentinel.
canonicalize_catch() {
  # $1 = file, $2 = top-level yq path expression to the catch list
  local f="$1" path="$2"
  if [ "$YQ_VARIANT" = "mikefarah" ]; then
    # Mike Farah: 1) replace describe.kind via with(select),
    # 2) emit JSON, 3) pipe through python -m json.tool --sort-keys
    #    for canonical key ordering (Mike Farah's `sort_keys` is .. heavy).
    yq "${path} |= map(with(select(has(\"describe\")); .describe.kind = \"${SENTINEL_KIND}\")) | ${path}" \
      "$f" -o=json -I=0 2>/dev/null \
      | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), sort_keys=True))' 2>/dev/null
  else
    # Python yq (jq under the hood) — straightforward jq expression.
    yq -c -S "${path} | map(if has(\"describe\") then .describe.kind = \"${SENTINEL_KIND}\" else . end)" \
      "$f" 2>/dev/null
  fi
}

catch_length() {
  local f="$1"
  if [ "$YQ_VARIANT" = "mikefarah" ]; then
    yq '.spec.catch | length' "$f" 2>/dev/null
  else
    yq -r '.spec.catch | length' "$f" 2>/dev/null
  fi
}

catch_op_keys() {
  local f="$1"
  if [ "$YQ_VARIANT" = "mikefarah" ]; then
    yq '.spec.catch[] | keys | .[]' "$f" 2>/dev/null
  else
    yq -r '.spec.catch[] | keys[]' "$f" 2>/dev/null
  fi
}

# ---- canonical block parses ---------------------------------------------
if [ ! -f "$LIB" ]; then
  _fail "lib_catch_block_exists" "$LIB not found"
  assert_summary; exit 1
fi
_pass "lib_catch_block_exists"

CANONICAL=$(canonicalize_catch "$LIB" '.catch')
if [ -z "$CANONICAL" ] || [ "$CANONICAL" = "null" ]; then
  _fail "canonical_block_parses" "could not canonicalize .catch from $LIB"
  assert_summary; exit 1
fi
_pass "canonical_block_parses"

# ---- discover scenarios --------------------------------------------------
#
# `find` walks every chainsaw-test.yaml under tests/chainsaw/. We filter
# out anything whose path contains `/tests/chainsaw/_lib/` (the library
# directory holds the canonical fragment, not a scenario).
SCENARIOS=$(
  find tests/chainsaw -type f -name 'chainsaw-test.yaml' \
    | grep -v '/tests/chainsaw/_lib/' \
    | sort
)

if [ -z "$SCENARIOS" ]; then
  _fail "scenarios_discovered" "no chainsaw-test.yaml files found"
  assert_summary; exit 1
fi
SCENARIO_COUNT=$(echo "$SCENARIOS" | wc -l | tr -d ' ')
_pass "scenarios_discovered (${SCENARIO_COUNT} files)"

# ---- per-scenario checks -------------------------------------------------
META_SEEN=0
while IFS= read -r f; do
  case "$f" in
    *meta-catch-fires/chainsaw-test.yaml) META_SEEN=1 ;;
  esac

  # 1. catch list length >= 3
  len=$(catch_length "$f")
  if [ -z "$len" ] || [ "$len" = "null" ]; then
    _fail "catch_length_${f}" "expected .spec.catch length >= 3, got '${len}' (missing block?)"
    continue
  fi
  if [ "$len" -lt 3 ] 2>/dev/null; then
    _fail "catch_length_${f}" "expected .spec.catch length >= 3, got '${len}'"
    continue
  fi
  _pass "catch_length_${f}"

  # 2. contains describe + script + events
  ops=$(catch_op_keys "$f" | sort -u | tr '\n' ',')
  MISSING=0
  for required in describe script events; do
    case ",${ops}" in
      *",${required},"*) ;;
      *)
        _fail "catch_has_${required}_${f}" "missing operation type '${required}' (saw: ${ops%,})"
        MISSING=1
        ;;
    esac
  done
  [ "$MISSING" = "0" ] && _pass "catch_has_describe_script_events_${f}"

  # 3. structural diff against canonical (kind-normalized)
  scenario_norm=$(canonicalize_catch "$f" '.spec.catch')
  if [ "$scenario_norm" = "$CANONICAL" ]; then
    _pass "catch_structurally_matches_canonical_${f}"
  else
    _fail "catch_structurally_matches_canonical_${f}" \
      "drift vs $LIB — only describe.kind may differ"
  fi
done <<< "$SCENARIOS"

# 4. meta-test exists
if [ "$META_SEEN" = "1" ]; then
  _pass "meta_test_present"
else
  _fail "meta_test_present" "tests/chainsaw/meta-catch-fires/chainsaw-test.yaml not found"
fi

assert_summary
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
