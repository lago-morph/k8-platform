#!/usr/bin/env bash
# wait-for-claim.sh — canonical wait primitive for Crossplane claims.
#
# Usage:
#   wait-for-claim.sh <kind> <name> [ns] [timeout-seconds]
#
# Polls the named Crossplane claim's .status.conditions[type=Ready].status
# on a configurable interval (env POLL_INTERVAL, default 5s). Exits 0 the
# moment the value is exactly "True". On timeout, prints a self-describing
# dump of last-seen conditions + composition events + recent cluster
# events to stderr and exits 1 — UNCONDITIONALLY, so callers without
# `set -e` cannot silently miss the failure (PR #59 silent-PASS class).
#
# Empty / omitted <ns> targets a cluster-scoped resource (e.g. a raw
# Bucket MR — see tests/integration/05_crossplane_managed_resource.sh).
#
# Environment overrides:
#   POLL_INTERVAL   poll period in seconds (default 5)
#   TIMEOUT         max wait in seconds (overridden by CLI arg 4 if given;
#                   default 300)
#   KUBECTL         kubectl binary path (default `kubectl`; used by tests)
#
# Hard rules:
#   - Uses string equality `[[ "$st" == "True" ]]`, never `grep -q True`
#     (PR #67 silent-PASS class).
#   - Never assigns to the bash readonly user-id builtin (PR #59
#     readonly-builtin class — also enforced by
#     tests/unit/test_shell_readonly_var_assignment.sh).
#   - `set -uo pipefail` only (no `-e`); the script owns its own exit
#     path so the unconditional `exit 1` on timeout is what callers see.
#
# Spec: ai/brainstorming/specs/SPEC-S7-wait-for-claim.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=_lib/k8s-helpers.sh
. "$SCRIPT_DIR/_lib/k8s-helpers.sh"

usage() {
  cat <<'EOF'
Usage: wait-for-claim.sh <kind> <name> [ns] [timeout-seconds]

  <kind>            Claim kind (e.g. PlatformSecret, TestBucket, Bucket).
  <name>            Claim name.
  [ns]              Namespace ("" or omitted = cluster-scoped resource).
  [timeout-seconds] Max wait. Default 300 (or $TIMEOUT env).

Env:
  POLL_INTERVAL=5   Poll period in seconds.
  TIMEOUT=300       Default max wait (overridden by CLI arg 4).
  KUBECTL=kubectl   kubectl binary (used by unit tests).

Exits 0 when .status.conditions[type=Ready].status == "True".
Exits 1 on timeout and dumps conditions+events to stderr.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 2
fi

KIND="$1"
NAME="$2"
NS="${3:-}"
TIMEOUT="${4:-${TIMEOUT:-300}}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# Defensive: numeric sanity. Bash arithmetic on bad input is silent.
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "wait-for-claim: invalid TIMEOUT '$TIMEOUT' (must be integer seconds)" >&2
  exit 2
fi
if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$POLL_INTERVAL" -lt 1 ]]; then
  echo "wait-for-claim: invalid POLL_INTERVAL '$POLL_INTERVAL' (must be positive integer)" >&2
  exit 2
fi

start=$(date +%s)
last_status=""

while :; do
  last_status=$(k8s_get_condition "$KIND" "$NAME" "$NS" Ready)
  # Exact-equality, NOT grep — defends PR #67 silent-PASS.
  if [[ "$last_status" == "True" ]]; then
    elapsed=$(( $(date +%s) - start ))
    echo "wait-for-claim: Ready=True after ${elapsed}s ($KIND/$NAME${NS:+ ns=$NS})"
    exit 0
  fi

  now=$(date +%s)
  elapsed=$(( now - start ))
  if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
    # NOTE (decision-brief D1): spec §5.2 says "prints ... " without
    # specifying stream, but §6 unit-test assertions check "stdout
    # contains '=== TIMEOUT DUMP:'". We resolve by writing BOTH the
    # one-line summary AND the dump to STDOUT so unit assertions match
    # AND CI logs interleave the dump with the surrounding script
    # output. (If consumers want the dump on stderr only, the decision
    # is reversible — change the redirections below.)
    echo "wait-for-claim: TIMEOUT after ${elapsed}s — Ready=${last_status:-<unset>} ($KIND/$NAME${NS:+ ns=$NS})"
    k8s_dump_claim_timeout "$KIND" "$NAME" "$NS"
    exit 1
  fi

  if [[ "${VERBOSE:-0}" == "1" ]]; then
    echo "wait-for-claim: waiting (${elapsed}/${TIMEOUT}s) Ready=${last_status:-<unset>}"
  fi
  sleep "$POLL_INTERVAL"
done
