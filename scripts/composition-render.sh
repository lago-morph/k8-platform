#!/usr/bin/env bash
# composition-render.sh — SPEC-S9 author-time dry-run helper.
#
# Runs `crossplane render` against an XRD + Composition + claim input,
# normalizes the output (strips non-deterministic fields), and diffs
# against a committed golden file. Catches function-input rejection
# (Bug 4 class — string transform missing `type: Format`) before the
# Composition reaches a cluster or chainsaw.
#
# Spec:    ai/brainstorming/specs/SPEC-S9-composition-render-dryrun.md
# Pairs:   SPEC-C4 (chainsaw golden-file assertions) — shares the same
#          normalization strategy so a future refactor can unify.
#
# Usage:
#   scripts/composition-render.sh \
#     --xrd  crossplane/xrds/platform-secret.yaml \
#     --comp crossplane/compositions/platform-secret.yaml \
#     --fixtures crossplane/xrds/platform-secret/render-fixtures/
#
#   scripts/composition-render.sh --all
#     Iterates every crossplane/xrds/*/render-fixtures/ directory.
#
#   scripts/composition-render.sh --help
#     Print usage and exit 0.
#
# Exit codes:
#   0 — all render outputs match their goldens (or bootstrap mode: no
#       expected.yaml present, output emitted)
#   1 — render output differs from golden (diff printed) OR crossplane
#       render itself returned non-zero (function-input rejection)
#   2 — invocation / setup error (missing CLI, missing files, bad flags)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_ENV="${REPO_ROOT}/tests/chainsaw/versions.env"

# ------------------------------------------------------------------------
# Diff-output budget. On mismatch a full multi-MR render can be thousands
# of lines; truncate at 200 to keep CI logs scannable.
# ------------------------------------------------------------------------
DIFF_TRUNCATE_LINES=200

usage() {
  cat <<'EOF'
scripts/composition-render.sh — author-time crossplane render dry-run

USAGE:
  composition-render.sh --xrd <file> --comp <file> --fixtures <dir>
  composition-render.sh --all
  composition-render.sh --help

FLAGS:
  --xrd <file>       CompositeResourceDefinition YAML
  --comp <file>      Composition YAML
  --fixtures <dir>   Directory containing input.yaml (the probe claim)
                     and optionally expected.yaml (the golden output).
                     If expected.yaml is absent the helper emits the
                     rendered stream and exits 0 (bootstrap mode).
  --all              Iterate every crossplane/xrds/*/render-fixtures/
                     directory, deriving --xrd / --comp / --fixtures
                     from the directory name. Used by the pre-commit
                     hook and the unit test.
  --help             Print this message and exit 0.

The function-patch-and-transform version is read from:
  tests/chainsaw/versions.env
(variable FUNCTION_PATCH_AND_TRANSFORM_VERSION — kept in sync with the
chainsaw harness so the two layers cannot drift apart).
EOF
}

err() { echo "ERROR: $*" >&2; }

# ------------------------------------------------------------------------
# Tool checks. crossplane CLI is mandatory; yq is mandatory for the
# normalization step.
# ------------------------------------------------------------------------
require_tools() {
  local missing=0
  if ! command -v crossplane >/dev/null 2>&1; then
    err "crossplane CLI not on PATH."
    err "Install: see https://docs.crossplane.io/latest/cli/ or the chainsaw bootstrap"
    err "         (tests/chainsaw/run.sh installs the matching version)."
    missing=1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    err "yq (mikefarah/yq) not on PATH."
    err "Install: https://github.com/mikefarah/yq"
    missing=1
  fi
  if [ "$missing" -ne 0 ]; then
    return 2
  fi
  return 0
}

# ------------------------------------------------------------------------
# Read the pinned function-patch-and-transform version from
# tests/chainsaw/versions.env. The spec names the variable
# FUNCTION_PT_VERSION; the on-disk file uses
# FUNCTION_PATCH_AND_TRANSFORM_VERSION. Accept either to remain
# robust against a future rename.
# ------------------------------------------------------------------------
read_function_version() {
  if [ ! -f "$VERSIONS_ENV" ]; then
    err "$VERSIONS_ENV not found — required for pinned function version."
    return 2
  fi
  # shellcheck disable=SC1090
  . "$VERSIONS_ENV"
  if [ -n "${FUNCTION_PATCH_AND_TRANSFORM_VERSION:-}" ]; then
    FUNC_VERSION="$FUNCTION_PATCH_AND_TRANSFORM_VERSION"
  elif [ -n "${FUNCTION_PT_VERSION:-}" ]; then
    FUNC_VERSION="$FUNCTION_PT_VERSION"
  else
    err "Neither FUNCTION_PATCH_AND_TRANSFORM_VERSION nor FUNCTION_PT_VERSION set in $VERSIONS_ENV"
    return 2
  fi
  echo "$FUNC_VERSION"
}

# ------------------------------------------------------------------------
# Read the pinned Crossplane version for the render-orchestrator image.
#
# `crossplane render` runs the actual composition rendering ("crossplane
# internal render") inside a Crossplane Docker image. That image defaults
# to the FLOATING `xpkg.crossplane.io/crossplane/crossplane:stable` tag,
# which resolves to the latest v1.x stable (e.g. v1.20.9) — a binary that
# has no `internal render` subcommand, so render fails with
# `unexpected argument internal`. We pin it to the SAME version as the
# management cluster's chart (CROSSPLANE_CHART_VERSION in versions.env) so
# the dry-run renders with the exact Crossplane the cluster runs. See
# OI-2026-06-06-1.
# ------------------------------------------------------------------------
read_crossplane_version() {
  if [ ! -f "$VERSIONS_ENV" ]; then
    err "$VERSIONS_ENV not found — required for pinned crossplane version."
    return 2
  fi
  # shellcheck disable=SC1090
  . "$VERSIONS_ENV"
  if [ -z "${CROSSPLANE_CHART_VERSION:-}" ]; then
    err "CROSSPLANE_CHART_VERSION not set in $VERSIONS_ENV"
    return 2
  fi
  # The chart version omits the leading `v` (e.g. 2.3.0); the render flag
  # and the crossplane image tag want it (v2.3.0).
  echo "v${CROSSPLANE_CHART_VERSION}"
}

# ------------------------------------------------------------------------
# Read the pinned function-environment-configs version from versions.env
# (FUNCTION_ENVIRONMENT_CONFIGS_VERSION). Only needed for Compositions
# whose pipeline references function-environment-configs.
# ------------------------------------------------------------------------
read_env_function_version() {
  if [ ! -f "$VERSIONS_ENV" ]; then
    err "$VERSIONS_ENV not found — required for pinned function version."
    return 2
  fi
  # shellcheck disable=SC1090
  . "$VERSIONS_ENV"
  if [ -z "${FUNCTION_ENVIRONMENT_CONFIGS_VERSION:-}" ]; then
    err "FUNCTION_ENVIRONMENT_CONFIGS_VERSION not set in $VERSIONS_ENV"
    return 2
  fi
  echo "$FUNCTION_ENVIRONMENT_CONFIGS_VERSION"
}

# ------------------------------------------------------------------------
# normalize_stream <input-yaml-stream-on-stdin>
#
# Strips fields that are non-deterministic between renders (status
# timestamps, ownerReferences with reconciler-injected UIDs,
# resourceVersion, etc.). Outputs the cleaned multi-document YAML
# stream on stdout.
#
# This is the load-bearing function: byte-determinism of the diff
# depends on it being idempotent and stable.
#
# Mirrors the normalization SPEC-C4 §5 will use so the two specs can
# share a fixture format.
# ------------------------------------------------------------------------
normalize_stream() {
  # `crossplane render` emits a multi-document stream whose DOCUMENT ORDER
  # is not stable across invocations: the composed-resource docs and the
  # diagnostic function `Result` docs can swap positions between two
  # back-to-back renders of the same input (observed for platform-secret —
  # the ExternalSecret and ASM Secret docs flip, as do the two
  # "not yet ready" Result messages). A golden-file diff must therefore be
  # order-independent, otherwise expected.yaml can never be a stable golden
  # and the determinism sub-test in
  # tests/unit/test_composition_render_fixtures.sh flakes the moment a
  # golden is bootstrapped. Normalization now:
  #   1. drops the render.crossplane.io Result docs (render-time readiness
  #      noise, not part of the composed-resource contract a golden pins),
  #   2. sorts the remaining docs by a stable (kind, name) key, and
  #   3. strips the non-deterministic per-field metadata as before.
  # (The XR's spec.crossplane.resourceRefs order was observed stable across
  # runs, so it is not re-sorted; revisit if a future render flakes on it.)
  # See auto-004 SPEC-S9 determinism fix.
  yq ea '
    [.]
    | map(select((.apiVersion // "") != "render.crossplane.io/v1beta1"))
    | sort_by(.kind + "/" + (.metadata.name // .metadata.generateName // ""))
    | .[]
    | del(
        .metadata.ownerReferences,
        .metadata.uid,
        .metadata.resourceVersion,
        .metadata.creationTimestamp,
        .metadata.generation,
        .metadata.managedFields,
        .metadata.annotations."crossplane.io/composition-resource-name",
        .status.conditions[]?.lastTransitionTime
      )
  ' -
}

# ------------------------------------------------------------------------
# render_one <xrd> <comp> <input>
#
# Invokes crossplane render and prints the multi-doc YAML stream on
# stdout. Captures stderr and re-emits on error. Uses the function
# binary identified by the pinned package version (function reference
# is sourced from the Composition itself — render auto-loads it from
# the OCI registry if a runtime is provided).
# ------------------------------------------------------------------------
render_one() {
  local xrd="$1" comp="$2" input="$3" required="${4:-}"
  local func_ver
  func_ver=$(read_function_version) || return 2
  local xp_ver
  xp_ver=$(read_crossplane_version) || return 2

  # crossplane render expects: <xr> <composition> <functions>
  # The "functions" arg is a YAML file describing the function packages
  # used. We construct it inline so the helper is self-contained.
  local fn_yaml
  fn_yaml=$(mktemp)
  cat >"$fn_yaml" <<EOF
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-patch-and-transform
  annotations:
    render.crossplane.io/runtime: Docker
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:${func_ver}
EOF

  # If the Composition's pipeline uses function-environment-configs, add
  # it to the functions file too, otherwise render rejects the unknown
  # functionRef. The EnvironmentConfig objects it reads are supplied via
  # --required-resources (the fixture's required-resources.yaml).
  local render_args=(--include-full-xr --include-function-results --crossplane-version "$xp_ver")
  if grep -q "function-environment-configs" "$comp"; then
    local env_ver
    env_ver=$(read_env_function_version) || return 2
    cat >>"$fn_yaml" <<EOF
---
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-environment-configs
  annotations:
    render.crossplane.io/runtime: Docker
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-environment-configs:${env_ver}
EOF
    if [ -n "$required" ] && [ -f "$required" ]; then
      render_args+=(--required-resources "$required")
    else
      err "Composition $comp uses function-environment-configs but no"
      err "required-resources.yaml found alongside the fixture ($required)."
      err "Supply the cluster-network EnvironmentConfig there (SPEC-S9)."
      rm -f "$fn_yaml"
      return 2
    fi
  fi

  local out rc
  out=$(crossplane render \
    "$input" "$comp" "$fn_yaml" \
    "${render_args[@]}" 2>&1)
  rc=$?
  rm -f "$fn_yaml"

  if [ "$rc" -ne 0 ]; then
    err "crossplane render failed (rc=$rc):"
    echo "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# ------------------------------------------------------------------------
# run_one <xrd> <comp> <fixtures-dir>
#
# Top-level per-Composition driver. Reads input.yaml, runs render,
# normalizes, diffs against expected.yaml. If expected.yaml is absent
# emits the rendered stream and exits 0 (bootstrap mode).
# ------------------------------------------------------------------------
run_one() {
  local xrd="$1" comp="$2" fixtures="$3"

  if [ ! -f "$xrd" ];  then err "XRD not found: $xrd";   return 2; fi
  if [ ! -f "$comp" ]; then err "Composition not found: $comp"; return 2; fi
  if [ ! -d "$fixtures" ]; then err "Fixtures dir not found: $fixtures"; return 2; fi

  local input="${fixtures%/}/input.yaml"
  local expected="${fixtures%/}/expected.yaml"
  # Optional: EnvironmentConfig(s) the Composition reads via
  # function-environment-configs, supplied to render as required resources.
  local required="${fixtures%/}/required-resources.yaml"

  if [ ! -f "$input" ]; then
    err "input.yaml not found: $input"
    return 2
  fi

  local rendered
  rendered=$(render_one "$xrd" "$comp" "$input" "$required") || return $?

  local normalized
  normalized=$(printf '%s\n' "$rendered" | normalize_stream)

  if [ ! -f "$expected" ]; then
    echo "$normalized"
    echo "" >&2
    echo "No expected.yaml found at $expected." >&2
    echo "Review output above and redirect to expected.yaml to create the golden." >&2
    return 0
  fi

  # Compare the freshly-normalized render against the stored golden AS-IS.
  # The golden was produced by this same helper's bootstrap path (already
  # normalized). normalize_stream is deterministic across renders but NOT
  # idempotent w.r.t. yq's multi-document separator emission, so
  # re-normalizing the golden here would spuriously differ from a single
  # normalize of a fresh render. Trust the stored golden; regenerate it via
  # bootstrap (delete expected.yaml, re-run) when the Composition changes.
  # See auto-004 SPEC-S9 determinism fix.
  local diff_out
  diff_out=$(diff -u \
    "$expected" \
    <(printf '%s\n' "$normalized")) || {
    err "rendered output differs from $expected"
    local lines
    lines=$(printf '%s\n' "$diff_out" | wc -l)
    if [ "$lines" -gt "$DIFF_TRUNCATE_LINES" ]; then
      printf '%s\n' "$diff_out" | head -n "$DIFF_TRUNCATE_LINES"
      echo "... ($((lines - DIFF_TRUNCATE_LINES)) more lines truncated)" >&2
      echo "Run scripts/composition-render.sh --fixtures $fixtures locally for the full diff." >&2
    else
      printf '%s\n' "$diff_out"
    fi
    return 1
  }

  echo "OK: rendered output matches $expected"
  return 0
}

# ------------------------------------------------------------------------
# run_all
#
# Iterates every crossplane/xrds/*/render-fixtures/ directory. The XRD
# and Composition paths are derived from the directory name:
#   crossplane/xrds/<NAME>/render-fixtures/
#     -> --xrd  crossplane/xrds/<NAME>.yaml
#     -> --comp crossplane/compositions/<NAME>.yaml
# ------------------------------------------------------------------------
run_all() {
  local overall=0 count=0
  local fixtures
  shopt -s nullglob
  for fixtures in "${REPO_ROOT}"/crossplane/xrds/*/render-fixtures; do
    count=$((count + 1))
    local name
    name=$(basename "$(dirname "$fixtures")")
    local xrd="${REPO_ROOT}/crossplane/xrds/${name}.yaml"
    local comp="${REPO_ROOT}/crossplane/compositions/${name}.yaml"
    echo ""
    echo "── ${name} ──────────────────────────────────────────────"
    if ! run_one "$xrd" "$comp" "$fixtures"; then
      overall=1
    fi
  done
  shopt -u nullglob
  if [ "$count" -eq 0 ]; then
    echo "No crossplane/xrds/*/render-fixtures/ directories found — nothing to do."
  fi
  return "$overall"
}

# ------------------------------------------------------------------------
# main — argument parsing.
# ------------------------------------------------------------------------
main() {
  local xrd="" comp="" fixtures="" all=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h)       usage; exit 0 ;;
      --xrd)           xrd="$2";       shift 2 ;;
      --comp)          comp="$2";      shift 2 ;;
      --fixtures)      fixtures="$2";  shift 2 ;;
      --all)           all=1;          shift ;;
      --)              shift; break ;;
      *)               err "unknown flag: $1"; usage; exit 2 ;;
    esac
  done

  require_tools || exit $?

  if [ "$all" -eq 1 ]; then
    run_all
    exit $?
  fi

  if [ -z "$xrd" ] || [ -z "$comp" ] || [ -z "$fixtures" ]; then
    err "--xrd, --comp and --fixtures are all required (or use --all)."
    usage
    exit 2
  fi

  run_one "$xrd" "$comp" "$fixtures"
  exit $?
}

main "$@"
