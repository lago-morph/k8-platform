#!/usr/bin/env bash
# LIVE behavioral check (after tier) — OI-2026-06-08-2 / ADR-0006
#
# End-to-end HARD check: a real HTTP request reaches the `hello` workload on the
# spoke cluster through the public NLB, AND the hub's ArgoCD reports the
# spoke-hello Application as Synced+Healthy.
#
# Two assertions, both HARD (no self-gating skip stubs):
#   1. PUBLIC NLB / TLS check  — poll https://hello.platform.<domain>/ for up to
#      300 s (15 s interval) expecting HTTP 200 AND the exact body marker
#      produced by hashicorp/http-echo with -text="<message>".  TLS chain must
#      validate without -k (the cluster's ACM wildcard *.platform.<domain> is
#      publicly trusted).  Timeout with no 200+body → FAIL (ng + exit 1).
#   2. HUB ArgoCD assertion    — drive the hub cluster k8-platform-mgmt via the
#      SSM relay; assert spoke-hello Application .status.sync.status == "Synced"
#      AND .status.health.status == "Healthy".  A relay flake (bounded retries
#      exhausted) → SKIP with a loud diagnostic — a relay hiccup must never
#      masquerade as "ArgoCD unhealthy".  Relay reached but app not
#      Synced/Healthy → FAIL.
#
# Legitimate skips ONLY: missing tools (aws/jq/curl/kubectl/session-manager-plugin),
# no AWS creds, no resolvable public hosted zone, or relay-flake.
#
# Emits `covers "platform.hello/e2e"` on success — additive synthetic marker,
# NOT in LIVE_EXPECT_FULL, so it never trips expect-full.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail.  Read-only (curl GET + kubectl get) — safe in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
# Hub cluster name is a durable platform constant (task brief OI-2026-06-08-2).
HUB_CLUSTER="k8-platform-mgmt"
HELPER="$REPO_ROOT/scripts/sandbox-kubeconfig.sh"

# Expected body marker — the exact string hashicorp/http-echo echoes when
# launched with -text="hello from the k8-platform platform-services cluster"
# (platform-services/hello/values.yaml: message field).
EXPECTED_BODY="hello from the k8-platform platform-services cluster"

# ArgoCD Application name (argocd/apps/spoke/hello.yaml metadata.name).
HELLO_APP="spoke-hello"

# Poll parameters for the public NLB check.
NLB_POLL_MAX="${HELLO_E2E_NLB_POLL_MAX:-300}"
NLB_POLL_INTERVAL="${HELLO_E2E_NLB_POLL_INTERVAL:-15}"

# Relay retry parameters (mirrors external-secret-live.sh).
RELAY_ATTEMPTS="${LIVE_RELAY_ATTEMPTS:-4}"
RELAY_INTERVAL="${LIVE_RELAY_INTERVAL:-15}"

# ── Tooling / credential preconditions ────────────────────────────────────────
# Not-applicable (skip), not a failure.
for bin in aws jq curl kubectl session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 \
    || skip "$bin not on PATH (hello e2e live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 \
  || skip "no usable AWS credentials in this environment"
[ -x "$HELPER" ] || skip "helper $HELPER missing/not executable"

# ── §1 — Derive the public hosted-zone domain (AGENTS §8.1: LIVE, never hardcoded) ──
log "deriving public hosted-zone domain via aws route53 list-hosted-zones"

ZONES_JSON="$(aws route53 list-hosted-zones --output json 2>/dev/null)" \
  || skip "route53:ListHostedZones not permitted / unavailable here"

# Find the public (non-private) hosted zone whose name ends with a real TLD.
# The account has exactly one public zone (realhandsonlabs.net. or equivalent).
ZONE_NAME="$(printf '%s' "$ZONES_JSON" | jq -r '
  .HostedZones[]
  | select(.Config.PrivateZone == false)
  | .Name' | head -1)"

if [ -z "$ZONE_NAME" ] || [ "$ZONE_NAME" = "null" ]; then
  skip "no public hosted zone found in this account (hello e2e precondition not met)"
fi

# Strip trailing dot → base domain (e.g. "realhandsonlabs.net").
DOMAIN="${ZONE_NAME%.}"

log "public domain: $DOMAIN"

# Host under test: hello.platform.<domain>
HOST="hello.platform.${DOMAIN}"
URL="https://${HOST}/"

log "target URL: $URL"

# ── §2 — HARD bounded poll: public NLB + TLS + body assertion ────────────────
# Poll for NLB_POLL_MAX seconds (interval NLB_POLL_INTERVAL) expecting:
#   - curl exits 0 (TCP + TLS success — no -k, so chain must validate)
#   - HTTP 200 status code
#   - Response body contains EXPECTED_BODY
# If none of the conditions are met within the window → FAIL (NOT skip).

log "polling $URL for HTTP 200 + body marker (max ${NLB_POLL_MAX}s, interval ${NLB_POLL_INTERVAL}s)"
log "  expected body marker: \"$EXPECTED_BODY\""

NLB_START="$(date +%s)"
nlb_ok=0

while true; do
  NLB_NOW="$(date +%s)"
  NLB_ELAPSED=$(( NLB_NOW - NLB_START ))

  # -s silent, -S show errors, -f fail on 4xx/5xx, --max-time 10 per attempt.
  # Capture body; capture HTTP status separately via -w.
  HTTP_STATUS=""
  BODY=""
  if BODY="$(curl -sSf --max-time 10 \
               -w "\n%{http_code}" \
               --connect-timeout 5 \
               "$URL" 2>/dev/null)"; then
    # Last line of output from -w is the status code.
    HTTP_STATUS="$(printf '%s' "$BODY" | tail -1)"
    BODY="$(printf '%s' "$BODY" | head -n -1)"
    if [ "$HTTP_STATUS" = "200" ] && printf '%s' "$BODY" | grep -qF "$EXPECTED_BODY"; then
      nlb_ok=1
      break
    else
      log "  attempt at ${NLB_ELAPSED}s: status=$HTTP_STATUS body_match=$(printf '%s' "$BODY" | grep -cF "$EXPECTED_BODY" || true)"
    fi
  else
    log "  attempt at ${NLB_ELAPSED}s: curl failed (TLS error, DNS, or connection refused)"
  fi

  if [ "$NLB_ELAPSED" -ge "$NLB_POLL_MAX" ]; then
    break
  fi

  sleep "$NLB_POLL_INTERVAL"
done

if [ "$nlb_ok" -ne 1 ]; then
  ng "hello workload at $URL did not return HTTP 200 + expected body within ${NLB_POLL_MAX}s"
  ng "  expected body marker: \"$EXPECTED_BODY\""
  ng "  (last HTTP_STATUS=${HTTP_STATUS:-none})"
  ng "  Indicates: NLB not healthy, ingress-nginx not routing, hello Deployment not Ready,"
  ng "  ExternalDNS record missing, or ACM cert not valid for ${HOST}"
  exit 1
fi

ok "https://${HOST}/ returned HTTP 200 with expected body marker after $(($(date +%s) - NLB_START))s"

# ── §3 — Paired hub-side ArgoCD assertion (via SSM relay) ─────────────────────
# Drive the hub cluster k8-platform-mgmt through the SSM relay.
# Relay-flake → SKIP (loud diagnostic, mirror external-secret-live.sh).
# Relay reached but app not Synced/Healthy → FAIL.

log "asserting hub ArgoCD Application '$HELLO_APP' Synced+Healthy via SSM relay on $HUB_CLUSTER"

APP_JSON=""; relay_ok=0
for attempt in $(seq 1 "$RELAY_ATTEMPTS"); do
  APP_JSON="$("$HELPER" -c "$HUB_CLUSTER" -r "$REGION" --exec \
                kubectl get application "$HELLO_APP" -n argocd -o json 2>/dev/null)" || true
  # A real success: parseable JSON with .status present.
  if [ -n "$APP_JSON" ] && printf '%s' "$APP_JSON" | jq -e '.status' >/dev/null 2>&1; then
    relay_ok=1; break
  fi
  log "relay attempt $attempt/$RELAY_ATTEMPTS did not return parseable Application JSON for $HUB_CLUSTER; retry in ${RELAY_INTERVAL}s"
  [ "$attempt" -lt "$RELAY_ATTEMPTS" ] && sleep "$RELAY_INTERVAL"
done

if [ "$relay_ok" -ne 1 ]; then
  log "RELAY UNREACHABLE for $HUB_CLUSTER after $RELAY_ATTEMPTS attempts."
  log "  → This is a relay/SSM-tunnel failure, NOT evidence that ArgoCD is unhealthy."
  log "  → Do NOT treat it as a missing/broken Application. Investigate the relay"
  log "    (scripts/sandbox-kubeconfig.sh); the sandbox holds admin AWS and can"
  log "    self-grant cluster access (AGENTS §6.37)."
  skip "hub kube API not reachable for $HUB_CLUSTER after $RELAY_ATTEMPTS relay attempts (tunnel flake — not an ArgoCD absence)"
fi

SYNC_STATUS="$(printf '%s' "$APP_JSON" | jq -r '.status.sync.status // "Unknown"')"
HEALTH_STATUS="$(printf '%s' "$APP_JSON" | jq -r '.status.health.status // "Unknown"')"

log "ArgoCD Application $HELLO_APP: sync=$SYNC_STATUS health=$HEALTH_STATUS"

if [ "$SYNC_STATUS" != "Synced" ] || [ "$HEALTH_STATUS" != "Healthy" ]; then
  ng "ArgoCD Application $HELLO_APP on hub $HUB_CLUSTER is NOT Synced+Healthy"
  ng "  sync.status=$SYNC_STATUS  (expected: Synced)"
  ng "  health.status=$HEALTH_STATUS  (expected: Healthy)"
  # Emit the last condition for diagnosis.
  LAST_COND="$(printf '%s' "$APP_JSON" | jq -r '
    (.status.conditions // [])[-1]
    | if . then "type=\(.type) message=\(.message // "n/a")" else "no conditions" end')"
  ng "  last condition: $LAST_COND"
  exit 1
fi

ok "ArgoCD Application $HELLO_APP on hub $HUB_CLUSTER: sync=$SYNC_STATUS health=$HEALTH_STATUS"

# ── All assertions passed ─────────────────────────────────────────────────────
covers "platform.hello/e2e"
exit "$LIVE_RC_PASS"
