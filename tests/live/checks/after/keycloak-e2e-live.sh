#!/usr/bin/env bash
# LIVE behavioral check (after tier) — OI-2026-06-07-5 / ADR-0006
#
# End-to-end HARD check: Keycloak on the spoke BOOTED AGAINST RDS and serves
# through the spoke ingress. Keycloak only answers realm metadata after a
# successful DB-backed start + `--import-realm`, so an HTTP 200 on the
# `platform` realm's OIDC discovery document is behavioral proof of the whole
# OI-2026-06-07-5 chain: XDatabase RDS (in the base VPC, OI-2026-06-11-1) →
# hub connection Secret → hub PushSecret → ASM k8-platform/keycloak-db →
# spoke ExternalSecret (host/port via extraEnvVarsSecret envFrom override) →
# StatefulSet Running → ingress-nginx/NLB/ACM/external-dns.
#
# Two assertions, both HARD (no self-gating skip stubs — PR #210 pattern):
#   1. PUBLIC discovery check — poll
#      https://auth.platform.<domain>/realms/platform/.well-known/openid-configuration
#      for up to 600 s (15 s interval) expecting HTTP 200 AND an `issuer`
#      field naming that same realm URL. TLS chain must validate without -k
#      (the spoke's ACM wildcard *.platform.<domain>). Timeout → FAIL.
#      (600 s, not hello's 300: a cold Keycloak StatefulSet does a schema
#      migration + realm import on first boot.)
#   2. HUB ArgoCD assertion — via the SSM relay on k8-platform-mgmt; assert
#      spoke-keycloak Application Synced+Healthy. Relay flake (bounded
#      retries exhausted) → SKIP with a loud diagnostic; reached but not
#      Synced/Healthy → FAIL.
#
# Emits `covers "platform.keycloak/e2e"` on success — additive synthetic
# marker, same convention as hello-e2e-live.sh.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only against AWS; HTTPS GETs only against the workload.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

HELPER="$REPO_ROOT/scripts/sandbox-kubeconfig.sh"
HUB_CLUSTER="${LIVE_HUB_CLUSTER:-k8-platform-mgmt}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# ArgoCD Application name (the keycloak ApplicationSet template:
# <short-name>-keycloak with short-name=spoke).
KC_APP="spoke-keycloak"

# Poll parameters for the public discovery check.
KC_POLL_MAX="${KEYCLOAK_E2E_POLL_MAX:-600}"
KC_POLL_INTERVAL="${KEYCLOAK_E2E_POLL_INTERVAL:-15}"

# Relay retry parameters (mirrors hello-e2e-live.sh).
RELAY_ATTEMPTS="${LIVE_RELAY_ATTEMPTS:-4}"
RELAY_INTERVAL="${LIVE_RELAY_INTERVAL:-15}"

# ── Tooling / credential preconditions (not-applicable ⇒ skip) ───────────────
for bin in aws jq curl kubectl session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 \
    || skip "$bin not on PATH (keycloak e2e live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 \
  || skip "no usable AWS credentials in this environment"
[ -x "$HELPER" ] || skip "helper $HELPER missing/not executable"

# ── §1 — Derive the public hosted-zone domain (AGENTS §8.1: LIVE, never hardcoded) ──
log "deriving public hosted-zone domain via aws route53 list-hosted-zones"

ZONES_JSON="$(aws route53 list-hosted-zones --output json 2>/dev/null)" \
  || skip "route53:ListHostedZones not permitted / unavailable here"

ZONE_NAME="$(printf '%s' "$ZONES_JSON" | jq -r '
  .HostedZones[]
  | select(.Config.PrivateZone == false)
  | .Name' | head -1)"

if [ -z "$ZONE_NAME" ] || [ "$ZONE_NAME" = "null" ]; then
  skip "no public hosted zone found in this account (keycloak e2e precondition not met)"
fi

DOMAIN="${ZONE_NAME%.}"
log "public domain: $DOMAIN"

HOST="auth.platform.${DOMAIN}"
URL="https://${HOST}/realms/platform/.well-known/openid-configuration"
EXPECTED_ISSUER="https://${HOST}/realms/platform"

log "target URL: $URL"

# ── §2 — HARD bounded poll: discovery 200 + issuer assertion ─────────────────
log "polling $URL for HTTP 200 + issuer (max ${KC_POLL_MAX}s, interval ${KC_POLL_INTERVAL}s)"
log "  expected issuer: $EXPECTED_ISSUER"

KC_START="$(date +%s)"
kc_ok=0

while true; do
  KC_NOW="$(date +%s)"
  KC_ELAPSED=$(( KC_NOW - KC_START ))

  HTTP_STATUS=""
  BODY=""
  if BODY="$(curl -sSf --max-time 10 \
               -w "\n%{http_code}" \
               --connect-timeout 5 \
               "$URL" 2>/dev/null)"; then
    HTTP_STATUS="$(printf '%s' "$BODY" | tail -1)"
    BODY="$(printf '%s' "$BODY" | head -n -1)"
    GOT_ISSUER="$(printf '%s' "$BODY" | jq -r '.issuer // ""' 2>/dev/null)"
    if [ "$HTTP_STATUS" = "200" ] && [ "$GOT_ISSUER" = "$EXPECTED_ISSUER" ]; then
      kc_ok=1
      break
    else
      log "  attempt at ${KC_ELAPSED}s: status=$HTTP_STATUS issuer=${GOT_ISSUER:-none}"
    fi
  else
    log "  attempt at ${KC_ELAPSED}s: curl failed (TLS error, DNS, or connection refused)"
  fi

  if [ "$KC_ELAPSED" -ge "$KC_POLL_MAX" ]; then
    break
  fi

  sleep "$KC_POLL_INTERVAL"
done

if [ "$kc_ok" -ne 1 ]; then
  ng "keycloak at $URL did not return HTTP 200 + issuer $EXPECTED_ISSUER within ${KC_POLL_MAX}s"
  ng "  (last HTTP_STATUS=${HTTP_STATUS:-none})"
  ng "  Indicates: keycloak pods not Running (DB secret/admin secret/realm CM missing,"
  ng "  RDS unreachable — OI-2026-06-11-1, or DB creds wrong), realm 'platform' not"
  ng "  imported, ingress-nginx not routing auth.*, ExternalDNS record missing, or"
  ng "  ACM cert not valid for ${HOST}"
  exit 1
fi

ok "$URL returned HTTP 200 with issuer $EXPECTED_ISSUER after $(($(date +%s) - KC_START))s"

# ── §3 — Paired hub-side ArgoCD assertion (via SSM relay) ─────────────────────
log "asserting hub ArgoCD Application '$KC_APP' Synced+Healthy via SSM relay on $HUB_CLUSTER"

APP_JSON=""; relay_ok=0
for attempt in $(seq 1 "$RELAY_ATTEMPTS"); do
  APP_JSON="$("$HELPER" -c "$HUB_CLUSTER" -r "$REGION" --exec \
                kubectl get application "$KC_APP" -n argocd -o json 2>/dev/null)" || true
  if [ -n "$APP_JSON" ] && printf '%s' "$APP_JSON" | jq -e '.status' >/dev/null 2>&1; then
    relay_ok=1; break
  fi
  log "relay attempt $attempt/$RELAY_ATTEMPTS did not return parseable Application JSON for $HUB_CLUSTER; retry in ${RELAY_INTERVAL}s"
  [ "$attempt" -lt "$RELAY_ATTEMPTS" ] && sleep "$RELAY_INTERVAL"
done

if [ "$relay_ok" -ne 1 ]; then
  log "RELAY UNREACHABLE for $HUB_CLUSTER after $RELAY_ATTEMPTS attempts."
  log "  → This is a relay/SSM-tunnel failure, NOT evidence that ArgoCD is unhealthy."
  skip "hub kube API not reachable for $HUB_CLUSTER after $RELAY_ATTEMPTS relay attempts (tunnel flake — not an ArgoCD absence)"
fi

SYNC_STATUS="$(printf '%s' "$APP_JSON" | jq -r '.status.sync.status // "Unknown"')"
HEALTH_STATUS="$(printf '%s' "$APP_JSON" | jq -r '.status.health.status // "Unknown"')"

log "ArgoCD Application $KC_APP: sync=$SYNC_STATUS health=$HEALTH_STATUS"

if [ "$SYNC_STATUS" != "Synced" ] || [ "$HEALTH_STATUS" != "Healthy" ]; then
  ng "ArgoCD Application $KC_APP on hub $HUB_CLUSTER is NOT Synced+Healthy"
  ng "  sync.status=$SYNC_STATUS  (expected: Synced)"
  ng "  health.status=$HEALTH_STATUS  (expected: Healthy)"
  LAST_COND="$(printf '%s' "$APP_JSON" | jq -r '
    (.status.conditions // [])[-1]
    | if . then "type=\(.type) message=\(.message // "n/a")" else "no conditions" end')"
  ng "  last condition: $LAST_COND"
  exit 1
fi

ok "ArgoCD Application $KC_APP on hub $HUB_CLUSTER: sync=$SYNC_STATUS health=$HEALTH_STATUS"

# ── All assertions passed ─────────────────────────────────────────────────────
covers "platform.keycloak/e2e"
exit "$LIVE_RC_PASS"
