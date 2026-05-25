# PURPOSE:
# Shared kubectl helper functions for scripts/ executables. First introduced
# by SPEC-S7 (scripts/wait-for-claim.sh); later consumed by SPEC-S2
# (crossplane-trace.sh), SPEC-A2, SPEC-A3, SPEC-A5.
#
# Sourced — never executed directly:
#   . "$SCRIPT_DIR/_lib/k8s-helpers.sh"
#
# Convention (mirrors scripts/_lib/aws-cli-helpers.sh):
#   - k8s_*  : kubectl-facing helpers
#   - every function is read-only (no mutations to cluster state)
#   - failures return a sentinel ("" or "UNKNOWN"); functions never exit
#     the calling script
#
# Hard rules:
#   - No reference to the bash readonly user-id builtin anywhere
#     (PR #59 readonly-builtin class — see
#     tests/unit/test_shell_readonly_var_assignment.sh).
#   - Do not source AWS helpers from here; cross-source coupling is
#     forbidden so each module can be unit-tested in isolation.

# Guard against accidental direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: k8s-helpers.sh must be sourced, not executed directly." >&2
  echo "Usage: . /path/to/scripts/_lib/k8s-helpers.sh" >&2
  exit 2
fi

# Allow tests to override the kubectl binary with a mock.
: "${KUBECTL:=kubectl}"

# k8s_get_condition <kind> <name> <ns> <type>
#
# Emits the .status.conditions[?(@.type==<type>)].status value
# ("True" / "False" / "Unknown" / "").
#
# Empty <ns> ("" or omitted) → cluster-scoped resource, no -n flag.
# Failures (resource missing, kubectl error, condition absent) emit "".
#
# Exact-equality callers should compare with `[[ "$v" == "True" ]]`;
# never pipe to `grep -q True` — that silently treats "" as not-Ready
# but also matches "TrueFalse" as Ready (PR #67 silent-PASS class).
k8s_get_condition() {
  local kind="${1:?k8s_get_condition: kind required}"
  local name="${2:?k8s_get_condition: name required}"
  local ns="${3:-}"
  local ctype="${4:?k8s_get_condition: condition type required}"
  local jp="{.status.conditions[?(@.type==\"${ctype}\")].status}"

  if [[ -n "$ns" ]]; then
    "$KUBECTL" get "$kind/$name" -n "$ns" -o jsonpath="$jp" 2>/dev/null || echo ""
  else
    "$KUBECTL" get "$kind/$name" -o jsonpath="$jp" 2>/dev/null || echo ""
  fi
}

# _k8s_truncate <max-bytes>
# Reads stdin, emits at most <max-bytes> bytes (head -c equivalent that
# also appends a notice when truncated). Internal — not part of the
# public API.
_k8s_truncate() {
  local max="${1:-800}"
  local buf
  buf=$(cat)
  if [[ "${#buf}" -gt "$max" ]]; then
    printf '%s\n  (truncated to %d bytes)\n' "${buf:0:max}" "$max"
  else
    printf '%s\n' "$buf"
  fi
}

# k8s_dump_claim_timeout <kind> <name> <ns>
#
# Emits a self-describing post-mortem dump on wait-for-claim timeout.
# Three sections, each truncated for a ≤ ~3 KB combined budget:
#   1. .status.conditions formatted as "type=status reason=R msg=M"
#   2. composition events on the XR (or "(XR ref not yet set)")
#   3. recent cluster events in the namespace
#
# Written to stdout so the caller's CI log captures it inline. The script
# wrapper (wait-for-claim.sh) prints the header on stderr before calling
# this and exits 1 unconditionally.
#
# Robust to: missing resource, empty .status.conditions, missing
# spec.resourceRef, empty namespace (cluster-scoped MR).
k8s_dump_claim_timeout() {
  local kind="${1:?k8s_dump_claim_timeout: kind required}"
  local name="${2:?k8s_dump_claim_timeout: name required}"
  local ns="${3:-}"
  local ns_flag=()
  if [[ -n "$ns" ]]; then
    ns_flag=(-n "$ns")
  fi

  printf '=== TIMEOUT DUMP: %s/%s ===\n' "$kind" "$name"

  # ---- 1. conditions ------------------------------------------------------
  printf -- '-- conditions:\n'
  local cond_jp='{range .status.conditions[*]}  type={.type} status={.status} reason={.reason} msg={.message}{"\n"}{end}'
  local cond
  cond=$("$KUBECTL" get "$kind/$name" "${ns_flag[@]}" -o jsonpath="$cond_jp" 2>/dev/null || true)
  if [[ -z "${cond//[[:space:]]/}" ]]; then
    printf '  (conditions unavailable)\n'
  else
    printf '%s' "$cond" | _k8s_truncate 800
  fi

  # ---- 2. composition events on the XR -----------------------------------
  printf -- '-- composition events (XR):\n'
  local xr_name
  xr_name=$("$KUBECTL" get "$kind/$name" "${ns_flag[@]}" \
    -o jsonpath='{.spec.resourceRef.name}' 2>/dev/null || true)
  if [[ -z "$xr_name" ]]; then
    printf '  (XR ref not yet set)\n'
  else
    local xr_events
    xr_events=$("$KUBECTL" get events \
      --field-selector "involvedObject.name=${xr_name}" \
      -o custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,MSG:.message \
      --no-headers 2>/dev/null || true)
    if [[ -z "${xr_events//[[:space:]]/}" ]]; then
      printf '  (no events on XR %s)\n' "$xr_name"
    else
      printf '%s' "$xr_events" | _k8s_truncate 800
    fi
  fi

  # ---- 3. recent cluster events in the namespace (±5 min) ----------------
  printf -- '-- recent cluster events (%s, ±5 min, last 20):\n' "${ns:-cluster-scoped}"
  local ns_events
  ns_events=$("$KUBECTL" get events "${ns_flag[@]}" \
    --sort-by=.lastTimestamp \
    -o custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,OBJ:.involvedObject.name,MSG:.message \
    --no-headers 2>/dev/null | tail -n 20 || true)
  if [[ -z "${ns_events//[[:space:]]/}" ]]; then
    printf '  (no recent events)\n'
  else
    printf '%s' "$ns_events" | _k8s_truncate 800
  fi

  printf '=== END TIMEOUT DUMP ===\n'
}
