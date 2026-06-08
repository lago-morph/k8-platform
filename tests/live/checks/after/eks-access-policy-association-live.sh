#!/usr/bin/env bash
# LIVE behavioral check (after tier) -- a Crossplane-provisioned EKS
# AccessPolicyAssociation exists and is healthy.
#
# This is the BEHAVIORAL oracle for
# eks.aws.m.upbound.io/AccessPolicyAssociation per ADR-0006. AWS does NOT
# stamp tags onto policy associations, so selection is indirect: locate the
# crossplane EKS cluster (tagged crossplane-kind=cluster.eks.aws.m.upbound.io)
# and its crossplane-tagged AccessEntry (tagged
# crossplane-kind=accessentry.eks.aws.m.upbound.io or
# PlatformAbstraction=PlatformCluster); then assert that at least one access
# policy is associated to that principal. The crossplane "stamp" is that both
# the cluster AND the access entry are crossplane-tagged -- a Terraform-only
# entry would not appear under a crossplane-tagged parent.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only (describe/list only) -- safe
# in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="eks.aws.m.upbound.io/AccessPolicyAssociation"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (EKS AccessPolicyAssociation live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for the Crossplane PlatformCluster EKS cluster (region $REGION)"

# Step 1: find the crossplane EKS cluster by composition stamp.
CLUSTERS_JSON="$(aws eks list-clusters --region "$REGION" \
  --query 'clusters' --output json 2>/dev/null)" \
  || skip "eks:ListClusters not permitted / unavailable here"

COUNT="$(printf '%s' "$CLUSTERS_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no EKS clusters in the account (PlatformCluster path not provisioned)"

crossplane_cluster=""
while IFS= read -r cluster_name; do
  [ -z "$cluster_name" ] && continue
  cluster_arn="$(aws eks describe-cluster --name "$cluster_name" --region "$REGION" \
    --query 'cluster.arn' --output text 2>/dev/null)" || continue
  tags_json="$(aws eks list-tags-for-resource \
    --resource-arn "$cluster_arn" \
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

log "found crossplane EKS cluster: $crossplane_cluster -- finding crossplane-tagged access entry"

# Step 2: find the crossplane-tagged AccessEntry's principal ARN on that cluster.
ENTRIES_JSON="$(aws eks list-access-entries --cluster-name "$crossplane_cluster" \
  --region "$REGION" --query 'accessEntries' --output json 2>/dev/null)" \
  || skip "eks:ListAccessEntries not permitted / unavailable here"

ENTRY_COUNT="$(printf '%s' "$ENTRIES_JSON" | jq 'length')"
[ "${ENTRY_COUNT:-0}" -gt 0 ] \
  || skip "no access entries on cluster $crossplane_cluster (AccessEntry / AccessPolicyAssociation not provisioned)"

crossplane_principal=""
while IFS= read -r principal_arn; do
  [ -z "$principal_arn" ] && continue
  desc_json="$(aws eks describe-access-entry \
    --cluster-name "$crossplane_cluster" \
    --principal-arn "$principal_arn" \
    --region "$REGION" --output json 2>/dev/null)" || continue
  is_crossplane="$(printf '%s' "$desc_json" | jq -r '
    (.accessEntry.tags // {}) as $t
    | if (($t["crossplane-kind"] == "accessentry.eks.aws.m.upbound.io")
          or ($t["PlatformAbstraction"] == "PlatformCluster")) then "yes" else "no" end')"
  if [ "$is_crossplane" = "yes" ]; then
    crossplane_principal="$principal_arn"
    break
  fi
done <<EOF
$(printf '%s' "$ENTRIES_JSON" | jq -r '.[]')
EOF

if [ -z "$crossplane_principal" ]; then
  skip "no access entry on cluster $crossplane_cluster tagged crossplane-kind=accessentry.eks.aws.m.upbound.io (AccessPolicyAssociation parent not found -- not provisioned)"
fi

log "found crossplane AccessEntry principal: $crossplane_principal -- listing associated access policies"

# Step 3: assert at least one policy is associated to this principal.
# AccessPolicyAssociation has no tags; indirect selection via the crossplane-
# stamped cluster + access entry is the only available path.
POLICIES_JSON="$(aws eks list-associated-access-policies \
  --cluster-name "$crossplane_cluster" \
  --principal-arn "$crossplane_principal" \
  --region "$REGION" --output json 2>/dev/null)" \
  || skip "eks:ListAssociatedAccessPolicies not permitted / unavailable here"

POLICY_COUNT="$(printf '%s' "$POLICIES_JSON" | jq '.associatedAccessPolicies | length')"
if [ "${POLICY_COUNT:-0}" -lt 1 ]; then
  ng "crossplane AccessEntry principal '$crossplane_principal' on cluster '$crossplane_cluster' has no associated access policies"
  exit 1
fi

# Report the first policy ARN for observability.
first_policy="$(printf '%s' "$POLICIES_JSON" | jq -r '.associatedAccessPolicies[0].policyArn // "unknown"')"
ok "crossplane AccessPolicyAssociation verified: $POLICY_COUNT policy/policies associated to '$crossplane_principal' on cluster '$crossplane_cluster' (first: $first_policy)"
covers "$KIND"
exit "$LIVE_RC_PASS"
