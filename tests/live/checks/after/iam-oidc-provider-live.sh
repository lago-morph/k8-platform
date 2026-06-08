#!/usr/bin/env bash
# LIVE behavioral check (after tier) -- a Crossplane-provisioned IAM OIDC
# Provider is real.
#
# This is the BEHAVIORAL oracle for iam.aws.m.upbound.io/OpenIDConnectProvider
# per ADR-0006: it proves the abstraction actually produced a real OIDC
# provider, not that a manifest says so. It selects by the Composition's own
# tag (crossplane-kind=openidconnectprovider.iam.aws.m.upbound.io OR
# PlatformAbstraction=XSpokeAccess) -- a Terraform-managed OIDC provider
# (ManagedBy=terraform) does NOT count.
#
# NOTE: the only OIDC provider in this account is the Terraform mgmt-cluster
# IRSA provider (ManagedBy=terraform). A crossplane-stamped OIDC provider is
# NOT provisioned here -- a clean SKIP is the correct expected result.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (list/get only) -- safe in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="iam.aws.m.upbound.io/OpenIDConnectProvider"   # IAM is global -- no region

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (IAM OIDC Provider live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for a Crossplane-provisioned IAM OIDC Provider (crossplane-kind=openidconnectprovider.iam.aws.m.upbound.io)"

PROVIDERS_JSON="$(aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[].Arn' \
  --output json 2>/dev/null)" || skip "iam:ListOpenIDConnectProviders not permitted / unavailable here"

COUNT="$(printf '%s' "$PROVIDERS_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no IAM OIDC providers in the account (OpenIDConnectProvider path not provisioned)"

found_arn=""
while IFS= read -r provider_arn; do
  [ -z "$provider_arn" ] && continue
  tags="$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" \
            --query 'Tags' --output json 2>/dev/null)" || continue
  is_xp="$(printf '%s' "$tags" | jq -r '
    (map({(.Key): .Value}) | add // {}) as $t
    | if ($t["crossplane-kind"] == "openidconnectprovider.iam.aws.m.upbound.io"
          or $t["PlatformAbstraction"] == "XSpokeAccess")
      then "yes" else "no" end')"
  if [ "$is_xp" = "yes" ]; then
    found_arn="$provider_arn"
    break
  fi
done <<EOF
$(printf '%s' "$PROVIDERS_JSON" | jq -r '.[]')
EOF

# No crossplane-tagged OIDC provider -- the kind is unprovisioned for this
# account. The only provider present is the Terraform mgmt-cluster IRSA
# provider (ManagedBy=terraform) which is correctly excluded.
if [ -z "$found_arn" ]; then
  skip "no IAM OIDC provider tagged crossplane-kind=openidconnectprovider.iam.aws.m.upbound.io or PlatformAbstraction=XSpokeAccess (only the Terraform mgmt-cluster IRSA provider exists in this account -- OpenIDConnectProvider kind is not provisioned here)"
fi

# Health: the provider exists (it does -- we just retrieved it via tag lookup).
ok "Crossplane-provisioned IAM OIDC Provider '$found_arn' exists (crossplane-kind=openidconnectprovider.iam.aws.m.upbound.io)"
covers "$KIND"
exit "$LIVE_RC_PASS"
