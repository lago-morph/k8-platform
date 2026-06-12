#!/usr/bin/env bash
# Pins the keycloak-admin bootstrap-secret SOURCE to the OI-2026-06-12-1
# quarantine contract: while no committed Application syncs the
# XPlatformSecret producers (argocd/apps/keycloak-secrets.yaml was reverted
# out of PR #227 with the material chain), the spoke keycloak-admin
# ExternalSecret MUST be the in-cluster generatorRef form — an ASM-pull
# remoteRef references a key nothing provisions, and with
# deletionPolicy: Delete ESO actively DELETES the target Secret, leaving
# the StatefulSet in CreateContainerConfigError forever.
#
# This is the red-first reproduction of the clean-build-#3 defect
# (2026-06-12): the PR #227 revert restored everything EXCEPT this file,
# which kept the chain's ASM-pull form (`k8-platform/keycloak/keycloak-admin`)
# while the producer Application was reverted away. Live symptom: ES status
# SecretDeleted, secret "keycloak-admin" not found, keycloak pods 0/1.
#
# When the OI-2026-06-12-1 material-chain rework re-lands the producer
# (the keycloak-secrets Application + valued XPlatformSecret chain), this
# test is updated IN THE SAME PR to assert the ASM-pull form against the
# deterministic key the chain provisions (audit-before-enforce: the swap
# and its producer land together or not at all).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
ES_FILE="$ROOT/platform-services/keycloak/spoke/keycloak-admin-externalsecret.yaml"
PRODUCER_APP="$ROOT/argocd/apps/keycloak-secrets.yaml"
VALUES="$ROOT/platform-services/keycloak/values.yaml"

[ -f "$ES_FILE" ] || { fail "manifest present" "$ES_FILE missing"; summary; }
pass "keycloak-admin ES manifest present"

if [ -f "$PRODUCER_APP" ]; then
  # The material chain re-landed: the ASM-pull form is legitimate again.
  # This test's quarantine assertions no longer apply — the re-landing PR
  # must replace them with the producer-coupled contract (see header).
  fail "quarantine contract stale" \
    "argocd/apps/keycloak-secrets.yaml exists — update this test in the same PR to pin the ASM-pull form against the chain's deterministic key"
  summary
fi
pass "no committed XPlatformSecret producer Application (quarantine state)"

# ---- the ExternalSecret doc --------------------------------------------------
es_doc() { yq 'select(.kind == "ExternalSecret")' "$ES_FILE"; }
gen_doc() { yq 'select(.kind == "Password")' "$ES_FILE"; }

[ "$(es_doc | yq -r '.metadata.name + "/" + .metadata.namespace')" = "keycloak-admin/keycloak" ] \
  && pass "ES is keycloak-admin in ns keycloak" \
  || fail "ES identity" "$(es_doc | yq -r '.metadata.name + "/" + .metadata.namespace')"

# No remoteRef to an unprovisioned platform ASM key while quarantined.
remote_keys="$(es_doc | yq -r '[.spec.data[]?.remoteRef.key] | join(",")')"
if [ -z "$remote_keys" ] || [ "$remote_keys" = "null" ]; then
  pass "ES has no ASM remoteRef (in-cluster generation only)"
else
  fail "ES pulls from ASM while no producer exists" "remoteRef keys: $remote_keys"
fi

# generatorRef present and bound to a Password generator in the same file.
gen_ref="$(es_doc | yq -r '.spec.dataFrom[0].sourceRef.generatorRef.kind + "/" + .spec.dataFrom[0].sourceRef.generatorRef.name')"
[ "$gen_ref" = "Password/keycloak-admin-password" ] \
  && pass "ES sources a generatorRef (Password/keycloak-admin-password)" \
  || fail "ES generatorRef" "got: $gen_ref"

[ "$(gen_doc | yq -r '.metadata.name + "/" + .metadata.namespace')" = "keycloak-admin-password/keycloak" ] \
  && pass "Password generator doc present in the same file, same ns" \
  || fail "Password generator" "$(gen_doc | yq -r '.metadata.name + "/" + .metadata.namespace')"

# Generate ONCE: a regenerating bootstrap password rotates under the
# running StatefulSet.
[ "$(es_doc | yq -r '.spec.refreshInterval')" = "0" ] \
  && pass "refreshInterval 0 (generate once)" \
  || fail "refreshInterval" "got: $(es_doc | yq -r '.spec.refreshInterval')"

# Retain on delete: Delete is the policy that erased the live Secret when
# the source went missing.
[ "$(es_doc | yq -r '.spec.target.deletionPolicy')" = "Retain" ] \
  && pass "target deletionPolicy Retain" \
  || fail "deletionPolicy" "got: $(es_doc | yq -r '.spec.target.deletionPolicy')"

# Template must materialize the key the chart consumes.
[ "$(es_doc | yq -r '.spec.target.name')" = "keycloak-admin" ] \
  && pass "target Secret named keycloak-admin" \
  || fail "target name" "got: $(es_doc | yq -r '.spec.target.name')"

tmpl_pw="$(es_doc | yq -r '.spec.target.template.data["admin-password"]')"
[ "$tmpl_pw" = "{{ .password }}" ] \
  && pass "template maps admin-password from the generator's .password" \
  || fail "template key" "got: $tmpl_pw"

# Chart side: values.yaml must consume exactly that Secret/key.
[ "$(yq -r '.auth.existingSecret' "$VALUES")" = "keycloak-admin" ] \
  && pass "values.yaml auth.existingSecret=keycloak-admin" \
  || fail "values existingSecret" "got: $(yq -r '.auth.existingSecret' "$VALUES")"

[ "$(yq -r '.auth.passwordSecretKey' "$VALUES")" = "admin-password" ] \
  && pass "values.yaml auth.passwordSecretKey=admin-password" \
  || fail "values passwordSecretKey" "got: $(yq -r '.auth.passwordSecretKey' "$VALUES")"

# Wave guard: every doc in the file rides wave <= 0 (a pod-mounted Secret
# in a later wave than the wave-0 StatefulSet deadlocks the first sync).
while IFS= read -r w; do
  [ "$w" = "---" ] && continue   # mikefarah yq doc separator in raw mode
  [ -z "$w" ] && w="0"
  if [ "$w" -le 0 ] 2>/dev/null; then
    pass "wave guard: doc wave $w <= 0"
  else
    fail "wave guard" "sync-wave $w > 0"
  fi
done < <(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"] // ""' "$ES_FILE")

summary
