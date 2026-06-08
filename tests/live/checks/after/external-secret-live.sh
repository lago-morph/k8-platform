#!/usr/bin/env bash
# LIVE behavioral check (after tier) — ExternalSecrets on the cluster are real
# and healthy (lane: non-aws, KIND external-secrets.io/ExternalSecret).
#
# This is the BEHAVIORAL oracle for external-secrets.io/ExternalSecret per
# ADR-0006: it proves ESO (External Secrets Operator) is running and has
# successfully synced at least one ExternalSecret to Ready=True — not that a
# manifest says so. Drives the real kube API read-only through the shared SSM
# relay (docs/decisions/0008).
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only (kubectl get only) — safe in
# `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="external-secrets.io/ExternalSecret"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
CLUSTER="${LIVE_CLUSTER:-}"
HELPER="$REPO_ROOT/scripts/sandbox-kubeconfig.sh"

[ -n "$CLUSTER" ] || skip "no LIVE_CLUSTER set (no cluster under test)"

# Tooling / creds preconditions — not-applicable (skip), not a failure.
for bin in aws kubectl jq session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (ExternalSecret live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"
[ -x "$HELPER" ] || skip "helper $HELPER missing/not executable"

log "driving kubectl get externalsecrets for '$CLUSTER' through the SSM relay"

# The SSM relay tunnel flakes transiently (two relay calls colliding in one wave —
# auto-014/auto-014-004). A SINGLE failed attempt must NOT be read as "0 found":
# that silently turns a relay hiccup into a false "ExternalSecret unprovisioned"
# fact (exactly the auto-014 check gap). So poll the relay (bounded) and only skip
# after repeated failure, with a LOUD diagnostic that this is a relay failure, not
# an absence. A reached-but-empty result is a separate, real signal (handled below).
RELAY_ATTEMPTS="${LIVE_RELAY_ATTEMPTS:-4}"
RELAY_INTERVAL="${LIVE_RELAY_INTERVAL:-15}"
OUT=""; relay_ok=0
for attempt in $(seq 1 "$RELAY_ATTEMPTS"); do
  OUT="$("$HELPER" -c "$CLUSTER" -r "$REGION" --exec \
          kubectl get externalsecrets.external-secrets.io -A -o json 2>/dev/null)"
  # A real success is a parseable list (.items present) — distinguishes an empty
  # ExternalSecret set ({"items":[]}) from relay garbage / a half-open tunnel.
  if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '.items' >/dev/null 2>&1; then
    relay_ok=1; break
  fi
  log "relay attempt $attempt/$RELAY_ATTEMPTS did not return a parseable list for $CLUSTER; retry in ${RELAY_INTERVAL}s"
  [ "$attempt" -lt "$RELAY_ATTEMPTS" ] && sleep "$RELAY_INTERVAL"
done

if [ "$relay_ok" -ne 1 ]; then
  log "RELAY UNREACHABLE for $CLUSTER after $RELAY_ATTEMPTS attempts."
  log "  → This is a relay/SSM-tunnel failure, NOT evidence that ExternalSecrets are absent."
  log "  → Do NOT count it as '0 found'. Investigate the relay (scripts/sandbox-kubeconfig.sh);"
  log "    the sandbox holds admin AWS and can self-grant cluster access (AGENTS §6.37)."
  skip "kube API not reachable for $CLUSTER after $RELAY_ATTEMPTS relay attempts (tunnel flake — not an absence)"
fi

TOTAL="$(printf '%s' "$OUT" | jq '.items | length')"
log "ExternalSecrets found on $CLUSTER (relay reached cleanly): $TOTAL"

# Relay reached + zero ExternalSecrets is a GENUINE absence signal (the ESO path is
# not provisioned on THIS cluster). The orchestrator promotes this skip to a FAIL
# iff git declares external-secrets.io/ExternalSecret expect-full for $CLUSTER — so
# the spoke (Keycloak's XPlatformSecret emits one) cannot read green by absence.
[ "${TOTAL:-0}" -gt 0 ] || skip "0 ExternalSecrets on $CLUSTER after a CLEAN relay read (ESO path genuinely not provisioned here)"

# Print names and namespaces for audit — never dump .data / .stringData.
log "ExternalSecret names:"
printf '%s' "$OUT" | jq -r '.items[] | "  \(.metadata.namespace)/\(.metadata.name)"'

# Count how many have a Ready=True condition.
READY_COUNT="$(printf '%s' "$OUT" | jq '
  [ .items[] | select(
      .status.conditions[]?
      | select(.type == "Ready" and .status == "True")
    )
  ] | length')"

log "ExternalSecrets with Ready=True: $READY_COUNT / $TOTAL"

# Print condition summaries for observability — never the synced secret contents.
printf '%s' "$OUT" | jq -r '
  .items[] |
  (.metadata.namespace + "/" + .metadata.name) as $name |
  (.status.conditions[]? | select(.type == "Ready") |
    "  " + $name + " Ready=" + .status + " (" + (.reason // "n/a") + ")"
  )'

if [ "${READY_COUNT:-0}" -lt 1 ]; then
  ng "$TOTAL ExternalSecret(s) exist on $CLUSTER but NONE have Ready=True (ESO is failing to sync)"
  exit 1
fi

ok "$READY_COUNT/$TOTAL ExternalSecret(s) Ready=True on $CLUSTER"
covers "$KIND"
exit "$LIVE_RC_PASS"
