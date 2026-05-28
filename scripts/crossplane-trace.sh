#!/usr/bin/env bash
# crossplane-trace.sh — walk a claim → XR → managed-resource → atProvider chain
# and print .status.conditions at every layer. Read-only.
#
# Usage:
#   scripts/crossplane-trace.sh <kind>/<name> [-n <ns>] [--watch] [--json] [--timeout <s>]
#
# Modes (independent):
#   default  one-shot human-readable trace to stdout
#   --watch  re-print every $TRACE_INTERVAL (10s) until Ready=True or timeout
#   --json   single JSON snapshot to stdout (suitable for diffing across runs)
#
# Env:
#   AWS_REGION       (us-east-1, us-west-2 → AWS section enabled; other → skipped)
#   SKIP_AWS_OVERRIDE=1  force-skip the AWS / IRSA section (used by tests)
#   TRACE_INTERVAL   seconds between watch iterations (default 10)
#   KUBECTL          kubectl binary path (default `kubectl`)
#
# Spec: ai/brainstorming/specs/SPEC-S2-crossplane-trace.md
#
# Hard rules:
#   - No mutations: kubectl get + aws sts get-caller-identity + aws iam get-role only.
#   - Fail-soft per layer: each layer's helper prints "LAYER: <reason>" on
#     error and returns, the script continues. The OVERALL exit code is 1
#     if any layer reported lookup-failed at the claim layer; otherwise 0.
#   - --watch follows spec §5.5: exit 0 on Ready=True, exit 2 on timeout.
#   - No reference to bash $UID anywhere (PR #59 readonly-builtin class).
#   - String-equality on condition checks (PR #67 silent-PASS class).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional shared helpers; spec §5.6 says inline-fallback if absent.
if [[ -f "$SCRIPT_DIR/_lib/k8s-helpers.sh" ]]; then
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=_lib/k8s-helpers.sh
  . "$SCRIPT_DIR/_lib/k8s-helpers.sh"
else
  echo "WARN: _lib/k8s-helpers.sh not found — using inline fallbacks" >&2
  : "${KUBECTL:=kubectl}"
  k8s_get_condition() {
    local kind="$1" name="$2" ns="$3" ctype="$4"
    local jp="{.status.conditions[?(@.type==\"${ctype}\")].status}"
    if [[ -n "$ns" ]]; then
      "$KUBECTL" get "$kind/$name" -n "$ns" -o jsonpath="$jp" 2>/dev/null || echo ""
    else
      "$KUBECTL" get "$kind/$name" -o jsonpath="$jp" 2>/dev/null || echo ""
    fi
  }
fi

: "${KUBECTL:=kubectl}"
: "${TRACE_INTERVAL:=10}"

usage() {
  cat <<'EOF'
Usage: crossplane-trace.sh <kind>/<name> [-n <ns>] [--watch] [--json] [--timeout <s>]

Walks claim → XR → managed-resources → atProvider, printing
.status.conditions at every layer. Read-only.

Arguments:
  <kind>/<name>     Claim kind and name (kind is case-insensitive).

Options:
  -n <ns>           Namespace. Default: default.
  --watch           Re-print every TRACE_INTERVAL (default 10s) until
                    Ready=True (exit 0) or --timeout elapses (exit 2).
  --json            Emit one JSON snapshot to stdout. Exit immediately.
  --timeout <s>     Watch timeout (only meaningful with --watch). Default 600.
  -h, --help        This help.

Env overrides:
  TRACE_INTERVAL    Watch poll interval in seconds (default 10).
  KUBECTL           kubectl binary (used by tests).
  AWS_REGION        Region. Sections skipped unless us-east-1 / us-west-2.
  SKIP_AWS_OVERRIDE force-skip the AWS / IRSA block (tests).

Examples:
  scripts/crossplane-trace.sh platformsecret/my-claim -n default
  scripts/crossplane-trace.sh platformsecret/my-claim --watch --timeout 300
  scripts/crossplane-trace.sh platformsecret/my-claim --json | jq .
EOF
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
KIND_NAME=""
NS="default"
WATCH=0
JSON=0
TIMEOUT=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n) NS="${2:-default}"; shift 2 ;;
    --watch) WATCH=1; shift ;;
    --json) JSON=1; shift ;;
    --timeout) TIMEOUT="${2:-600}"; shift 2 ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *) if [[ -z "$KIND_NAME" ]]; then KIND_NAME="$1"; else echo "ERROR: unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done

if [[ -z "$KIND_NAME" || "$KIND_NAME" != */* ]]; then
  echo "ERROR: <kind>/<name> required" >&2
  usage >&2
  exit 2
fi

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --timeout must be a non-negative integer (got: $TIMEOUT)" >&2
  exit 2
fi

KIND_RAW="${KIND_NAME%%/*}"
NAME="${KIND_NAME#*/}"
# Case-insensitive kind
KIND=$(echo "$KIND_RAW" | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------------------
# Pre-flight (spec §5.2)
# ---------------------------------------------------------------------------
SKIP_AWS=0
if [[ "${SKIP_AWS_OVERRIDE:-0}" == "1" ]]; then
  SKIP_AWS=1
fi

REGION="${AWS_REGION:-us-east-1}"
if [[ "$REGION" != "us-east-1" && "$REGION" != "us-west-2" ]]; then
  if [[ "$JSON" != "1" ]]; then
    echo "WARN: region=$REGION — AWS sections skipped" >&2
  fi
  SKIP_AWS=1
fi

if [[ "$SKIP_AWS" -eq 0 ]]; then
  if ! aws sts get-caller-identity --query 'Account' --output text >/dev/null 2>&1; then
    echo "WARN: aws sts get-caller-identity failed — AWS sections skipped" >&2
    SKIP_AWS=1
  fi
fi

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
# truncate stdin to N chars; appends '…' marker if truncated
trunc() {
  local n="${1:-160}"
  local s
  s=$(cat)
  if [[ "${#s}" -gt "$n" ]]; then
    printf '%s…' "${s:0:n}"
  else
    printf '%s' "$s"
  fi
}

# json_get <fixture-cmd> <jq-expr> — runs the kubectl JSON producer and
# applies the jq expr; returns empty on any error.
kget_json() {
  local kind="$1" name="$2" ns="${3:-}"
  if [[ -n "$ns" ]]; then
    "$KUBECTL" get "$kind/$name" -n "$ns" -o json 2>/dev/null
  else
    "$KUBECTL" get "$kind/$name" -o json 2>/dev/null
  fi
}

# jq_or_empty <expr> — read JSON on stdin; jq -r the expr; empty on error.
jq_or_empty() {
  local e="$1"
  jq -r "$e" 2>/dev/null || true
}

# Emit one condition summary "type=status reason=R" from JSON on stdin.
# Returns multi-condition string joined " | " or empty.
conditions_summary() {
  jq -r '
    (.status.conditions // [])
    | map("\(.type)=\(.status) reason=\(.reason // "-")")
    | join(" | ")
  ' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Layer state — populated by collect(), consumed by render_human / render_json
# ---------------------------------------------------------------------------
CLAIM_JSON=""
CLAIM_LOOKUP_FAILED=0
CLAIM_COMP_REF=""
XR_KIND=""
XR_NAME=""
XR_JSON=""
XR_LOOKUP_FAILED=0
MR_REFS_JSON="[]"   # raw resourceRefs from XR
MR_DETAILS_JSON="[]" # per-MR enriched detail: [{kind,name,synced,ready,reason,message,atProvider,fail}]
PROVIDER_NAME=""
PROVIDER_JSON=""
POD_JSON=""
POD_SA=""
SA_JSON=""
ROLE_ARN=""
TRUST_SUB_SA=""
IRSA_MATCH=""       # "true" / "false" / "" (not evaluated)

# Map an MR apiVersion → provider package name. Mirrors SPEC-A1 §5 §4.
# Conservative: maps the common providers used in this repo.
provider_for_apiversion() {
  local av="$1"
  local group="${av%%/*}"
  case "$group" in
    *.aws.upbound.io|aws.upbound.io|*.aws.m.upbound.io|aws.m.upbound.io)
      echo "upbound-provider-family-aws" ;;
    *)
      # Best-effort fallback: strip trailing ".upbound.io" → "upbound-provider-<group-prefix>"
      local short="${group%.upbound.io}"
      short="${short//./-}"
      if [[ -n "$short" && "$short" != "$group" ]]; then
        echo "upbound-provider-${short%-*}"
      else
        echo ""
      fi
      ;;
  esac
}

collect() {
  CLAIM_JSON=""; CLAIM_LOOKUP_FAILED=0; CLAIM_COMP_REF=""
  XR_KIND=""; XR_NAME=""; XR_JSON=""; XR_LOOKUP_FAILED=0
  MR_REFS_JSON="[]"; MR_DETAILS_JSON="[]"
  PROVIDER_NAME=""; PROVIDER_JSON=""; POD_JSON=""; POD_SA=""
  SA_JSON=""; ROLE_ARN=""; TRUST_SUB_SA=""; IRSA_MATCH=""

  # ---- Layer 0: CLAIM ------------------------------------------------------
  CLAIM_JSON=$(kget_json "$KIND" "$NAME" "$NS")
  if [[ -z "$CLAIM_JSON" ]]; then
    CLAIM_LOOKUP_FAILED=1
    return
  fi
  CLAIM_COMP_REF=$(printf '%s' "$CLAIM_JSON" | jq_or_empty '.spec.compositionRef.name // ""')
  XR_KIND=$(printf '%s' "$CLAIM_JSON" | jq_or_empty '.spec.resourceRef.kind // ""')
  XR_NAME=$(printf '%s' "$CLAIM_JSON" | jq_or_empty '.spec.resourceRef.name // ""')

  # ---- Layer 1: XR ---------------------------------------------------------
  if [[ -n "$XR_NAME" && -n "$XR_KIND" ]]; then
    XR_JSON=$(kget_json "$XR_KIND" "$XR_NAME" "")
    if [[ -z "$XR_JSON" ]]; then
      XR_LOOKUP_FAILED=1
    else
      MR_REFS_JSON=$(printf '%s' "$XR_JSON" | jq -c '.spec.resourceRefs // []' 2>/dev/null || echo "[]")
    fi
  fi

  # ---- Layer 2: managed resources -----------------------------------------
  local refs_count
  refs_count=$(printf '%s' "$MR_REFS_JSON" | jq 'length' 2>/dev/null || echo 0)
  local i=0
  local details="[]"
  local first_fail_apiversion=""
  while [[ "$i" -lt "$refs_count" && "$i" -lt 12 ]]; do
    local ref_av ref_kind ref_name
    ref_av=$(printf '%s' "$MR_REFS_JSON" | jq -r ".[$i].apiVersion // \"\"" 2>/dev/null)
    ref_kind=$(printf '%s' "$MR_REFS_JSON" | jq -r ".[$i].kind // \"\"" 2>/dev/null)
    ref_name=$(printf '%s' "$MR_REFS_JSON" | jq -r ".[$i].name // \"\"" 2>/dev/null)
    if [[ -z "$ref_kind" || -z "$ref_name" ]]; then i=$((i+1)); continue; fi
    local mr_json mr_synced mr_ready mr_reason mr_msg mr_atp fail
    mr_json=$(kget_json "$ref_kind" "$ref_name" "")
    if [[ -z "$mr_json" ]]; then
      mr_synced="?" ; mr_ready="?"; mr_reason="lookup-failed"; mr_msg=""; mr_atp="{}"
      fail=1
    else
      mr_synced=$(printf '%s' "$mr_json" | jq -r '(.status.conditions // []) | map(select(.type=="Synced"))[0].status // "?"' 2>/dev/null)
      mr_ready=$(printf '%s' "$mr_json" | jq -r '(.status.conditions // []) | map(select(.type=="Ready"))[0].status // "?"' 2>/dev/null)
      mr_reason=$(printf '%s' "$mr_json" | jq -r '(.status.conditions // []) | map(select(.type=="Ready"))[0].reason // "-"' 2>/dev/null)
      mr_msg=$(printf '%s' "$mr_json" | jq -r '(.status.conditions // []) | map(select(.type=="Ready"))[0].message // ""' 2>/dev/null \
        | trunc 200)
      mr_atp=$(printf '%s' "$mr_json" | jq -c '.status.atProvider // {}' 2>/dev/null || echo "{}")
      if [[ "$mr_ready" == "True" && "$mr_synced" == "True" ]]; then
        fail=0
      else
        fail=1
        if [[ -z "$first_fail_apiversion" ]]; then
          first_fail_apiversion="$ref_av"
        fi
      fi
    fi
    # truncate atProvider to 400 chars
    if [[ "${#mr_atp}" -gt 400 ]]; then
      mr_atp="${mr_atp:0:400}"
    fi
    local entry
    entry=$(jq -nc \
      --arg kind "$ref_kind" --arg name "$ref_name" \
      --arg av "$ref_av" \
      --arg synced "$mr_synced" --arg ready "$mr_ready" \
      --arg reason "$mr_reason" --arg message "$mr_msg" \
      --arg atp "$mr_atp" --argjson fail "$fail" \
      '{kind:$kind, name:$name, apiVersion:$av, synced:$synced, ready:$ready, reason:$reason, message:$message, atProvider:$atp, fail:$fail}' 2>/dev/null)
    details=$(printf '%s' "$details" | jq -c ". + [$entry]" 2>/dev/null || echo "$details")
    i=$((i+1))
  done
  MR_DETAILS_JSON="$details"

  # ---- Layer 3: provider + IRSA -------------------------------------------
  if [[ -n "$first_fail_apiversion" ]]; then
    PROVIDER_NAME=$(provider_for_apiversion "$first_fail_apiversion")
  fi
  if [[ -n "$PROVIDER_NAME" ]]; then
    PROVIDER_JSON=$(kget_json "provider.pkg.crossplane.io" "$PROVIDER_NAME" "")
    if [[ -z "$PROVIDER_JSON" ]]; then
      PROVIDER_JSON=$(kget_json "provider" "$PROVIDER_NAME" "")
    fi
    # provider pod
    POD_JSON=$("$KUBECTL" get pods -n crossplane-system \
      -l "pkg.crossplane.io/provider=${PROVIDER_NAME#upbound-}" -o json 2>/dev/null || true)
    if [[ -z "$POD_JSON" || "$POD_JSON" == "null" ]]; then
      POD_JSON=$("$KUBECTL" get pods -n crossplane-system -o json 2>/dev/null || true)
    fi
    POD_SA=$(printf '%s' "$POD_JSON" | jq -r '.items[0].spec.serviceAccountName // ""' 2>/dev/null)
    # SA lookup (for IRSA role annotation)
    if [[ -n "$POD_SA" ]]; then
      SA_JSON=$("$KUBECTL" get sa "$POD_SA" -n crossplane-system -o json 2>/dev/null || true)
      ROLE_ARN=$(printf '%s' "$SA_JSON" | jq -r '.metadata.annotations["eks.amazonaws.com/role-arn"] // ""' 2>/dev/null)
    fi
  fi

  # ---- Layer 3b: IRSA via AWS --------------------------------------------
  if [[ "$SKIP_AWS" -eq 0 && -n "$ROLE_ARN" ]]; then
    local role_name role_json trust_sub
    role_name="${ROLE_ARN##*/}"
    role_json=$(aws iam get-role --role-name "$role_name" --output json 2>/dev/null || true)
    if [[ -n "$role_json" ]]; then
      trust_sub=$(printf '%s' "$role_json" | jq -r '
        .Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals
        | to_entries[] | select(.key | endswith(":sub")) | .value
      ' 2>/dev/null | head -n1)
      TRUST_SUB_SA="$trust_sub"
      # Extract the SA part: system:serviceaccount:<ns>:<sa>
      local sub_sa
      sub_sa="${trust_sub##*:}"
      if [[ "$sub_sa" == "$POD_SA" ]]; then
        IRSA_MATCH="true"
      else
        IRSA_MATCH="false"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Rendering — human
# ---------------------------------------------------------------------------
render_human() {
  local ts
  ts=$(date -u +"%H:%M:%SZ")
  printf '=== CROSSPLANE TRACE: %s/%s -n %s  [%s] ===\n' "$KIND" "$NAME" "$NS" "$ts"

  # ---- CLAIM ----
  if [[ "$CLAIM_LOOKUP_FAILED" -eq 1 ]]; then
    printf 'CLAIM: lookup-failed (%s/%s -n %s not found)\n' "$KIND" "$NAME" "$NS"
    printf '=== END TRACE ===\n'
    return
  fi
  printf 'CLAIM    %s/%s  compRef=%s\n' "$KIND" "$NAME" "${CLAIM_COMP_REF:--}"
  local c_synced c_ready c_reason_s c_reason_r c_msg
  c_synced=$(printf '%s' "$CLAIM_JSON" | jq -r '(.status.conditions // []) | map(select(.type=="Synced"))[0].status // "?"')
  c_ready=$(printf '%s' "$CLAIM_JSON" | jq -r '(.status.conditions // []) | map(select(.type=="Ready"))[0].status // "?"')
  c_reason_s=$(printf '%s' "$CLAIM_JSON" | jq -r '(.status.conditions // []) | map(select(.type=="Synced"))[0].reason // "-"')
  c_reason_r=$(printf '%s' "$CLAIM_JSON" | jq -r '(.status.conditions // []) | map(select(.type=="Ready"))[0].reason // "-"')
  c_msg=$(printf '%s' "$CLAIM_JSON" | jq -r '(.status.conditions // []) | map(select(.type=="Ready"))[0].message // ""' | trunc 160)
  printf '  Synced=%s reason=%s | Ready=%s reason=%s  message: %s\n' \
    "$c_synced" "$c_reason_s" "$c_ready" "$c_reason_r" "$c_msg"
  if [[ -n "$XR_KIND" && -n "$XR_NAME" ]]; then
    printf '  XR-ptr: %s/%s\n' "$XR_KIND" "$XR_NAME"
  fi

  # ---- XR ----
  if [[ -n "$XR_NAME" ]]; then
    printf 'XR       %s/%s\n' "$XR_KIND" "$XR_NAME"
    if [[ "$XR_LOOKUP_FAILED" -eq 1 ]]; then
      printf '  XR: lookup-failed\n'
    else
      local xr_summary
      xr_summary=$(printf '%s' "$XR_JSON" | conditions_summary)
      if [[ -z "$xr_summary" ]]; then
        printf '  conditions: <empty — Composition pipeline may not have reconciled yet>\n'
      else
        printf '  conditions: %s\n' "$xr_summary"
      fi
      local total_refs shown_refs
      total_refs=$(printf '%s' "$MR_REFS_JSON" | jq 'length' 2>/dev/null || echo 0)
      shown_refs=$(printf '%s' "$MR_DETAILS_JSON" | jq 'length' 2>/dev/null || echo 0)
      printf '  resourceRefs (%s total):\n' "$total_refs"
      local fail_seen=0
      local idx=0
      while [[ "$idx" -lt "$shown_refs" ]]; do
        local k n s r reason msg fail
        k=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$idx].kind")
        n=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$idx].name")
        s=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$idx].synced")
        r=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$idx].ready")
        reason=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$idx].reason")
        msg=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$idx].message")
        fail=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$idx].fail")
        if [[ "$fail" == "1" ]]; then
          if [[ "$fail_seen" -lt 5 ]]; then
            printf '    [FAIL] %s/%s  Synced=%s Ready=%s  reason=%s\n' "$k" "$n" "$s" "$r" "$reason"
            if [[ -n "$msg" ]]; then
              printf '           message: %s\n' "$msg"
            fi
          fi
          fail_seen=$((fail_seen + 1))
        else
          printf '    [OK]   %s/%s  Synced=%s Ready=%s\n' "$k" "$n" "$s" "$r"
        fi
        idx=$((idx + 1))
      done
      if [[ "$total_refs" -gt "$shown_refs" ]]; then
        printf '    (+%s more)\n' "$((total_refs - shown_refs))"
      fi
      if [[ "$fail_seen" -gt 5 ]]; then
        printf '    (+%s more failing MRs)\n' "$((fail_seen - 5))"
      fi
    fi
  fi

  # ---- PROVIDER ----
  if [[ -n "$PROVIDER_NAME" ]]; then
    local p_healthy p_installed
    if [[ -n "$PROVIDER_JSON" ]]; then
      p_healthy=$(printf '%s' "$PROVIDER_JSON" | jq -r '(.status.conditions // []) | map(select(.type=="Healthy"))[0].status // "?"')
      p_installed=$(printf '%s' "$PROVIDER_JSON" | jq -r '(.status.conditions // []) | map(select(.type=="Installed"))[0].status // "?"')
    else
      p_healthy="?"; p_installed="?"
    fi
    printf 'PROVIDER provider.pkg/%s  Healthy=%s Installed=%s\n' "$PROVIDER_NAME" "$p_healthy" "$p_installed"
    local pod_name pod_phase pod_restarts
    pod_name=$(printf '%s' "$POD_JSON" | jq -r '.items[0].metadata.name // "?"' 2>/dev/null)
    pod_phase=$(printf '%s' "$POD_JSON" | jq -r '.items[0].status.phase // "?"' 2>/dev/null)
    pod_restarts=$(printf '%s' "$POD_JSON" | jq -r '[.items[0].status.containerStatuses[]?.restartCount // 0] | add // 0' 2>/dev/null)
    printf '  pod:    %s  phase=%s  restarts=%s\n' "$pod_name" "$pod_phase" "$pod_restarts"
    printf '  pod-SA: %s\n' "${POD_SA:-?}"
  fi

  # ---- IRSA ----
  if [[ "$SKIP_AWS" -eq 0 && -n "$ROLE_ARN" ]]; then
    printf 'IRSA     role: %s\n' "$ROLE_ARN"
    printf '  trust-subject: %s\n' "${TRUST_SUB_SA:-?}"
    if [[ "$IRSA_MATCH" == "true" ]]; then
      printf '  MATCH\n'
    elif [[ "$IRSA_MATCH" == "false" ]]; then
      printf '  MISMATCH\n'
    fi
  fi

  # ---- ATPROVIDER (failing only) ----
  local fail_count
  fail_count=$(printf '%s' "$MR_DETAILS_JSON" | jq '[.[] | select(.fail==1)] | length' 2>/dev/null || echo 0)
  if [[ "$fail_count" -gt 0 ]]; then
    printf 'ATPROVIDER (failing MRs)\n'
    local n=0 emitted=0
    while [[ "$n" -lt "$(printf '%s' "$MR_DETAILS_JSON" | jq 'length')" && "$emitted" -lt 5 ]]; do
      local f k nm atp
      f=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$n].fail")
      if [[ "$f" == "1" ]]; then
        k=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$n].kind")
        nm=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$n].name")
        atp=$(printf '%s' "$MR_DETAILS_JSON" | jq -r ".[$n].atProvider")
        printf '  %s/%s: %s\n' "$k" "$nm" "$atp"
        emitted=$((emitted + 1))
      fi
      n=$((n + 1))
    done
  fi

  printf '=== END TRACE ===\n'
}

# ---------------------------------------------------------------------------
# Rendering — JSON (spec §5.4)
# ---------------------------------------------------------------------------
render_json() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local claim_obj xr_obj prov_obj irsa_obj
  if [[ "$CLAIM_LOOKUP_FAILED" -eq 1 ]]; then
    claim_obj=$(jq -nc --arg kind "$KIND" --arg name "$NAME" --arg ns "$NS" \
      '{kind:$kind, name:$name, namespace:$ns, lookupFailed:true}')
  else
    claim_obj=$(jq -nc --argjson c "$CLAIM_JSON" --arg comp "$CLAIM_COMP_REF" \
      '{kind: $c.kind, name: $c.metadata.name, namespace: $c.metadata.namespace,
        compositionRef: $comp,
        conditions: ($c.status.conditions // [])}')
  fi

  if [[ -n "$XR_NAME" && "$XR_LOOKUP_FAILED" -eq 0 && -n "$XR_JSON" ]]; then
    xr_obj=$(jq -nc --argjson x "$XR_JSON" --arg k "$XR_KIND" --arg n "$XR_NAME" \
      '{kind:$k, name:$n, conditions: ($x.status.conditions // []),
        resourceRefs: ($x.spec.resourceRefs // [])}')
  elif [[ -n "$XR_NAME" ]]; then
    xr_obj=$(jq -nc --arg k "$XR_KIND" --arg n "$XR_NAME" \
      '{kind:$k, name:$n, lookupFailed:true}')
  else
    xr_obj='null'
  fi

  prov_obj=$(jq -nc --arg n "$PROVIDER_NAME" --arg sa "$POD_SA" \
    --argjson pkg "${PROVIDER_JSON:-null}" --argjson pod "${POD_JSON:-null}" \
    '{name:$n, podServiceAccount:$sa,
      package: (if $pkg==null then null else {conditions:($pkg.status.conditions // [])} end),
      pod: (if $pod==null then null else {name: ($pod.items[0].metadata.name // null),
                                            phase: ($pod.items[0].status.phase // null)} end)}' 2>/dev/null \
    || jq -nc --arg n "$PROVIDER_NAME" --arg sa "$POD_SA" \
       '{name:$n, podServiceAccount:$sa, package:null, pod:null}')

  if [[ "$SKIP_AWS" -eq 1 ]]; then
    irsa_obj='{"skipped": true}'
  else
    local match_bool="null"
    if [[ "$IRSA_MATCH" == "true" ]]; then match_bool="true"
    elif [[ "$IRSA_MATCH" == "false" ]]; then match_bool="false"
    fi
    irsa_obj=$(jq -nc --arg role "$ROLE_ARN" --arg sub "$TRUST_SUB_SA" \
      --argjson m "$match_bool" \
      '{roleArn:$role, trustSubject:$sub, match:$m}')
  fi

  jq -nc \
    --arg ts "$ts" \
    --argjson claim "$claim_obj" \
    --argjson xr "$xr_obj" \
    --argjson mrs "$MR_DETAILS_JSON" \
    --argjson provider "$prov_obj" \
    --argjson irsa "$irsa_obj" \
    '{timestamp:$ts, claim:$claim, xr:$xr, managedResources:$mrs, provider:$provider, irsa:$irsa}'
}

# ---------------------------------------------------------------------------
# Watch loop (spec §5.5)
# ---------------------------------------------------------------------------
claim_is_ready() {
  local st
  st=$(k8s_get_condition "$KIND" "$NAME" "$NS" Ready)
  [[ "$st" == "True" ]]
}

run_once() {
  collect
  if [[ "$JSON" -eq 1 ]]; then
    render_json
  else
    render_human
  fi
}

run_watch() {
  local elapsed=0
  while :; do
    run_once
    if [[ "$CLAIM_LOOKUP_FAILED" -eq 0 ]] && claim_is_ready; then
      echo "=== CLAIM READY — watch exiting 0 ==="
      exit 0
    fi
    if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
      echo "=== TIMEOUT (${TIMEOUT}s) — claim not Ready ==="
      exit 2
    fi
    sleep "$TRACE_INTERVAL"
    elapsed=$(( elapsed + TRACE_INTERVAL ))
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "$WATCH" -eq 1 ]]; then
  run_watch
else
  run_once
  if [[ "$CLAIM_LOOKUP_FAILED" -eq 1 ]]; then
    exit 1
  fi
  exit 0
fi
