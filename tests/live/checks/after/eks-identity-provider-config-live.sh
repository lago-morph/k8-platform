#!/usr/bin/env bash
# LIVE behavioral check (after tier) — the Crossplane-composed EKS OIDC
# IdentityProviderConfig exists, is ACTIVE, and points at the cluster's own
# Keycloak realm (REQ-AUTH-07; SUBSTRATE row 11's per-cluster half).
#
# This is the behavioral oracle for eks.aws.m.upbound.io/IdentityProviderConfig
# per ADR-0006: it proves the PlatformCluster abstraction actually associated
# the OIDC provider on the real cluster — an association only reaches ACTIVE
# after the EKS control plane fetches the issuer's discovery document, so
# ACTIVE additionally implies the Keycloak realm is publicly served with a
# valid chain. Assertions:
#   1. The crossplane-tagged EKS cluster has an identity provider config
#      named `keycloak` (the Composition's external-name).
#   2. Its status is ACTIVE (CREATING → skip with a loud note: the fresh-build
#      association retries until Keycloak boots; FAILED → hard FAIL).
#   3. The oidc block carries the contract claims: clientId=kubernetes,
#      usernameClaim=preferred_username, groupsClaim=groups, both prefixes
#      `kc:` — the values the kc-* ClusterRoleBindings depend on.
#   4. issuerUrl is https://auth.<...>/realms/platform (shape, not the
#      account-ephemeral domain).
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (list/describe only) — safe in full + verify-only.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="eks.aws.m.upbound.io/IdentityProviderConfig"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
CONFIG_NAME="keycloak"   # the Composition's crossplane.io/external-name

for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (IdentityProviderConfig live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for the Crossplane PlatformCluster EKS cluster (region $REGION)"

CLUSTERS_JSON="$(aws eks list-clusters --region "$REGION" \
  --query 'clusters' --output json 2>/dev/null)" \
  || skip "eks:ListClusters not permitted / unavailable here"

COUNT="$(printf '%s' "$CLUSTERS_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no EKS clusters in the account (PlatformCluster path not provisioned)"

crossplane_cluster=""
while IFS= read -r cluster_name; do
  [ -z "$cluster_name" ] && continue
  tags_json="$(aws eks list-tags-for-resource \
    --resource-arn "$(aws eks describe-cluster --name "$cluster_name" --region "$REGION" \
      --query 'cluster.arn' --output text 2>/dev/null)" \
    --region "$REGION" --output json 2>/dev/null)" || continue
  is_crossplane="$(printf '%s' "$tags_json" | jq -r '
    .tags as $t
    | if ($t["crossplane-kind"] == "cluster.eks.aws.m.upbound.io") then "yes" else "no" end')"
  if [ "$is_crossplane" = "yes" ]; then
    crossplane_cluster="$cluster_name"
    break
  fi
done <<EOF
$(printf '%s' "$CLUSTERS_JSON" | jq -r '.[]')
EOF

if [ -z "$crossplane_cluster" ]; then
  skip "no EKS cluster tagged crossplane-kind=cluster.eks.aws.m.upbound.io (PlatformCluster abstraction not provisioned)"
fi

log "found crossplane EKS cluster: $crossplane_cluster — listing identity provider configs"

CONFIGS_JSON="$(aws eks list-identity-provider-configs \
  --cluster-name "$crossplane_cluster" --region "$REGION" \
  --query 'identityProviderConfigs' --output json 2>/dev/null)" \
  || skip "eks:ListIdentityProviderConfigs not permitted / unavailable here"

has_config="$(printf '%s' "$CONFIGS_JSON" | jq -r --arg n "$CONFIG_NAME" \
  '[.[] | select(.type == "oidc" and .name == $n)] | length')"
[ "${has_config:-0}" -gt 0 ] \
  || skip "no oidc identity provider config named '$CONFIG_NAME' on cluster $crossplane_cluster (composed IdentityProviderConfig not provisioned — pre-phase-5 build?)"

DESC_JSON="$(aws eks describe-identity-provider-config \
  --cluster-name "$crossplane_cluster" --region "$REGION" \
  --identity-provider-config "type=oidc,name=$CONFIG_NAME" \
  --output json 2>/dev/null)" || {
  ng "describe-identity-provider-config failed for '$CONFIG_NAME' on $crossplane_cluster"
  exit 1
}

STATUS="$(printf '%s' "$DESC_JSON" | jq -r '.identityProviderConfig.oidc.status // "UNKNOWN"')"
case "$STATUS" in
  ACTIVE) ;;
  CREATING)
    skip "identity provider config '$CONFIG_NAME' is still CREATING on $crossplane_cluster — the fresh-build association retries until the Keycloak issuer serves its discovery document; re-run after the app stack converges"
    ;;
  *)
    ng "identity provider config '$CONFIG_NAME' on $crossplane_cluster is $STATUS (want ACTIVE)"
    ng "  a FAILED association usually means the issuer URL was unreachable or its discovery document invalid"
    exit 1
    ;;
esac

OIDC="$(printf '%s' "$DESC_JSON" | jq -r '.identityProviderConfig.oidc')"
client_id="$(printf '%s' "$OIDC" | jq -r '.clientId // ""')"
u_claim="$(printf '%s' "$OIDC" | jq -r '.usernameClaim // ""')"
u_prefix="$(printf '%s' "$OIDC" | jq -r '.usernamePrefix // ""')"
g_claim="$(printf '%s' "$OIDC" | jq -r '.groupsClaim // ""')"
g_prefix="$(printf '%s' "$OIDC" | jq -r '.groupsPrefix // ""')"
issuer="$(printf '%s' "$OIDC" | jq -r '.issuerUrl // ""')"

errs=""
[ "$client_id" = "kubernetes" ]          || errs="$errs clientId='$client_id'(want kubernetes);"
[ "$u_claim" = "preferred_username" ]    || errs="$errs usernameClaim='$u_claim'(want preferred_username);"
[ "$u_prefix" = "kc:" ]                  || errs="$errs usernamePrefix='$u_prefix'(want kc:);"
[ "$g_claim" = "groups" ]                || errs="$errs groupsClaim='$g_claim'(want groups);"
[ "$g_prefix" = "kc:" ]                  || errs="$errs groupsPrefix='$g_prefix'(want kc:);"
case "$issuer" in
  https://auth.*/realms/platform) ;;
  *) errs="$errs issuerUrl='$issuer'(want https://auth.<subdomain>.<domain>/realms/platform);"
esac

if [ -n "$errs" ]; then
  ng "identity provider config '$CONFIG_NAME' claim contract drifted:$errs"
  ng "  the kc-* ClusterRoleBindings bind nothing under these values"
  exit 1
fi

ok "IdentityProviderConfig '$CONFIG_NAME' on '$crossplane_cluster' ACTIVE; claims match the kc-* binding contract (issuer $issuer)"
covers "$KIND"
exit "$LIVE_RC_PASS"
