#!/usr/bin/env bash
# Pins the OI-2026-06-07-5 cross-cluster keycloak-db chain END TO END across
# the four committed manifests so any single-file edit re-surfaces the break:
#
#   hub connection Secret `keycloak-db` (XDatabase; provider keys
#   username/password/host/port)
#     → hub PushSecret (platform-services/keycloak/database/
#       keycloak-db-pushsecret.yaml) → ASM k8-platform/keycloak-db
#     → spoke ExternalSecret (platform-services/keycloak/spoke/
#       keycloak-db-externalsecret.yaml) → spoke Secret `keycloak-db`
#       {username, password, KEYCLOAK_DATABASE_HOST, KEYCLOAK_DATABASE_PORT}
#     → chart: existingSecret(username/password) + extraEnvVarsSecret
#       (HOST/PORT envFrom override — premise pinned separately by
#       test_keycloak_db_env_precedence.sh).
#
# Plus the structural guards: the keycloak ApplicationSet actually delivers
# the spoke dir; every manifest in that dir rides wave <= 0 (ArgoCD waits for
# wave health before advancing — a pod-mounted Secret/CM in a LATER wave than
# the chart's wave-0 StatefulSet deadlocks the first sync); the ES
# secretStoreRef matches the spoke ClusterSecretStore the eso ApplicationSet
# delivers (and the hub store keeps the same name, so the PushSecret's ref
# resolves there).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
PUSH="$ROOT/platform-services/keycloak/database/keycloak-db-pushsecret.yaml"
PULL="$ROOT/platform-services/keycloak/spoke/keycloak-db-externalsecret.yaml"
VALUES="$ROOT/platform-services/keycloak/values.yaml"
APPSET="$ROOT/argocd/apps/spoke/keycloak.yaml"
SPOKE_DIR="$ROOT/platform-services/keycloak/spoke"
SPOKE_CSS="$ROOT/platform-services/eso/spoke/cluster-secret-store.yaml"
HUB_CSS="$ROOT/clusters/management/eso/cluster-secret-store.yaml"

for f in "$PUSH" "$PULL" "$VALUES" "$APPSET" "$SPOKE_CSS" "$HUB_CSS"; do
  [ -f "$f" ] || { fail "manifest present" "$f missing"; summary; exit 1; }
done
pass "all chain manifests present"

ASM_KEY="k8-platform/keycloak-db"
CHAIN_KEYS="username password host port"

# ---- hub PushSecret ---------------------------------------------------------
[ "$(yq -r '.spec.selector.secret.name' "$PUSH")" = "keycloak-db" ] \
  && pass "push: selects the XDatabase connection Secret keycloak-db" \
  || fail "push selector" "$(yq -r '.spec.selector.secret.name' "$PUSH")"

[ "$(yq -r '.spec.secretStoreRefs[0].name + "/" + .spec.secretStoreRefs[0].kind' "$PUSH")" = "aws-secrets-manager/ClusterSecretStore" ] \
  && pass "push: store ref aws-secrets-manager/ClusterSecretStore" \
  || fail "push store ref" "$(yq -r '.spec.secretStoreRefs[0].name' "$PUSH")"

for k in $CHAIN_KEYS; do
  rk="$(yq -r ".spec.data[] | select(.match.secretKey==\"$k\") | .match.remoteRef.remoteKey" "$PUSH")"
  prop="$(yq -r ".spec.data[] | select(.match.secretKey==\"$k\") | .match.remoteRef.property" "$PUSH")"
  [ "$rk" = "$ASM_KEY" ] && [ "$prop" = "$k" ] \
    && pass "push: $k → $ASM_KEY#$k" \
    || fail "push key $k" "remoteKey=$rk property=$prop (want $ASM_KEY#$k)"
done

# ---- spoke ExternalSecret ---------------------------------------------------
[ "$(yq -r '.spec.secretStoreRef.name + "/" + .spec.secretStoreRef.kind' "$PULL")" = "aws-secrets-manager/ClusterSecretStore" ] \
  && pass "pull: store ref aws-secrets-manager/ClusterSecretStore" \
  || fail "pull store ref" "$(yq -r '.spec.secretStoreRef.name' "$PULL")"

[ "$(yq -r '.spec.target.name' "$PULL")" = "keycloak-db" ] \
  && pass "pull: target Secret keycloak-db (the chart's existingSecret + extraEnvVarsSecret)" \
  || fail "pull target" "$(yq -r '.spec.target.name' "$PULL")"

for k in $CHAIN_KEYS; do
  rk="$(yq -r ".spec.data[] | select(.secretKey==\"$k\") | .remoteRef.key" "$PULL")"
  prop="$(yq -r ".spec.data[] | select(.secretKey==\"$k\") | .remoteRef.property" "$PULL")"
  [ "$rk" = "$ASM_KEY" ] && [ "$prop" = "$k" ] \
    && pass "pull: $ASM_KEY#$k → dataFrom $k" \
    || fail "pull key $k" "key=$rk property=$prop (want $ASM_KEY#$k)"
done

# template: the four produced keys, mapped from the right extracted values.
declare -A WANT_TPL=(
  [username]="{{ .username }}"
  [password]="{{ .password }}"
  [KEYCLOAK_DATABASE_HOST]="{{ .host }}"
  [KEYCLOAK_DATABASE_PORT]="{{ .port }}"
)
for tk in "${!WANT_TPL[@]}"; do
  got="$(yq -r ".spec.target.template.data[\"$tk\"]" "$PULL")"
  [ "$got" = "${WANT_TPL[$tk]}" ] \
    && pass "pull template: $tk ← ${WANT_TPL[$tk]}" \
    || fail "pull template $tk" "got '$got', want '${WANT_TPL[$tk]}'"
done

# ---- chart consumption ------------------------------------------------------
[ "$(yq -r '.extraEnvVarsSecret' "$VALUES")" = "keycloak-db" ] \
  && pass "values: extraEnvVarsSecret=keycloak-db (HOST/PORT envFrom carrier)" \
  || fail "values extraEnvVarsSecret" "$(yq -r '.extraEnvVarsSecret' "$VALUES")"

[ "$(yq -r '.externalDatabase.existingSecretUserKey' "$VALUES")" = "username" ] \
  && [ "$(yq -r '.externalDatabase.existingSecretPasswordKey' "$VALUES")" = "password" ] \
  && pass "values: existingSecret keys match the pull template (username/password)" \
  || fail "values existingSecret keys" "drifted from the pull template keys"

# ---- delivery: the keycloak AppSet ships the spoke dir ----------------------
SRC_PATH="$(yq -r '.spec.template.spec.sources[] | select(.path != null) | .path' "$APPSET" | head -1)"
[ "$SRC_PATH" = "platform-services/keycloak/spoke" ] \
  && pass "appset: third source delivers platform-services/keycloak/spoke" \
  || fail "appset directory source" "got '$SRC_PATH'"

# ---- wave guard: every spoke-dir manifest at wave <= 0 ----------------------
for f in "$SPOKE_DIR"/*.yaml; do
  base="$(basename "$f")"
  while IFS= read -r w; do
    # multi-doc files: yq emits a bare --- between documents; skip it along
    # with docs that carry no wave annotation.
    if [ -z "$w" ] || [ "$w" = "null" ] || [ "$w" = "---" ]; then continue; fi
    if [ "$w" -le 0 ] 2>/dev/null; then
      pass "wave guard: $base wave $w <= 0 (applies before the chart's wave-0)"
    else
      fail "wave guard: $base" "sync-wave $w > 0 — pod-mounted resources in a later wave than the StatefulSet deadlock the first sync"
    fi
  done < <(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"] // ""' "$f")
done

# ---- store-name invariant across hub + spoke --------------------------------
for css in "$HUB_CSS" "$SPOKE_CSS"; do
  [ "$(yq -r '.metadata.name' "$css")" = "aws-secrets-manager" ] \
    && pass "css: $(basename "$(dirname "$css")") store named aws-secrets-manager" \
    || fail "css name" "$css: $(yq -r '.metadata.name' "$css")"
done

summary
