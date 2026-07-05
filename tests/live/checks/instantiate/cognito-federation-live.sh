#!/usr/bin/env bash
# LIVE behavioral check (instantiate tier) — the FULL identity federation
# path (REQ-AUTH-02/07/08/09/10; the phase-5 e2e oracle):
#
#   Cognito directory login (hosted UI, headless)
#     → Keycloak broker (alias cognito, kc_idp_hint short-circuit)
#     → authorization code + PKCE on the public `kubernetes` client
#     → ID token claims: preferred_username = the directory email,
#       groups ∋ k8s-viewers  (REQ-AUTH-02/08)
#     → kubectl with that token against the spoke API server:
#       SelfSubjectReview reports kc:<email> + kc:k8s-viewers
#       (REQ-AUTH-07 IdP config + REQ-AUTH-09 bindings + REQ-AUTH-10 flow)
#
# FIXTURE LIFECYCLE (why instantiate tier): the check creates its own
# throwaway DIRECTORY user (oracle-<RUN_ID>@…, permanent password, member
# of k8s-viewers, given/family names set so the first-broker-login review
# form stays quiet), runs the flow, and deletes the user in a trap. The
# only mutation is to the user directory — state that is BY DESIGN managed
# outside the platform (REQ-AUTH-03/08: no users or groups exist in
# Keycloak or the clusters); the oracle simulates the human enrollment
# step, then verifies the PLATFORM read-only. It does NOT depend on the
# CI-created ci-test user (whose password is minted fresh per terraform
# apply and unknowable here). Runs ONLY in LIVE_MODE=mutating — the CI
# producer invokes run.sh readonly, so its recorded evidence comes from
# sandbox evidence passes (like the relay-coupled e2e oracles). The
# hosted-UI form mechanics were live-verified standalone on build #5
# (2026-07-05): fixture user → login page → credential POST → 302 to the
# broker callback with an authorization code.
#
# PRECONDITIONS (loud SKIPs, not failures — each names the build state
# that makes the path not-yet-exercisable):
#   - Keycloak discovery serving on auth.platform.<domain>
#   - the realm advertises the cognito broker (a realm imported before the
#     phase-5 broker block CANNOT re-import on a live DB — IGNORE_EXISTING;
#     first exercisable on a from-scratch build)
#   - ASM k8-platform/base/cognito present (the terraform bridge)
#   - the k8s-viewers group exists in the pool
#   - the EKS IdentityProviderConfig `keycloak` is ACTIVE on the spoke
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Mutating ONLY within the test-owned fixture user.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
CONFIG_NAME="keycloak"
GROUP="k8s-viewers"
HELPER="$REPO_ROOT/scripts/sandbox-kubeconfig.sh"
CURL_MAX="${FEDERATION_CURL_MAX_TIME:-15}"

# ── Mode gate: the fixture user write requires mutating mode ─────────────
[ "$(live_mode)" = "mutating" ] \
  || skip "LIVE_MODE=readonly — the directory-fixture flow only runs in mutating mode (sandbox evidence passes)"

# ── Tooling / credential preconditions ────────────────────────────────────
for bin in aws jq curl python3 kubectl; do
  command -v "$bin" >/dev/null 2>&1 \
    || skip "$bin not on PATH (federation live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 \
  || skip "no usable AWS credentials in this environment"

# ── Derive the public domain (live, never hardcoded) ─────────────────────
ZONES_JSON="$(aws route53 list-hosted-zones --output json 2>/dev/null)" \
  || skip "route53:ListHostedZones not permitted / unavailable here"
DOMAIN="$(printf '%s' "$ZONES_JSON" | jq -r '
  .HostedZones[] | select(.Config.PrivateZone == false) | .Name' | head -1)"
DOMAIN="${DOMAIN%.}"
[ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ] \
  || skip "no public hosted zone in this account (federation precondition not met)"

HOST="auth.platform.${DOMAIN}"
ISSUER="https://${HOST}/realms/platform"
log "issuer under test: $ISSUER"

# ── Keycloak discovery + broker advertisement ─────────────────────────────
DISC="$(curl -sSf --max-time "$CURL_MAX" "$ISSUER/.well-known/openid-configuration" 2>/dev/null)" \
  || skip "Keycloak discovery not serving at $ISSUER (app stack not converged yet?)"
AUTH_EP="$(printf '%s' "$DISC" | jq -r '.authorization_endpoint // empty')"
TOKEN_EP="$(printf '%s' "$DISC" | jq -r '.token_endpoint // empty')"
[ -n "$AUTH_EP" ] && [ -n "$TOKEN_EP" ] || skip "discovery document lacks endpoints (unexpected shape)"

# ── The committed Cognito bridge (terraform/base → ASM) ───────────────────
ASM_DOC="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "k8-platform/base/cognito" \
  --query SecretString --output text 2>/dev/null)" \
  || skip "ASM k8-platform/base/cognito absent (terraform Cognito bridge not applied — pre-phase-5 base?)"
POOL_ISSUER="$(printf '%s' "$ASM_DOC" | jq -r '.issuer_url // empty')"
POOL_ID="${POOL_ISSUER##*/}"
[ -n "$POOL_ID" ] || skip "cognito bridge document lacks issuer_url (unexpected shape)"

aws cognito-idp get-group --group-name "$GROUP" --user-pool-id "$POOL_ID" \
  --region "$REGION" >/dev/null 2>&1 \
  || skip "group $GROUP absent in pool $POOL_ID (pre-phase-5 base — groups ship with the Cognito bridge)"

# ── The realm must actually offer the broker ──────────────────────────────
# (A live realm imported before the broker block stays broker-less until a
# from-scratch build re-imports it — IGNORE_EXISTING; see the realm CM.)
PKCE_VERIFIER="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
PKCE_CHALLENGE="$(printf '%s' "$PKCE_VERIFIER" | python3 -c 'import sys,hashlib,base64; print(base64.urlsafe_b64encode(hashlib.sha256(sys.stdin.buffer.read()).digest()).rstrip(b"=").decode())')"
STATE="$(python3 -c 'import secrets; print(secrets.token_urlsafe(16))')"
REDIRECT_URI="http://localhost:8000"

WORK="$(mktemp -d)"
KC_JAR="$WORK/kc.jar"; COG_JAR="$WORK/cog.jar"
FIXTURE_EMAIL=""
cleanup() {
  [ -n "$FIXTURE_EMAIL" ] && aws cognito-idp admin-delete-user \
    --user-pool-id "$POOL_ID" --username "$FIXTURE_EMAIL" \
    --region "$REGION" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

AUTH_URL="${AUTH_EP}?client_id=kubernetes&response_type=code&scope=openid%20profile&redirect_uri=${REDIRECT_URI}&state=${STATE}&code_challenge=${PKCE_CHALLENGE}&code_challenge_method=S256&kc_idp_hint=cognito"

# First hop: Keycloak should 302 us straight to the Cognito hosted UI
# (kc_idp_hint). A 200 login page instead means the broker is not in the
# live realm.
HOP1_HEADERS="$WORK/hop1.h"
curl -sS --max-time "$CURL_MAX" -c "$KC_JAR" -D "$HOP1_HEADERS" -o "$WORK/hop1.html" "$AUTH_URL" \
  || skip "authorization endpoint unreachable ($AUTH_EP)"
COG_AUTHORIZE="$(awk 'tolower($1)=="location:" {print $2}' "$HOP1_HEADERS" | tr -d '\r' | head -1)"
case "$COG_AUTHORIZE" in
  *amazoncognito.com/oauth2/authorize*|*amazoncognito.com/authorize*) ;;
  *)
    skip "realm does not broker to Cognito yet (no kc_idp_hint redirect — realm imported before the phase-5 broker block; first exercisable on a from-scratch build)"
    ;;
esac

# ── The spoke IdentityProviderConfig must be ACTIVE ───────────────────────
CLUSTERS_JSON="$(aws eks list-clusters --region "$REGION" --query 'clusters' --output json 2>/dev/null)" \
  || skip "eks:ListClusters not permitted / unavailable here"
crossplane_cluster=""
while IFS= read -r cluster_name; do
  [ -z "$cluster_name" ] && continue
  arn="$(aws eks describe-cluster --name "$cluster_name" --region "$REGION" --query 'cluster.arn' --output text 2>/dev/null)" || continue
  tag="$(aws eks list-tags-for-resource --resource-arn "$arn" --region "$REGION" --output json 2>/dev/null \
    | jq -r '.tags["crossplane-kind"] // ""')"
  [ "$tag" = "cluster.eks.aws.m.upbound.io" ] && { crossplane_cluster="$cluster_name"; break; }
done <<EOF
$(printf '%s' "$CLUSTERS_JSON" | jq -r '.[]')
EOF
[ -n "$crossplane_cluster" ] \
  || skip "no crossplane-tagged EKS cluster (PlatformCluster not provisioned)"

IDP_STATUS="$(aws eks describe-identity-provider-config \
  --cluster-name "$crossplane_cluster" --region "$REGION" \
  --identity-provider-config "type=oidc,name=$CONFIG_NAME" \
  --query 'identityProviderConfig.oidc.status' --output text 2>/dev/null || echo ABSENT)"
[ "$IDP_STATUS" = "ACTIVE" ] \
  || skip "identity provider config '$CONFIG_NAME' on $crossplane_cluster is ${IDP_STATUS} (kubectl federation not live yet — ACTIVE arrives once the association validates the issuer)"

# ── Fixture user (create → flow → trap-deleted) ───────────────────────────
FIXTURE_EMAIL="oracle-${RUN_ID:-$$}@federation-oracle.invalid"
FIXTURE_PW="Oracle$(python3 -c 'import secrets; print(secrets.token_hex(8))')A1"
log "creating fixture user $FIXTURE_EMAIL in pool $POOL_ID (group $GROUP)"

aws cognito-idp admin-create-user --user-pool-id "$POOL_ID" \
  --username "$FIXTURE_EMAIL" --message-action SUPPRESS \
  --user-attributes Name=email,Value="$FIXTURE_EMAIL" Name=email_verified,Value=true \
                    Name=given_name,Value=Federation Name=family_name,Value=Oracle \
  --region "$REGION" >/dev/null 2>&1 \
  || { ng "admin-create-user failed (fixture)"; exit 1; }
aws cognito-idp admin-set-user-password --user-pool-id "$POOL_ID" \
  --username "$FIXTURE_EMAIL" --password "$FIXTURE_PW" --permanent \
  --region "$REGION" >/dev/null 2>&1 \
  || { ng "admin-set-user-password failed (fixture)"; exit 1; }
aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL_ID" \
  --username "$FIXTURE_EMAIL" --group-name "$GROUP" \
  --region "$REGION" >/dev/null 2>&1 \
  || { ng "admin-add-user-to-group failed (fixture)"; exit 1; }

# ── Cognito hosted-UI login (headless form dance) ─────────────────────────
# GET the login page (cookie jar picks up XSRF-TOKEN), then POST the form.
COG_BASE="${COG_AUTHORIZE%%/oauth2/authorize*}"; COG_BASE="${COG_BASE%%/authorize*}"
LOGIN_HEADERS="$WORK/login-get.h"
LOGIN_URL="$(curl -sS --max-time "$CURL_MAX" -c "$COG_JAR" -D "$LOGIN_HEADERS" -o "$WORK/login.html" -w '%{url_effective}' -L --max-redirs 4 "$COG_AUTHORIZE")" \
  || { ng "cognito authorize endpoint unreachable"; exit 1; }
case "$LOGIN_URL" in
  */login*) ;;
  *) ng "cognito authorize did not land on the hosted-UI login page (got $LOGIN_URL)"; exit 1 ;;
esac

CSRF="$(awk '$6=="XSRF-TOKEN" {print $7}' "$COG_JAR" | tail -1)"
[ -n "$CSRF" ] || { ng "no XSRF-TOKEN cookie from the hosted UI"; exit 1; }

POST_HEADERS="$WORK/login-post.h"
curl -sS --max-time "$CURL_MAX" -b "$COG_JAR" -c "$COG_JAR" -D "$POST_HEADERS" -o "$WORK/login-post.html" \
  --data-urlencode "_csrf=$CSRF" \
  --data-urlencode "username=$FIXTURE_EMAIL" \
  --data-urlencode "password=$FIXTURE_PW" \
  "$LOGIN_URL" \
  || { ng "hosted-UI credential POST failed"; exit 1; }
BROKER_CB="$(awk 'tolower($1)=="location:" {print $2}' "$POST_HEADERS" | tr -d '\r' | head -1)"
case "$BROKER_CB" in
  https://${HOST}/realms/platform/broker/cognito/endpoint*) ;;
  *)
    ng "hosted-UI login did not redirect to the Keycloak broker callback"
    ng "  got Location: ${BROKER_CB:-<none>} (wrong credentials, changed hosted-UI form, or misconfigured client callback)"
    exit 1
    ;;
esac

# ── Keycloak completes the brokered login ─────────────────────────────────
# Follow hops within the issuer host; the terminal hop is the 302 to
# http://localhost:8000?code=... (never followed — nothing listens there).
# One first-broker-login review form is tolerated and submitted if shown.
NEXT="$BROKER_CB"
KC_CODE=""
for _hop in 1 2 3 4 5 6; do
  H="$WORK/kc-hop.h"
  curl -sS --max-time "$CURL_MAX" -b "$KC_JAR" -c "$KC_JAR" -D "$H" -o "$WORK/kc-hop.html" "$NEXT" \
    || { ng "keycloak broker hop failed ($NEXT)"; exit 1; }
  LOC="$(awk 'tolower($1)=="location:" {print $2}' "$H" | tr -d '\r' | head -1)"
  if [ -n "$LOC" ]; then
    case "$LOC" in
      ${REDIRECT_URI}*)
        KC_CODE="$(printf '%s' "$LOC" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
        break
        ;;
      https://${HOST}/*) NEXT="$LOC"; continue ;;
      *) ng "unexpected broker redirect off-host: $LOC"; exit 1 ;;
    esac
  fi
  # 200 page: the first-broker-login review form. Submit it once.
  FORM_ACTION="$(sed -n 's/.*<form[^>]*action="\([^"]*\)".*/\1/p' "$WORK/kc-hop.html" | head -1)"
  [ -n "$FORM_ACTION" ] || { ng "broker flow returned a page with no form and no redirect (hop $_hop)"; exit 1; }
  case "$FORM_ACTION" in
    /*) FORM_ACTION="https://${HOST}${FORM_ACTION}" ;;
  esac
  FORM_ACTION="$(printf '%s' "$FORM_ACTION" | sed 's/\&amp;/\&/g')"
  curl -sS --max-time "$CURL_MAX" -b "$KC_JAR" -c "$KC_JAR" -D "$H" -o "$WORK/kc-hop.html" \
    --data-urlencode "email=$FIXTURE_EMAIL" \
    --data-urlencode "firstName=Federation" \
    --data-urlencode "lastName=Oracle" \
    "$FORM_ACTION" \
    || { ng "first-broker-login form POST failed"; exit 1; }
  LOC="$(awk 'tolower($1)=="location:" {print $2}' "$H" | tr -d '\r' | head -1)"
  [ -n "$LOC" ] && NEXT="$LOC" || { ng "first-broker-login form did not redirect"; exit 1; }
  case "$NEXT" in
    ${REDIRECT_URI}*)
      KC_CODE="$(printf '%s' "$NEXT" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
      break
      ;;
  esac
done
[ -n "$KC_CODE" ] || { ng "no authorization code after the broker flow (bounded hops exhausted)"; exit 1; }
ok "brokered login issued an authorization code (Cognito → Keycloak leg live)"

# ── Token exchange (PKCE, public client) ──────────────────────────────────
TOKENS="$(curl -sS --max-time "$CURL_MAX" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "client_id=kubernetes" \
  --data-urlencode "code=$KC_CODE" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" \
  --data-urlencode "code_verifier=$PKCE_VERIFIER" \
  "$TOKEN_EP")" \
  || { ng "token exchange failed"; exit 1; }
ID_TOKEN="$(printf '%s' "$TOKENS" | jq -r '.id_token // empty')"
[ -n "$ID_TOKEN" ] || { ng "token response lacks id_token: $(printf '%s' "$TOKENS" | jq -c 'del(.access_token, .refresh_token)' 2>/dev/null)"; exit 1; }

# ── ID-token claim assertions (REQ-AUTH-02/08) ────────────────────────────
CLAIMS="$(printf '%s' "$ID_TOKEN" | cut -d. -f2 | python3 -c 'import sys,base64,json; p=sys.stdin.read().strip(); p+="="*(-len(p)%4); print(json.dumps(json.loads(base64.urlsafe_b64decode(p))))')" \
  || { ng "could not decode the id_token payload"; exit 1; }
P_USER="$(printf '%s' "$CLAIMS" | jq -r '.preferred_username // ""')"
HAS_GROUP="$(printf '%s' "$CLAIMS" | jq -r --arg g "$GROUP" '(.groups // []) | if type == "array" then any(. == $g) else . == $g end')"

[ "$P_USER" = "$FIXTURE_EMAIL" ] \
  || { ng "preferred_username '$P_USER' != fixture email '$FIXTURE_EMAIL' (username template mapper broken)"; exit 1; }
[ "$HAS_GROUP" = "true" ] \
  || { ng "groups claim lacks $GROUP: $(printf '%s' "$CLAIMS" | jq -c '.groups // null') (cognito:groups mapper broken)"; exit 1; }
ok "id_token claims correct: preferred_username=$P_USER, groups ∋ $GROUP"

# ── kubectl with the federated token (REQ-AUTH-07/09/10) ──────────────────
EP="$(aws eks describe-cluster --name "$crossplane_cluster" --region "$REGION" --query 'cluster.endpoint' --output text 2>/dev/null)"
CA_FILE="$WORK/ca.pem"
aws eks describe-cluster --name "$crossplane_cluster" --region "$REGION" \
  --query 'cluster.certificateAuthority.data' --output text 2>/dev/null | base64 -d > "$CA_FILE"

WHOAMI=""
if WHOAMI="$(kubectl --server "$EP" --certificate-authority "$CA_FILE" \
      --token "$ID_TOKEN" auth whoami -o json 2>"$WORK/whoami.err")"; then
  :
elif [ -x "$HELPER" ] && command -v session-manager-plugin >/dev/null 2>&1; then
  # Sandbox path: the egress gateway 503s the private-CA API endpoint —
  # ride the SSM relay (transparent TCP; the real CA verifies end-to-end).
  log "direct API unreachable ($(head -c 120 "$WORK/whoami.err" 2>/dev/null)…) — retrying via the SSM relay"
  WHOAMI="$("$HELPER" -c "$crossplane_cluster" --exec kubectl --token "$ID_TOKEN" auth whoami -o json 2>/dev/null | sed -n '/^{/,$p' | sed '/^stopped tunnel/d')" \
    || { ng "kubectl with the federated token failed through the relay too"; exit 1; }
else
  ng "kubectl with the federated token failed: $(head -c 200 "$WORK/whoami.err" 2>/dev/null)"
  exit 1
fi

K_USER="$(printf '%s' "$WHOAMI" | jq -r '.status.userInfo.username // ""')"
K_GROUPS="$(printf '%s' "$WHOAMI" | jq -c '.status.userInfo.groups // []')"
[ "$K_USER" = "kc:${FIXTURE_EMAIL}" ] \
  || { ng "API server username '$K_USER' != 'kc:${FIXTURE_EMAIL}' (usernameClaim/prefix drift)"; exit 1; }
printf '%s' "$K_GROUPS" | jq -e --arg g "kc:${GROUP}" 'any(. == $g)' >/dev/null \
  || { ng "API server groups $K_GROUPS lack kc:${GROUP} (groupsClaim/prefix drift)"; exit 1; }

ok "kubectl federated identity live: username=$K_USER groups∋kc:${GROUP} on $crossplane_cluster"
covers "platform.federation/e2e"
exit "$LIVE_RC_PASS"
