#!/usr/bin/env bash
# phase-status.sh — live phase-state oracle (SPEC-S5).
#
# Walks phases 0–6, probes the live AWS + Kubernetes environment, and
# classifies each phase as not-coded / code-only / applied / verified.
# Treats ai/handoff.md as belief; derives state from live API calls.
#
# Usage:
#   scripts/phase-status.sh                       # human-readable table
#   scripts/phase-status.sh --json                # JSON snapshot to stdout
#   scripts/phase-status.sh --assert-phase N STATE  # exit 0 iff phase N is STATE
#   scripts/phase-status.sh --no-color            # suppress ANSI even on TTY
#   scripts/phase-status.sh --help                # this usage block
#
# Exit codes:
#   0   success; or --assert-phase match
#   1   --assert-phase: state mismatch
#   2   --assert-phase: unknown phase number or state argument; bad flag
#
# Design contract:
#   - Fail-soft: AWS/kubectl errors during probes never crash the script.
#   - Snapshot: --json also writes /tmp/phase-status-<ts>.json for drift diff.
#   - Account ID is queried at runtime; never hardcoded.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/_lib/aws-cli-helpers.sh
. "$SCRIPT_DIR/_lib/aws-cli-helpers.sh"

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
MODE="human"
NO_COLOR=0
ASSERT_PHASE=""
ASSERT_STATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      MODE="json"
      shift
      ;;
    --assert-phase)
      MODE="assert"
      ASSERT_PHASE="${2:-}"
      ASSERT_STATE="${3:-}"
      if [[ -z "$ASSERT_PHASE" || -z "$ASSERT_STATE" ]]; then
        echo "ERROR: --assert-phase requires <phase-number> <state>" >&2
        exit 2
      fi
      shift 3
      ;;
    --no-color)
      NO_COLOR=1
      shift
      ;;
    --help|-h)
      sed -n '2,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown flag: $1" >&2
      echo "Usage: $0 [--json|--assert-phase N STATE|--no-color|--help]" >&2
      exit 2
      ;;
  esac
done

VALID_STATES=("not-coded" "code-only" "applied" "verified")
is_valid_state() {
  local s="$1"
  for v in "${VALID_STATES[@]}"; do
    [[ "$s" == "$v" ]] && return 0
  done
  return 1
}

if [[ "$MODE" == "assert" ]]; then
  if ! [[ "$ASSERT_PHASE" =~ ^[0-6]$ ]]; then
    echo "ERROR: --assert-phase: phase must be 0..6 (got '$ASSERT_PHASE')" >&2
    exit 2
  fi
  if ! is_valid_state "$ASSERT_STATE"; then
    echo "ERROR: --assert-phase: state must be one of ${VALID_STATES[*]} (got '$ASSERT_STATE')" >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Pre-flight: region guard + account discovery (best effort, fail-soft)
# ---------------------------------------------------------------------------
REGION="$(aws_region)"
ACCOUNT="$(aws_account_id)"
CLUSTER="$(aws_eks_cluster)"

# Region guard (SPEC-S5 §12 rollout notes)
case "$REGION" in
  us-east-1|us-west-2) : ;;
  *)
    echo "WARN: AWS_REGION='$REGION' outside allowlist (us-east-1, us-west-2); probes may fail" >&2
    ;;
esac

# ---------------------------------------------------------------------------
# Color helpers (only when stdout is a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 && "$NO_COLOR" -eq 0 ]]; then
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_GREY=$'\033[90m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_GREY=""; C_RESET=""
fi

colorize_state() {
  case "$1" in
    verified)  printf '%s%s%s' "$C_GREEN"  "$1" "$C_RESET" ;;
    applied)   printf '%s%s%s' "$C_YELLOW" "$1" "$C_RESET" ;;
    code-only) printf '%s%s%s' "$C_CYAN"   "$1" "$C_RESET" ;;
    not-coded) printf '%s%s%s' "$C_GREY"   "$1" "$C_RESET" ;;
    *)         printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Helpers: classify and record probe results.
# Each probe sets three variables: STATE[N], SENTINEL[N], PROBE[N].
# ---------------------------------------------------------------------------
declare -a STATE SENTINEL PROBE
for i in 0 1 2 3 4 5 6; do
  STATE[$i]="not-coded"
  SENTINEL[$i]=""
  PROBE[$i]=""
done

# Wrapper: run a command with kubectl/aws errors silenced; returns rc.
silent() { "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Per-phase probes — each returns via STATE[N]/SENTINEL[N]/PROBE[N].
# ---------------------------------------------------------------------------

# Phase 0: base (Route53 zone matching *.realhandsonlabs.net + Cognito user pool)
probe_phase_0() {
  local has_tf=0
  [[ -d "$REPO_ROOT/terraform/base" ]] && has_tf=1

  local zones
  zones=$(aws route53 list-hosted-zones \
    --query "HostedZones[?contains(Name, 'realhandsonlabs.net')].Name" \
    --output text 2>/dev/null | tr -d '\n')

  if [[ -z "$zones" ]]; then
    if [[ $has_tf -eq 1 ]]; then
      STATE[0]="code-only"
      SENTINEL[0]="no Route53 zone for *.realhandsonlabs.net"
      PROBE[0]=""
    else
      STATE[0]="not-coded"
      SENTINEL[0]=""
      PROBE[0]=""
    fi
    return
  fi

  SENTINEL[0]="Route53 zone $zones"
  # Functional probe: at least one Cognito user pool exists
  local pools
  pools=$(aws cognito-idp list-user-pools --max-results 10 \
    --query 'UserPools[0].Id' --output text 2>/dev/null | grep -v '^None$' || true)
  if [[ -n "$pools" ]]; then
    STATE[0]="verified"
    PROBE[0]="Cognito pool found"
  else
    STATE[0]="applied"
    PROBE[0]="no Cognito pool"
  fi
}

# Phase 1: management EKS + ArgoCD
probe_phase_1() {
  local has_tf=0
  [[ -d "$REPO_ROOT/terraform/management" ]] && has_tf=1

  if ! silent aws eks describe-cluster --name k8-platform-mgmt --region "$REGION"; then
    if [[ $has_tf -eq 1 ]]; then
      STATE[1]="code-only"
      SENTINEL[1]="no EKS cluster k8-platform-mgmt"
      PROBE[1]=""
    else
      STATE[1]="not-coded"
      SENTINEL[1]=""
      PROBE[1]=""
    fi
    return
  fi
  SENTINEL[1]="EKS k8-platform-mgmt"

  # Functional probe: >=1 Ready node AND ArgoCD pod Running
  local nodes_ok=0 argo_ok=0
  local ready_count
  ready_count=$(kubectl get nodes --no-headers 2>/dev/null \
    | grep -c ' Ready ' || true)
  if [[ "${ready_count:-0}" -ge 1 ]]; then
    nodes_ok=1
  fi
  if kubectl get pod -n argocd --no-headers 2>/dev/null | grep -q 'Running'; then
    argo_ok=1
  fi
  if [[ $nodes_ok -eq 1 && $argo_ok -eq 1 ]]; then
    STATE[1]="verified"
    PROBE[1]="${ready_count} node(s) Ready, ArgoCD Running"
  else
    STATE[1]="applied"
    PROBE[1]="nodes_ok=$nodes_ok argo_ok=$argo_ok"
  fi
}

# Phase 2: xrds (PlatformSecret CRD + provider Healthy)
probe_phase_2() {
  local has_src=0
  [[ -d "$REPO_ROOT/crossplane" ]] && has_src=1

  if ! silent kubectl get crd platformsecrets.platform.k8-platform.io; then
    if [[ $has_src -eq 1 ]]; then
      STATE[2]="code-only"
      SENTINEL[2]="CRD platformsecrets absent"
      PROBE[2]=""
    else
      STATE[2]="not-coded"
      SENTINEL[2]=""
      PROBE[2]=""
    fi
    return
  fi
  SENTINEL[2]="CRD platformsecrets OK"

  # Functional probe: xplatformsecrets CRD + provider Healthy=True
  local healthy
  if ! silent kubectl get crd xplatformsecrets.platform.k8-platform.io; then
    STATE[2]="applied"
    PROBE[2]="xplatformsecrets CRD missing"
    return
  fi
  healthy=$(kubectl get provider.pkg/provider-family-aws \
    -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || true)
  if [[ "$healthy" == "True" ]]; then
    STATE[2]="verified"
    PROBE[2]="provider Healthy=True"
  else
    STATE[2]="applied"
    PROBE[2]="provider Healthy=${healthy:-unknown}"
  fi
}

# Phase 3: platform clusters (stub until phase 3 lands)
probe_phase_3() {
  if ! silent kubectl get crd platformclusters.platform.k8-platform.io; then
    STATE[3]="not-coded"
    SENTINEL[3]=""
    PROBE[3]=""
    return
  fi
  SENTINEL[3]="CRD platformclusters OK"
  # Phase 3 functional probe is a stub
  STATE[3]="applied"
  PROBE[3]="phase 3 functional probe not implemented"
}

# Phase 4: observability (Grafana — stub)
probe_phase_4() {
  if ! silent kubectl get helmrelease -n monitoring grafana; then
    STATE[4]="not-coded"
    SENTINEL[4]=""
    PROBE[4]=""
    return
  fi
  SENTINEL[4]="Grafana HelmRelease OK"
  STATE[4]="applied"
  PROBE[4]="phase 4 functional probe not implemented"
}

# Phase 5: auth (Keycloak — stub)
probe_phase_5() {
  if silent kubectl get deployment -n keycloak keycloak \
     || silent kubectl get helmrelease -n keycloak keycloak; then
    SENTINEL[5]="Keycloak workload OK"
    STATE[5]="applied"
    PROBE[5]="phase 5 functional probe not implemented"
  else
    STATE[5]="not-coded"
    SENTINEL[5]=""
    PROBE[5]=""
  fi
}

# Phase 6: workload (PlatformCluster claim)
probe_phase_6() {
  local claim_out claim_count
  claim_out=$(kubectl get platformcluster -A --no-headers 2>/dev/null || true)
  if [[ -z "$claim_out" ]]; then
    claim_count=0
  else
    claim_count=$(printf '%s\n' "$claim_out" | wc -l | tr -d ' ')
  fi
  if [[ "${claim_count:-0}" -lt 1 ]]; then
    STATE[6]="not-coded"
    SENTINEL[6]=""
    PROBE[6]=""
    return
  fi
  SENTINEL[6]="${claim_count} PlatformCluster claim(s)"
  local ready
  ready=$(kubectl get platformcluster -A \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$ready" == "True" ]]; then
    STATE[6]="verified"
    PROBE[6]="Claim Ready=True"
  else
    STATE[6]="applied"
    PROBE[6]="Claim Ready=${ready:-unknown}"
  fi
}

# ---------------------------------------------------------------------------
# Run all probes (fail-soft — never crash)
# ---------------------------------------------------------------------------
{ probe_phase_0; } 2>/dev/null || true
{ probe_phase_1; } 2>/dev/null || true
{ probe_phase_2; } 2>/dev/null || true
{ probe_phase_3; } 2>/dev/null || true
{ probe_phase_4; } 2>/dev/null || true
{ probe_phase_5; } 2>/dev/null || true
{ probe_phase_6; } 2>/dev/null || true

# ---------------------------------------------------------------------------
# JSON escape helper (for SENTINEL/PROBE strings)
# ---------------------------------------------------------------------------
json_escape() {
  local s="$1"
  # backslash first, then quote, then strip newlines/tabs
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

emit_phase_json() {
  local n="$1"
  local state="${STATE[$n]}"
  local sentinel_raw="${SENTINEL[$n]}"
  local probe_raw="${PROBE[$n]}"
  local sentinel_json probe_json
  if [[ -z "$sentinel_raw" ]]; then
    sentinel_json="null"
  else
    sentinel_json="\"$(json_escape "$sentinel_raw")\""
  fi
  if [[ -z "$probe_raw" ]]; then
    probe_json="null"
  else
    probe_json="\"$(json_escape "$probe_raw")\""
  fi
  printf '    "%s": { "state": "%s", "sentinel": %s, "probe": %s }' \
    "$n" "$state" "$sentinel_json" "$probe_json"
}

build_json() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local cluster_json
  if [[ -z "$CLUSTER" || "$CLUSTER" == "None" ]]; then
    cluster_json="null"
  else
    cluster_json="\"$(json_escape "$CLUSTER")\""
  fi
  local acct_json
  if [[ -z "$ACCOUNT" || "$ACCOUNT" == "UNKNOWN" ]]; then
    acct_json="null"
  else
    acct_json="\"$(json_escape "$ACCOUNT")\""
  fi
  {
    printf '{\n'
    printf '  "generated_at": "%s",\n' "$ts"
    printf '  "cluster": %s,\n' "$cluster_json"
    printf '  "region": "%s",\n' "$(json_escape "$REGION")"
    printf '  "account": %s,\n' "$acct_json"
    printf '  "phases": {\n'
    local first=1
    for n in 0 1 2 3 4 5 6; do
      if [[ $first -eq 1 ]]; then
        first=0
      else
        printf ',\n'
      fi
      emit_phase_json "$n"
    done
    printf '\n  }\n}\n'
  }
}

# ---------------------------------------------------------------------------
# Dispatch by mode
# ---------------------------------------------------------------------------
case "$MODE" in
  human)
    printf '%-5s  %-10s  %-38s  %s\n' "Phase" "State" "Sentinel" "Functional probe"
    printf '%-5s  %-10s  %-38s  %s\n' "-----" "----------" "--------------------------------------" "-------------------"
    for n in 0 1 2 3 4 5 6; do
      row_state="${STATE[$n]}"
      row_sent="${SENTINEL[$n]:-—}"
      row_probe="${PROBE[$n]:-—}"
      # Truncate sentinel for table readability
      if [[ ${#row_sent} -gt 38 ]]; then
        row_sent="${row_sent:0:35}..."
      fi
      # Strip newlines/tabs that would break the row layout
      row_sent="${row_sent//$'\n'/ }"
      row_probe="${row_probe//$'\n'/ }"
      printf '%-5s  %-10s  %-38s  %s\n' \
        "$n" "$(colorize_state "$row_state")" "$row_sent" "$row_probe"
    done
    ;;

  json)
    snapshot=$(build_json)
    echo "$snapshot"
    # Write snapshot file (best effort)
    ts=$(date -u +"%Y%m%dT%H%M%SZ")
    snapshot_path="/tmp/phase-status-${ts}.json"
    echo "$snapshot" > "$snapshot_path" 2>/dev/null || true
    ;;

  assert)
    actual="${STATE[$ASSERT_PHASE]}"
    if [[ "$actual" == "$ASSERT_STATE" ]]; then
      exit 0
    else
      echo "phase $ASSERT_PHASE: expected '$ASSERT_STATE', got '$actual'" >&2
      exit 1
    fi
    ;;
esac

exit 0
