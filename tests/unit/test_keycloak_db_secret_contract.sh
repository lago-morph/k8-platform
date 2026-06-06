#!/usr/bin/env bash
# Unit tests for the Keycloak ↔ XDatabase connection-Secret contract
# (phase 5, REQ-AUTH DB).
#
# Bug-of-record (this test would have FAILED before fix A1): the RDS
# Composition writes connection keys `username` / `password` to a Secret
# named after the XDatabase XR (writeConnectionSecretToRef.name :=
# metadata.name). The Keycloak XDatabase XR is named `keycloak-db`, so the
# Secret is `keycloak-db`. But keycloak/values.yaml previously read
#   existingSecret: keycloak-db
#   existingSecretUserKey: db-username      <-- WRONG (never written)
#   existingSecretPasswordKey: db-password  <-- WRONG (never written)
# so Keycloak would start with empty DB credentials and crash-loop. The
# three values are reconciled to: existingSecret == keycloak-db (== the XR
# name == the Secret the Composition publishes), existingSecretUserKey ==
# username, existingSecretPasswordKey == password (the keys RDS writes).
#
# This test pins all three to the OTHER side of the contract so a future
# edit to either the chart values or the XR name re-surfaces the mismatch.
#
# Uses raw `yq -r` (python/jq-flavored yq, matching test_keycloak_apps.sh)
# via the lib/test-helpers.sh harness — works under either yq variant.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
VALUES="$ROOT/platform-services/keycloak/values.yaml"
XR="$ROOT/platform-services/keycloak/database/keycloak-db.yaml"
COMP="$ROOT/crossplane/compositions/xdatabase.yaml"

[ -f "$VALUES" ] || { echo "FAIL: $VALUES missing"; exit 1; }
[ -f "$XR" ]     || { echo "FAIL: $XR missing"; exit 1; }
[ -f "$COMP" ]   || { echo "FAIL: $COMP missing"; exit 1; }

# ---- The keys the RDS Composition actually writes ------------------------
# These are the provider-aws-rds connection-detail key names. They are the
# contract's source of truth; values.yaml must match them.
WRITTEN_USER_KEY="username"
WRITTEN_PASS_KEY="password"

# ---- The Secret name the keycloak-db XR produces -------------------------
# The Composition patches writeConnectionSecretToRef.name := metadata.name
# (asserted by test_xdatabase_rds_composition.sh), so the connection Secret
# name == the XR's metadata.name. Read the XR name and require it == the
# chart's existingSecret. (We also independently require it to be the
# canonical `keycloak-db` so the chart's hard-coded existingSecret stays
# correct.)
XR_NAME="$(yq -r '.metadata.name' "$XR")"
[ "$XR_NAME" = "keycloak-db" ] \
  && pass "xr_name_is_keycloak-db ($XR_NAME)" \
  || fail "xr_name_is_keycloak-db" "XDatabase XR name=$XR_NAME, want keycloak-db (= the connection Secret name)"

# Confirm the Composition really patches the connection Secret name from the
# XR name (so XR_NAME == Secret name is a real contract, not a coincidence).
WCS_FROM="$(yq -r '.spec.pipeline[] | select(.functionRef.name=="function-patch-and-transform") | .input.resources[] | select(.name=="rds-instance") | .patches[] | select(.toFieldPath=="spec.writeConnectionSecretToRef.name") | .fromFieldPath' "$COMP" 2>/dev/null | head -1)"
[ "$WCS_FROM" = "metadata.name" ] \
  && pass "composition_connection_secret_name_from_xr_name" \
  || fail "composition_connection_secret_name_from_xr_name" "writeConnectionSecretToRef.name fromFieldPath=$WCS_FROM, want metadata.name"

# ---- values.yaml externalDatabase block ----------------------------------
EXISTING="$(yq -r '.externalDatabase.existingSecret' "$VALUES")"
USERKEY="$(yq -r '.externalDatabase.existingSecretUserKey' "$VALUES")"
PASSKEY="$(yq -r '.externalDatabase.existingSecretPasswordKey' "$VALUES")"

# existingSecret == the Secret the keycloak-db XR produces (== the XR name).
[ "$EXISTING" = "$XR_NAME" ] \
  && pass "existingSecret_matches_xr_secret_name ($EXISTING)" \
  || fail "existingSecret_matches_xr_secret_name" "existingSecret=$EXISTING, want $XR_NAME (the connection Secret the XR publishes)"

# existingSecretUserKey / existingSecretPasswordKey == the keys RDS writes.
[ "$USERKEY" = "$WRITTEN_USER_KEY" ] \
  && pass "existingSecretUserKey_matches_written ($USERKEY)" \
  || fail "existingSecretUserKey_matches_written" "existingSecretUserKey=$USERKEY, want $WRITTEN_USER_KEY (the key the Composition writes; NOT db-username)"

[ "$PASSKEY" = "$WRITTEN_PASS_KEY" ] \
  && pass "existingSecretPasswordKey_matches_written ($PASSKEY)" \
  || fail "existingSecretPasswordKey_matches_written" "existingSecretPasswordKey=$PASSKEY, want $WRITTEN_PASS_KEY (the key the Composition writes; NOT db-password)"

# Negative regression guard: the OLD wrong keys must be gone.
case "$USERKEY" in db-username) fail "userkey_not_old_db-username" "still using the pre-fix db-username key";; *) pass "userkey_not_old_db-username";; esac
case "$PASSKEY" in db-password) fail "passkey_not_old_db-password" "still using the pre-fix db-password key";; *) pass "passkey_not_old_db-password";; esac

summary
