#!/usr/bin/env bash
# Derive the expected composed-MR coverage set from the committed v2
# Pipeline-mode Compositions, group/kind-keyed and version-stripped.
#
# FINAL-PLAN §4.5: the expected-coverage set is GENERATED (never hand-edited
# green); the human maintains only the registry of which test defends which
# kind (tests/coverage/registry.yaml). This script is the extractor + the
# drift gate that proves the committed oracle still matches what the
# Compositions declare.
#
# Usage:
#   derive-coverage.sh                 # print the derived group/kind set (sorted, unique)
#   derive-coverage.sh --check         # compare derived set vs the committed
#                                      # oracle; honor tests/coverage/mode
#                                      # (warn => print drift, exit 0;
#                                      #  enforce => exit 1 on drift).
#
# Extraction path (round-3 k8s-expert C2): MR kinds live at
#   .spec.pipeline[].input.resources[].base
# Key on GROUP/KIND with the apiVersion VERSION stripped, deduped — so a
# v1beta1->v1beta2 provider bump does NOT change the key (a silent coverage
# miss exactly when an upgrade is riskiest). The select(.base) + .input.
# resources[] path structurally cannot emit ClusterProviderConfig / function
# Input|Resources wrappers / the Composition doc kind, so no exclude-list is
# needed; one is kept commented as documentation of that fact.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSITIONS_DIR="${COVERAGE_COMPOSITIONS_DIR:-$ROOT/crossplane/compositions}"
ORACLE="${COVERAGE_ORACLE:-$ROOT/tests/coverage/expected-coverage.txt}"
MODE_FILE="${COVERAGE_MODE_FILE:-$ROOT/tests/coverage/mode}"

# The single extraction expression — MUST be byte-identical to the one the
# fixture-test (tests/unit/test_coverage_deriver.sh) asserts against the oracle.
EXTRACT='.spec.pipeline[]?.input.resources[]? | select(.base) | (.base.apiVersion | sub("/.*";"")) + "/" + .base.kind'

derive() {
  local dir="$1"
  local f
  for f in "$dir"/*.yaml; do
    [ -e "$f" ] || continue
    yq "$EXTRACT" "$f"
  done | sort -u
}

cmd="${1:-print}"
case "$cmd" in
  print|"")
    derive "$COMPOSITIONS_DIR"
    ;;
  --check)
    derived="$(derive "$COMPOSITIONS_DIR")"
    oracle="$(sort -u "$ORACLE")"
    mode="warn"
    [ -f "$MODE_FILE" ] && mode="$(tr -d '[:space:]' < "$MODE_FILE")"
    if [ "$derived" = "$oracle" ]; then
      echo "coverage: derived set matches the committed oracle ($(printf '%s\n' "$derived" | grep -c . ) kinds) [mode=$mode]"
      exit 0
    fi
    echo "coverage: DRIFT between derived set and tests/coverage/expected-coverage.txt [mode=$mode]" >&2
    echo "--- only in derived (composition declares, oracle missing) ---" >&2
    comm -23 <(printf '%s\n' "$derived") <(printf '%s\n' "$oracle") >&2 || true
    echo "--- only in oracle (oracle claims, composition dropped) ---" >&2
    comm -13 <(printf '%s\n' "$derived") <(printf '%s\n' "$oracle") >&2 || true
    if [ "$mode" = "enforce" ]; then
      echo "coverage: FAIL (mode=enforce) — regenerate the oracle with 'derive-coverage.sh > tests/coverage/expected-coverage.txt' and register any new kind." >&2
      exit 1
    fi
    echo "coverage: WARN (mode=warn) — not failing the build; see the flip condition in tests/unit/test_coverage_deriver.sh." >&2
    exit 0
    ;;
  *)
    echo "derive-coverage.sh: unknown command '$cmd' (use: print | --check)" >&2
    exit 2
    ;;
esac
