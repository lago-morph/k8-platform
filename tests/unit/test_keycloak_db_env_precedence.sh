#!/usr/bin/env bash
# RENDER FIXTURE — proves the duplicate-env-name precedence premise behind the
# keycloak DB host/port mechanism (OI-2026-06-07-5; ADR-0010 "PR-2 resolutions"
# Decision 3 explicitly labels it an UNVERIFIED premise that this fixture must
# prove before wiring):
#
#   The ESO-materialized spoke Secret `keycloak-db` carries
#   KEYCLOAK_DATABASE_HOST/PORT keys and is attached via the chart's
#   `extraEnvVarsSecret`. For those keys to WIN over the chart-rendered
#   placeholder values, Kubernetes env semantics require this exact shape on
#   the rendered StatefulSet container:
#
#   1. KEYCLOAK_DATABASE_HOST/PORT must NOT be explicit `env:` entries —
#      explicit env always beats envFrom, which would make the override
#      impossible. (The chart routes externalDatabase.host/port through the
#      keycloak-env-vars ConfigMap consumed via envFrom.)
#   2. The container's envFrom must list the keycloak-env-vars configMapRef
#      BEFORE the extraEnvVarsSecret secretRef. Kubernetes resolves duplicate
#      keys across envFrom sources LAST-SOURCE-WINS (kubelet populates the env
#      map in list order, later sources overwrite earlier ones), so the
#      Secret's HOST/PORT override the ConfigMap's placeholders.
#   3. The ConfigMap carries the to-be-overridden KEYCLOAK_DATABASE_HOST/PORT
#      from externalDatabase.host/port (proving the values actually travel
#      that path and the override is load-bearing, not vacuous).
#   4. The explicit env DOES carry KEYCLOAK_DATABASE_USER/PASSWORD via
#      valueFrom on the SAME `keycloak-db` Secret (existingSecret keys) — no
#      conflict with the envFrom override, one Secret serves both paths.
#
# Renders the PINNED bitnami/keycloak chart (21.4.4 — the targetRevision in
# argocd/apps/spoke/keycloak.yaml) with the repo's committed values file plus
# the committed extraEnvVarsSecret value, exactly what ArgoCD deploys.
# Network-dependent like test_helm_render.sh (chart repo fetch).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

require_tool helm
require_tool yq

ROOT="$HERE/../.."
VALUES="$ROOT/platform-services/keycloak/values.yaml"
APPSET="$ROOT/argocd/apps/spoke/keycloak.yaml"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Chart version pinned by the ApplicationSet — render exactly that.
CHART_VERSION="$(yq -r '.spec.template.spec.sources[] | select(.chart=="keycloak") | .targetRevision' "$APPSET")"
[ -n "$CHART_VERSION" ] && [ "$CHART_VERSION" != "null" ] \
  && pass "appset pins bitnami/keycloak chart version ($CHART_VERSION)" \
  || { fail "appset chart version not found" "argocd/apps/spoke/keycloak.yaml"; summary; exit 1; }

# The committed values file must itself set extraEnvVarsSecret=keycloak-db —
# the override rides git, not a render-time flag.
EEVS="$(yq -r '.extraEnvVarsSecret // ""' "$VALUES")"
[ "$EEVS" = "keycloak-db" ] \
  && pass "values.yaml sets extraEnvVarsSecret=keycloak-db" \
  || fail "values.yaml extraEnvVarsSecret" "got '$EEVS', want keycloak-db (the OI-2026-06-07-5 host/port carrier)"

OUT="$TMP/keycloak.yaml"
if ! helm template keycloak keycloak \
    --repo "https://charts.bitnami.com/bitnami" \
    --version "$CHART_VERSION" \
    --namespace keycloak \
    -f "$VALUES" \
    > "$OUT" 2> "$OUT.err"; then
  fail "helm template bitnami/keycloak $CHART_VERSION" "$(tail -5 "$OUT.err")"
  summary
  exit 1
fi
pass "helm template renders (chart $CHART_VERSION + committed values)"

STS_CONTAINER='select(.kind=="StatefulSet" and .metadata.name=="keycloak") | .spec.template.spec.containers[] | select(.name=="keycloak")'

# ---- 1. HOST/PORT are NOT explicit env entries ----------------------------
ENV_NAMES="$(yq -r "$STS_CONTAINER | .env[].name" "$OUT")"
for var in KEYCLOAK_DATABASE_HOST KEYCLOAK_DATABASE_PORT; do
  hits="$(grep -c "^${var}\$" <<<"$ENV_NAMES" || true)"
  [ "$hits" = "0" ] \
    && pass "$var is NOT an explicit container env (explicit env would beat envFrom)" \
    || fail "$var explicit env" "found $hits explicit env entr(ies) — the extraEnvVarsSecret override CANNOT win; premise broken"
done

# ---- 2. envFrom order: configMapRef(keycloak-env-vars) BEFORE secretRef ----
CM_IDX="$(yq -r "$STS_CONTAINER | .envFrom | to_entries | .[] | select(.value.configMapRef.name==\"keycloak-env-vars\") | .key" "$OUT" | head -1)"
SEC_IDX="$(yq -r "$STS_CONTAINER | .envFrom | to_entries | .[] | select(.value.secretRef.name==\"keycloak-db\") | .key" "$OUT" | head -1)"
[ -n "$CM_IDX" ] && [ "$CM_IDX" != "null" ] \
  && pass "envFrom has configMapRef keycloak-env-vars (index $CM_IDX)" \
  || fail "envFrom configMapRef" "keycloak-env-vars configMapRef not in envFrom"
[ -n "$SEC_IDX" ] && [ "$SEC_IDX" != "null" ] \
  && pass "envFrom has secretRef keycloak-db (index $SEC_IDX)" \
  || fail "envFrom secretRef" "keycloak-db secretRef not in envFrom (extraEnvVarsSecret not rendered)"
if [ -n "$CM_IDX" ] && [ -n "$SEC_IDX" ] && [ "$CM_IDX" != "null" ] && [ "$SEC_IDX" != "null" ]; then
  [ "$SEC_IDX" -gt "$CM_IDX" ] \
    && pass "secretRef AFTER configMapRef ($SEC_IDX > $CM_IDX) — k8s last-source-wins gives the Secret precedence" \
    || fail "envFrom order" "secretRef index $SEC_IDX <= configMapRef index $CM_IDX — ConfigMap would win; premise broken"
fi

# ---- 3. the ConfigMap carries the to-be-overridden HOST/PORT --------------
CM_HOST="$(yq -r 'select(.kind=="ConfigMap" and .metadata.name=="keycloak-env-vars") | .data.KEYCLOAK_DATABASE_HOST' "$OUT")"
CM_PORT="$(yq -r 'select(.kind=="ConfigMap" and .metadata.name=="keycloak-env-vars") | .data.KEYCLOAK_DATABASE_PORT' "$OUT")"
[ "$CM_HOST" = "$(yq -r '.externalDatabase.host' "$VALUES")" ] \
  && pass "ConfigMap KEYCLOAK_DATABASE_HOST == values externalDatabase.host ($CM_HOST)" \
  || fail "ConfigMap HOST routing" "got '$CM_HOST' — externalDatabase.host no longer travels the envFrom ConfigMap; re-verify the whole premise"
[ "$CM_PORT" = "\"$(yq -r '.externalDatabase.port' "$VALUES")\"" ] || [ "$CM_PORT" = "$(yq -r '.externalDatabase.port' "$VALUES")" ] \
  && pass "ConfigMap KEYCLOAK_DATABASE_PORT == values externalDatabase.port ($CM_PORT)" \
  || fail "ConfigMap PORT routing" "got '$CM_PORT'"

# ---- 4. USER/PASSWORD stay explicit valueFrom on the same Secret ----------
for pair in "KEYCLOAK_DATABASE_USER:username" "KEYCLOAK_DATABASE_PASSWORD:password"; do
  var="${pair%%:*}"; key="${pair##*:}"
  ref="$(yq -r "$STS_CONTAINER | .env[] | select(.name==\"$var\") | .valueFrom.secretKeyRef | .name + \"/\" + .key" "$OUT")"
  [ "$ref" = "keycloak-db/$key" ] \
    && pass "$var ← secretKeyRef keycloak-db/$key (explicit env, no envFrom conflict)" \
    || fail "$var secretKeyRef" "got '$ref', want keycloak-db/$key"
done

summary
