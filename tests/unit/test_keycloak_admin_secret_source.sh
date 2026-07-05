#!/usr/bin/env bash
# Pins the keycloak-admin bootstrap-secret SOURCE to the producer-coupled
# contract of the OI-2026-06-12-1 material-chain re-land (ADR-12992f055b):
# the spoke keycloak-admin ExternalSecret is the ASM-pull form, and the
# key it pulls is provisioned by a COMMITTED producer — the keycloak-admin
# XPlatformSecret (platform-services/keycloak/secrets/keycloak-secrets.yaml)
# synced by argocd/apps/keycloak-secrets.yaml, whose Composition writes
# in-platform generated material to the deterministic
# k8-platform/<namespace>/<name> ASM key.
#
# History (clean-build-#3 defect, 2026-06-12): the PR #227 chain revert
# restored everything EXCEPT this file, leaving an ASM-pull ES whose source
# nothing provisioned; with deletionPolicy Delete, ESO actively DELETED the
# target Secret (keycloak pods CreateContainerConfigError). The quarantine
# form of this test (#231) pinned the interim generatorRef ES and
# self-flagged the moment the producer Application reappeared, forcing
# file + producer + test to move together — which is exactly this update.
#
# The coupling this test enforces (either side changing alone fails):
#   1. The producer Application exists and syncs the XR directory.
#   2. The committed keycloak-admin XPlatformSecret exists — and the ES
#      remoteRef key equals k8-platform/<XR-ns>/<XR-name> DERIVED from
#      that XR document, not hardcoded twice.
#   3. The ES has no generatorRef and the spoke file ships no Password
#      generator (the interim in-cluster generation is retired).
#   4. deletionPolicy Retain (the #231 lesson: never let a source gap
#      erase the running StatefulSet's bootstrap credential).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
ES_FILE="$ROOT/platform-services/keycloak/spoke/keycloak-admin-externalsecret.yaml"
PRODUCER_APP="$ROOT/argocd/apps/keycloak-secrets.yaml"
PRODUCER_XRS="$ROOT/platform-services/keycloak/secrets/keycloak-secrets.yaml"
VALUES="$ROOT/platform-services/keycloak/values.yaml"

[ -f "$ES_FILE" ] || { fail "manifest present" "$ES_FILE missing"; summary; }
pass "keycloak-admin ES manifest present"

# ---- 1. the producer Application ---------------------------------------------
if [ ! -f "$PRODUCER_APP" ]; then
  fail "producer Application present" \
    "argocd/apps/keycloak-secrets.yaml missing — an ASM-pull consumer without a committed producer is the #231 defect; if the chain was reverted again, swap this file back to the generatorRef form IN THE SAME PR"
  summary
fi
pass "producer Application argocd/apps/keycloak-secrets.yaml present"

app_path="$(yq -r '.spec.source.path' "$PRODUCER_APP")"
[ "$app_path" = "platform-services/keycloak/secrets" ] \
  && pass "producer app syncs platform-services/keycloak/secrets" \
  || fail "producer app path" "got: $app_path"

# ---- 2. the committed XR producer + derived key coupling ---------------------
[ -f "$PRODUCER_XRS" ] || { fail "producer XRs present" "$PRODUCER_XRS missing"; summary; }

xr_ns_name="$(yq -r 'select(.kind == "XPlatformSecret") | select(.metadata.name == "keycloak-admin") | .metadata.namespace + "/" + .metadata.name' "$PRODUCER_XRS")"
[ "$xr_ns_name" = "keycloak/keycloak-admin" ] \
  && pass "committed keycloak-admin XPlatformSecret present (ns keycloak)" \
  || fail "producer XR" "got: '$xr_ns_name' — expected keycloak/keycloak-admin in $PRODUCER_XRS"

# The deterministic key the platform-secret Composition provisions for that
# XR (fmt pinned by tests/unit/test_platform_secret_composition.sh).
expected_key="k8-platform/${xr_ns_name}"

# ---- 3. the ExternalSecret doc ------------------------------------------------
es_doc() { yq 'select(.kind == "ExternalSecret")' "$ES_FILE"; }

[ "$(es_doc | yq -r '.metadata.name + "/" + .metadata.namespace')" = "keycloak-admin/keycloak" ] \
  && pass "ES is keycloak-admin in ns keycloak" \
  || fail "ES identity" "$(es_doc | yq -r '.metadata.name + "/" + .metadata.namespace')"

remote_key="$(es_doc | yq -r '.spec.data[0].remoteRef.key')"
[ "$remote_key" = "$expected_key" ] \
  && pass "ES pulls the producer's deterministic ASM key ($expected_key)" \
  || fail "ES remoteRef key" "got: '$remote_key' — must equal k8-platform/<XR-ns>/<XR-name> = $expected_key"

remote_prop="$(es_doc | yq -r '.spec.data[0].remoteRef.property')"
[ "$remote_prop" = "value" ] \
  && pass "ES extracts the chain's payload key (property: value)" \
  || fail "ES remoteRef property" "got: '$remote_prop' — the material ES renders {\"value\":…}"

# No generatorRef and no Password generator doc: in-cluster generation is
# retired with the chain re-land (ASM is the single source of truth).
gen_ref="$(es_doc | yq -r '.spec.dataFrom[0].sourceRef.generatorRef.kind // ""')"
[ -z "$gen_ref" ] \
  && pass "ES has no generatorRef (ASM-pull form)" \
  || fail "ES still sources a generator" "generatorRef kind: $gen_ref"

pw_docs="$(yq 'select(.kind == "Password")' "$ES_FILE" | grep -c "kind: Password" || true)"
[ "$pw_docs" = "0" ] \
  && pass "no Password generator doc ships in the spoke file" \
  || fail "Password generator still present" "$pw_docs Password doc(s) in $ES_FILE"

# Retain on delete/source-loss: Delete is the policy that erased the live
# Secret when the source went missing (#231).
[ "$(es_doc | yq -r '.spec.target.deletionPolicy')" = "Retain" ] \
  && pass "target deletionPolicy Retain" \
  || fail "deletionPolicy" "got: $(es_doc | yq -r '.spec.target.deletionPolicy')"

[ "$(es_doc | yq -r '.spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name')" = "ClusterSecretStore/aws-secrets-manager" ] \
  && pass "ES uses the shared ClusterSecretStore" \
  || fail "secretStoreRef" "got: $(es_doc | yq -r '.spec.secretStoreRef.kind + "/" + .spec.secretStoreRef.name')"

# Template must materialize the key the chart consumes, from the pulled
# `value` property.
[ "$(es_doc | yq -r '.spec.target.name')" = "keycloak-admin" ] \
  && pass "target Secret named keycloak-admin" \
  || fail "target name" "got: $(es_doc | yq -r '.spec.target.name')"

tmpl_pw="$(es_doc | yq -r '.spec.target.template.data["admin-password"]')"
[ "$tmpl_pw" = "{{ .value }}" ] \
  && pass "template maps admin-password from the pulled .value" \
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
