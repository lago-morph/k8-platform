#!/usr/bin/env bash
# Pins the keycloak realm-import JSON to what Keycloak's STRICT Jackson
# parser actually accepts. Red-first reproduction of the clean-build-#3
# defect (2026-06-12): the realm ConfigMap carried `"comment"` fields as
# in-JSON documentation, and Keycloak 24 rejects any unknown field on
# RealmRepresentation (and its nested mapper/client representations) —
# `ERROR: Failed to import realms ... Unrecognized field "comment"` →
# the StatefulSet CrashLoops on first boot.
#
# Contract:
#   1. Every data key in the realm ConfigMap parses as JSON.
#   2. No `comment` key anywhere EXCEPT inside `config`/`attributes`
#      maps (the only places Keycloak accepts arbitrary string keys).
#      Documentation belongs in the YAML header, not the JSON.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq
require_tool jq

ROOT="$HERE/../.."
CM="$ROOT/platform-services/keycloak/spoke/realm-platform-configmap.yaml"

[ -f "$CM" ] || { fail "realm ConfigMap present" "$CM missing"; summary; }
pass "realm ConfigMap present"

keys="$(yq -r '.data | keys | .[]' "$CM")"
[ -n "$keys" ] || { fail "ConfigMap has data keys" "empty .data"; summary; }

while IFS= read -r k; do
  json="$(yq -r ".data[\"$k\"]" "$CM")"

  if printf '%s' "$json" | jq empty >/dev/null 2>&1; then
    pass "$k parses as JSON"
  else
    fail "$k parses as JSON" "$(printf '%s' "$json" | jq empty 2>&1 | head -1)"
    continue
  fi

  # `comment` keys outside config/attributes maps are unknown fields to
  # Keycloak's strict representations and abort the realm import.
  bad="$(printf '%s' "$json" | jq -r '
    [paths
     | select(.[-1] == "comment")
     | select((length < 2) or ((.[-2] != "config") and (.[-2] != "attributes")))
     | join(".")] | join(", ")')"
  if [ -z "$bad" ]; then
    pass "$k has no comment fields outside config/attributes"
  else
    fail "$k carries unknown 'comment' field(s)" "at: $bad — Keycloak strict parsing aborts the import; document in the YAML header instead"
  fi
done <<< "$keys"

summary
