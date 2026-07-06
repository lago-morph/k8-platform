#!/usr/bin/env bash
# Pins the phase-5 OIDC IdentityProviderConfig composed into the
# platform-cluster Composition (REQ-AUTH-07) to the claim contract the
# rest of the identity chain depends on:
#
#   - the realm's protocol mappers emit preferred_username + groups
#     (platform-services/keycloak/spoke/realm-platform-configmap.yaml),
#   - the kc-* ClusterRoleBindings bind kc:-prefixed groups
#     (clusters/platform/rbac/), and
#   - the identity-mapping reference page documents exactly these values
#     (docs/site/reference/identity-mapping.md, status: contract).
#
# A drifted claim name or prefix here silently strands ALL of those: tokens
# still verify, but usernames/groups stop matching any binding. The live
# oracle (tests/live/checks/after/eks-identity-provider-config-live.sh)
# asserts the same contract against the real association; this test keeps
# the committed source from drifting before it ever reaches a cluster.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
COMP="$ROOT/crossplane/compositions/platform-cluster.yaml"
PT='.spec.pipeline[] | select(.step == "patch-and-transform") | .input'
R="${PT}.resources[] | select(.name == \"oidc-identity-provider\")"

[ -f "$COMP" ] || { fail "composition present" "$COMP missing"; summary; }

kind="$(yq -r "$R | .base.kind" "$COMP")"
[ "$kind" = "IdentityProviderConfig" ] \
  && pass "oidc-identity-provider composes an IdentityProviderConfig" \
  || fail "resource kind" "got '$kind'"

api="$(yq -r "$R | .base.apiVersion" "$COMP")"
[ "$api" = "eks.aws.m.upbound.io/v1beta1" ] \
  && pass "modern v2 CRD group (.m. infix)" \
  || fail "apiVersion" "got '$api'"

# The oidc claim contract — the values every downstream consumer assumes.
declare -A want=(
  [clientId]=kubernetes
  [usernameClaim]=preferred_username
  [usernamePrefix]="kc:"
  [groupsClaim]=groups
  [groupsPrefix]="kc:"
)
for k in "${!want[@]}"; do
  v="$(yq -r "$R | .base.spec.forProvider.oidc.${k}" "$COMP")"
  [ "$v" = "${want[$k]}" ] \
    && pass "oidc.$k = ${want[$k]}" \
    || fail "oidc.$k" "got '$v', want '${want[$k]}'"
done

# external-name = the EKS identity_provider_config_name (the provider
# injects it; the live check selects on it).
en="$(yq -r "$R | .base.metadata.annotations[\"crossplane.io/external-name\"]" "$COMP")"
[ "$en" = "keycloak" ] \
  && pass "external-name pins config name 'keycloak'" \
  || fail "external-name" "got '$en'"

# issuerUrl combines subdomain+domain from the pipeline environment into
# the SAME auth.<subdomain>.<domain> host the ACM cert covers and
# KC_HOSTNAME advertises — drift here breaks discovery for the API server.
fmt="$(yq -r "$R | .patches[] | select(.toFieldPath == \"spec.forProvider.oidc.issuerUrl\") | .combine.string.fmt" "$COMP")"
[ "$fmt" = "https://auth.%s.%s/realms/platform" ] \
  && pass "issuerUrl combine fmt matches the auth hostname + platform realm" \
  || fail "issuerUrl fmt" "got '$fmt'"

vars="$(yq -r "$R | .patches[] | select(.toFieldPath == \"spec.forProvider.oidc.issuerUrl\") | [.combine.variables[].fromFieldPath] | join(\",\")" "$COMP")"
[ "$vars" = "subdomain,domain" ] \
  && pass "issuerUrl combines [subdomain, domain] from the environment" \
  || fail "issuerUrl variables" "got '$vars'"

# clusterName rides spec.name (the same source every sibling resource uses).
cn="$(yq -r "$R | .patches[] | select(.toFieldPath == \"spec.forProvider.clusterName\") | .fromFieldPath" "$COMP")"
[ "$cn" = "spec.name" ] \
  && pass "clusterName patched from spec.name" \
  || fail "clusterName patch" "got '$cn'"

# Readiness gates on the association reaching ACTIVE — Ready must not
# claim a cluster whose declared federation is unconfigured.
rc="$(yq -r "$R | .readinessChecks[0].matchCondition.type" "$COMP")"
[ "$rc" = "Ready" ] \
  && pass "readiness gates on MatchCondition Ready" \
  || fail "readinessCheck" "got '$rc'"

summary
