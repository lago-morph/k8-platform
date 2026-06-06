#!/usr/bin/env bash
# Unit tests for the Keycloak XDatabase XR (phase 5, REQ-AUTH DB):
# platform-services/keycloak/database/keycloak-db.yaml.
#
# Bug class defended:
#   - The XR must be NAMED keycloak-db (the connection Secret it produces is
#     named after it via writeConnectionSecretToRef.name := metadata.name;
#     keycloak/values.yaml hard-codes existingSecret: keycloak-db). A rename
#     silently breaks the secret contract.
#   - It must live in the keycloak namespace (v2 namespaced XR; the
#     connection Secret lands in the XR's namespace, where the Keycloak pods
#     read it).
#   - engine postgres + databaseName keycloak (Keycloak needs Postgres named
#     `keycloak`, matching values.yaml externalDatabase.database).
#   - sync-wave ordering: the DB must provision BEFORE the Keycloak App
#     (wave 40) and be consistent with the keycloak-secrets XRs (wave 35) —
#     i.e. a wave <= 35 and < 40. A wave at/after 40 would start Keycloak
#     before the DB Secret exists.
#
# Uses raw `yq -r` via lib/test-helpers.sh (works under either yq variant).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
XR="$ROOT/platform-services/keycloak/database/keycloak-db.yaml"
SECRETS="$ROOT/platform-services/keycloak/secrets/keycloak-secrets.yaml"
APP="$ROOT/argocd/apps/spoke/keycloak.yaml"

[ -f "$XR" ] || { echo "FAIL: $XR missing"; exit 1; }

# ---- 1. It is an XDatabase XR --------------------------------------------
KIND="$(yq -r '.kind' "$XR")"
[ "$KIND" = "XDatabase" ] && pass "kind=XDatabase" \
  || fail "kind=XDatabase" "kind=$KIND, want XDatabase"

APIV="$(yq -r '.apiVersion' "$XR")"
[ "$APIV" = "platform.k8-platform.io/v1alpha1" ] && pass "apiVersion pinned ($APIV)" \
  || fail "apiVersion" "apiVersion=$APIV, want platform.k8-platform.io/v1alpha1"

# ---- 2. Named keycloak-db in the keycloak namespace ----------------------
NAME="$(yq -r '.metadata.name' "$XR")"
[ "$NAME" = "keycloak-db" ] && pass "name=keycloak-db" \
  || fail "name=keycloak-db" "name=$NAME, want keycloak-db (= the connection Secret name)"

NS="$(yq -r '.metadata.namespace' "$XR")"
[ "$NS" = "keycloak" ] && pass "namespace=keycloak" \
  || fail "namespace=keycloak" "namespace=$NS, want keycloak"

# ---- 3. engine postgres + databaseName keycloak -------------------------
ENGINE="$(yq -r '.spec.engine' "$XR")"
[ "$ENGINE" = "postgres" ] && pass "engine=postgres" \
  || fail "engine=postgres" "engine=$ENGINE, want postgres"

DBNAME="$(yq -r '.spec.databaseName' "$XR")"
[ "$DBNAME" = "keycloak" ] && pass "databaseName=keycloak" \
  || fail "databaseName=keycloak" "databaseName=$DBNAME, want keycloak"

# ---- 4. sync-wave ordering ----------------------------------------------
WAVE="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$XR")"
if [ -z "$WAVE" ] || [ "$WAVE" = "null" ]; then
  fail "db_xr_sync_wave_present" "no argocd.argoproj.io/sync-wave annotation"
else
  pass "db_xr_sync_wave_present ($WAVE)"

  # Keycloak App wave (40) — the DB must come strictly before it.
  APP_WAVE="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$APP" 2>/dev/null)"
  [ -z "$APP_WAVE" ] && APP_WAVE=40
  if [ "$WAVE" -lt "$APP_WAVE" ] 2>/dev/null; then
    pass "db_xr_wave_before_keycloak_app ($WAVE < $APP_WAVE)"
  else
    fail "db_xr_wave_before_keycloak_app" "DB wave $WAVE not < Keycloak App wave $APP_WAVE"
  fi

  # keycloak-secrets XR wave (~35) — DB should be <= the secrets wave so the
  # database is in flight before/at the secrets, and both before the App.
  SEC_WAVE="$(yq -r 'select(.kind=="XPlatformSecret") | .metadata.annotations."argocd.argoproj.io/sync-wave"' "$SECRETS" 2>/dev/null | head -1)"
  [ -z "$SEC_WAVE" ] && SEC_WAVE=35
  if [ "$WAVE" -le "$SEC_WAVE" ] 2>/dev/null; then
    pass "db_xr_wave_consistent_with_secrets ($WAVE <= $SEC_WAVE)"
  else
    fail "db_xr_wave_consistent_with_secrets" "DB wave $WAVE > keycloak-secrets wave $SEC_WAVE"
  fi
fi

summary
