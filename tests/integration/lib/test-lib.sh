#!/usr/bin/env bash
# Shared helpers for integration tests. Source from each NN_*.sh script.

set -uo pipefail

# ---- env defaults --------------------------------------------------------

RUN_ID="${RUN_ID:-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6 || echo $$)}"
KEEP="${KEEP:-0}"
VERBOSE="${VERBOSE:-0}"

# ---- printing ------------------------------------------------------------

log()  { echo "  $*"; }
note() { echo "  -- $*"; }
ok()   { echo "  PASS: $*"; }
ng()   { echo "  FAIL: $*"; return 1; }
skip() { echo "  SKIP: $*"; exit 0; }

trace() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "  + $*" >&2
  fi
  "$@"
}

# ---- preconditions -------------------------------------------------------

require_kube() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "FAIL: no Kubernetes cluster reachable. Run: aws eks update-kubeconfig --name k8-platform-mgmt"
    exit 2
  fi
}

require_aws() {
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "FAIL: AWS creds not working. Run scripts/sandbox-creds-check.sh."
    exit 2
  fi
}

require_ns() {
  local ns="$1"
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    skip "namespace $ns not present (component not installed?)"
  fi
}

discover_domain() {
  if [ -n "${TEST_DOMAIN:-}" ]; then echo "$TEST_DOMAIN"; return; fi
  aws route53 list-hosted-zones --query 'HostedZones[0].Name' --output text \
    | sed 's/\.$//'
}

discover_zone_id() {
  aws route53 list-hosted-zones --query 'HostedZones[0].Id' --output text \
    | sed 's@^/hostedzone/@@'
}

# ---- waits ---------------------------------------------------------------

# wait_for "<description>" <max-seconds> <interval-seconds> -- <command...>
wait_for() {
  local desc="$1" max="$2" interval="$3"
  shift 3
  [ "$1" = "--" ] && shift
  local start now elapsed
  start=$(date +%s)
  while true; do
    if "$@" >/dev/null 2>&1; then
      now=$(date +%s); elapsed=$((now - start))
      log "✓ $desc (after ${elapsed}s)"
      return 0
    fi
    now=$(date +%s); elapsed=$((now - start))
    if [ "$elapsed" -ge "$max" ]; then
      log "✗ $desc — gave up after ${elapsed}s"
      return 1
    fi
    [ "$VERBOSE" -eq 1 ] && log "   waiting ($elapsed/${max}s) for: $desc"
    sleep "$interval"
  done
}

# Cleanup hook helpers — register with: add_cleanup "kubectl delete ..."
declare -a CLEANUP_CMDS=()
add_cleanup() { CLEANUP_CMDS+=("$1"); }
run_cleanup() {
  if [ "$KEEP" = "1" ]; then
    note "KEEP=1, skipping cleanup. Leftovers tagged RUN_ID=$RUN_ID"
    return 0
  fi
  for cmd in "${CLEANUP_CMDS[@]}"; do
    [ "$VERBOSE" -eq 1 ] && log "cleanup: $cmd"
    eval "$cmd" >/dev/null 2>&1 || true
  done
}
trap 'run_cleanup' EXIT

# ---- common labels -------------------------------------------------------

INTEG_LABEL="test.k8-platform/integration=true"
INTEG_LABEL_KEY="${INTEG_LABEL%=*}"
