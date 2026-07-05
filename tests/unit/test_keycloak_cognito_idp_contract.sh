#!/usr/bin/env bash
# Pins the Cognito-broker delivery contract across its four files
# (REQ-AUTH-02/08; the fail-closed env-substitution chain):
#
#   terraform/base/cognito.tf
#     └─ writes ASM k8-platform/base/cognito {8 JSON keys}
#   platform-services/keycloak/spoke/keycloak-cognito-idp-externalsecret.yaml
#     └─ pulls that exact ASM name → Secret keycloak-cognito-idp
#   argocd/apps/spoke/keycloak.yaml (ApplicationSet valuesObject)
#     └─ maps each Secret key → KC_COGNITO_* env via NON-optional secretKeyRef
#   platform-services/keycloak/spoke/realm-platform-configmap.yaml
#     └─ realm import substitutes ${KC_COGNITO_*} from container env
#
# Why each leg matters:
#   - An env placeholder in the realm with NO matching extraEnvVars entry
#     survives import as a literal and fails Keycloak's import-time URL
#     validation → CrashLoop (the #233 class, proven empirically on the
#     pinned Keycloak 24.0.5).
#   - An `optional: true` secretKeyRef would let the pod start without the
#     Secret — same literal-placeholder crash, but nondeterministic.
#   - A drifted ASM name or key set breaks the ExternalSecret or leaves an
#     env var unset at runtime (same failure, one hop earlier).
#   - deletionPolicy must stay Retain (#231: a briefly-absent source must
#     not erase the running StatefulSet's last-known-good inputs).
#
# The realm's own mapper syntax (${CLAIM.email}) is exempt: only
# KC_-prefixed placeholders are part of the env contract (unset
# placeholders pass through import verbatim — the mechanisms coexist).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq
require_tool jq

ROOT="$HERE/../.."
TF="$ROOT/terraform/base/cognito.tf"
ES="$ROOT/platform-services/keycloak/spoke/keycloak-cognito-idp-externalsecret.yaml"
APP="$ROOT/argocd/apps/spoke/keycloak.yaml"
CM="$ROOT/platform-services/keycloak/spoke/realm-platform-configmap.yaml"

for f in "$TF" "$ES" "$APP" "$CM"; do
  [ -f "$f" ] || { fail "contract file present" "$f missing"; summary; }
done
pass "all four contract files present"

ASM_NAME="k8-platform/base/cognito"

# ---- terraform leg -------------------------------------------------------
grep -q "name  *= \"$ASM_NAME\"" "$TF" \
  && pass "terraform provisions ASM $ASM_NAME" \
  || fail "terraform ASM name" "aws_secretsmanager_secret name != $ASM_NAME in $TF"

# The 8 JSON keys terraform writes (the secret_string jsonencode map).
tf_keys="client_id client_secret issuer_url authorization_url token_url user_info_url logout_url jwks_url"
for k in $tf_keys; do
  grep -qE "^\s+${k}\s+=" "$TF" \
    && pass "terraform writes key $k" \
    || fail "terraform key $k" "not found in $TF secret_string"
done

# ---- ExternalSecret leg --------------------------------------------------
es_key="$(yq -r '.spec.dataFrom[0].extract.key' "$ES")"
[ "$es_key" = "$ASM_NAME" ] \
  && pass "ExternalSecret extracts $ASM_NAME" \
  || fail "ExternalSecret remoteRef" "extract.key='$es_key', want $ASM_NAME"

[ "$(yq -r '.spec.target.deletionPolicy' "$ES")" = "Retain" ] \
  && pass "ExternalSecret deletionPolicy Retain (#231)" \
  || fail "ExternalSecret deletionPolicy" "must be Retain"

[ "$(yq -r '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$ES")" = "-1" ] \
  && pass "ExternalSecret rides wave -1" \
  || fail "ExternalSecret sync-wave" "must be \"-1\" (before the StatefulSet's wave)"

es_target="$(yq -r '.spec.target.name' "$ES")"

# ---- ApplicationSet env leg ---------------------------------------------
# Every KC_COGNITO_* env entry must be a secretKeyRef at the ES target
# Secret, key ∈ the terraform key set, and NOT optional.
mapfile -t env_entries < <(yq -o=json -r '
  .spec.template.spec.sources[]? | select(.chart != null)
  | .helm.valuesObject.extraEnvVars[]? | select(.name | test("^KC_COGNITO_"))
  | [.name, (.valueFrom.secretKeyRef.name // "MISSING"),
     (.valueFrom.secretKeyRef.key // "MISSING"),
     (.valueFrom.secretKeyRef.optional // "unset")] | join("|")' "$APP")

[ "${#env_entries[@]}" -gt 0 ] \
  && pass "ApplicationSet defines KC_COGNITO_* env entries (${#env_entries[@]})" \
  || fail "ApplicationSet env entries" "no KC_COGNITO_* extraEnvVars found"

declare -A env_names=()
for e in "${env_entries[@]}"; do
  IFS='|' read -r n sref skey sopt <<<"$e"
  env_names["$n"]=1
  [ "$sref" = "$es_target" ] \
    && pass "$n reads Secret $es_target" \
    || fail "$n secret name" "secretKeyRef.name='$sref', want $es_target"
  echo "$tf_keys" | grep -qw "$skey" \
    && pass "$n key '$skey' is terraform-written" \
    || fail "$n key" "'$skey' not in terraform key set"
  [ "$sopt" = "unset" ] || [ "$sopt" = "false" ] \
    && pass "$n secretKeyRef is non-optional (fail-closed)" \
    || fail "$n optional" "optional=$sopt — the pod must NOT start without the Secret"
done

# ---- realm placeholder leg ----------------------------------------------
json="$(yq -r '.data["platform-realm.json"]' "$CM")"
mapfile -t placeholders < <(printf '%s' "$json" | grep -oE '\$\{KC_[A-Z_]+\}' | sort -u)

[ "${#placeholders[@]}" -gt 0 ] \
  && pass "realm JSON uses KC_ env placeholders (${#placeholders[@]})" \
  || fail "realm placeholders" "no \${KC_*} placeholders found — broker block absent?"

for p in "${placeholders[@]}"; do
  v="${p#\$\{}"; v="${v%\}}"
  [ -n "${env_names[$v]:-}" ] \
    && pass "realm placeholder $v has a matching env entry" \
    || fail "realm placeholder $v" "no extraEnvVars entry defines it — unresolved literal fails import-time validation (#233 class)"
done

# The broker + mappers must actually be present (ABSENT-or-real: real now).
printf '%s' "$json" | jq -e '.identityProviders[]? | select(.alias == "cognito")' >/dev/null \
  && pass "identityProviders alias=cognito present" \
  || fail "identityProviders" "cognito broker block missing"

printf '%s' "$json" | jq -e '.identityProviderMappers[]? | select(.config.claim == "cognito:groups" and .config["user.attribute"] == "groups")' >/dev/null \
  && pass "cognito:groups → groups mapper present (REQ-AUTH-08)" \
  || fail "groups mapper" "cognito:groups → groups attribute importer missing"

printf '%s' "$json" | jq -e '.identityProviderMappers[]? | select(.identityProviderMapper == "oidc-username-idp-mapper")' >/dev/null \
  && pass "username template mapper present" \
  || fail "username mapper" "oidc-username-idp-mapper missing — brokered usernames would fall back to opaque ids"

# syncMode FORCE on provider + groups mapper (the revocation bound the
# identity-mapping reference documents).
printf '%s' "$json" | jq -e '.identityProviders[]? | select(.alias == "cognito") | select(.config.syncMode == "FORCE")' >/dev/null \
  && pass "broker syncMode FORCE" \
  || fail "broker syncMode" "must be FORCE — group changes must re-copy each login"

printf '%s' "$json" | jq -e '.identityProviderMappers[]? | select(.name == "cognito-groups") | select(.config.syncMode == "FORCE")' >/dev/null \
  && pass "groups mapper syncMode FORCE" \
  || fail "groups mapper syncMode" "must be FORCE"

summary
