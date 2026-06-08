#!/usr/bin/env bash
# LIVE behavioral check (after tier) -- a Crossplane-provisioned EKS node group
# is real and healthy.
#
# This is the BEHAVIORAL oracle for eks.aws.m.upbound.io/NodeGroup per ADR-0006:
# it proves the PlatformCluster abstraction actually produced a healthy node
# group, not that a manifest says so. It first identifies the crossplane EKS
# cluster by the Composition's own tag (crossplane-kind=cluster.eks.aws.m.upbound.io,
# ManagedBy != terraform), then iterates that cluster's node groups and selects
# the one tagged crossplane-kind=nodegroup.eks.aws.m.upbound.io.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only (describe/list only) -- safe in
# `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="eks.aws.m.upbound.io/NodeGroup"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (EKS nodegroup live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for a Crossplane PlatformCluster-provisioned EKS node group (region $REGION)"

# Step 1: find the crossplane-stamped EKS cluster (same logic as eks-cluster-live.sh).
CLUSTERS_JSON="$(aws eks list-clusters --region "$REGION" \
  --query 'clusters' --output json 2>/dev/null)" \
  || skip "eks:ListClusters not permitted / unavailable here"

COUNT="$(printf '%s' "$CLUSTERS_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no EKS clusters in the account (PlatformCluster path not provisioned)"

crossplane_cluster=""
while IFS= read -r cluster_name; do
  [ -z "$cluster_name" ] && continue
  desc="$(aws eks describe-cluster --region "$REGION" --name "$cluster_name" \
            --query 'cluster.{status:status,tags:tags}' --output json 2>/dev/null)" || continue
  crossplane_kind="$(printf '%s' "$desc" | jq -r '.tags["crossplane-kind"] // empty')"
  managed_by="$(printf '%s' "$desc" | jq -r '.tags["ManagedBy"] // empty')"
  if [ "$crossplane_kind" = "cluster.eks.aws.m.upbound.io" ] && [ "$managed_by" != "terraform" ]; then
    crossplane_cluster="$cluster_name"
    break
  fi
done <<EOF
$(printf '%s' "$CLUSTERS_JSON" | jq -r '.[]')
EOF

if [ -z "$crossplane_cluster" ]; then
  skip "no EKS cluster tagged crossplane-kind=cluster.eks.aws.m.upbound.io (parent cluster not provisioned)"
fi

log "found crossplane EKS cluster '$crossplane_cluster'; now scanning its node groups"

# Step 2: list node groups on the crossplane cluster.
NODEGROUPS_JSON="$(aws eks list-nodegroups --region "$REGION" --cluster-name "$crossplane_cluster" \
  --query 'nodegroups' --output json 2>/dev/null)" \
  || skip "eks:ListNodegroups not permitted / unavailable here"

NG_COUNT="$(printf '%s' "$NODEGROUPS_JSON" | jq 'length')"
[ "${NG_COUNT:-0}" -gt 0 ] || skip "no node groups on cluster '$crossplane_cluster' (NodeGroup path not provisioned)"

# Step 3: find the node group stamped by the Composition.
found_ng=""; found_ng_status=""
while IFS= read -r ng_name; do
  [ -z "$ng_name" ] && continue
  ng_desc="$(aws eks describe-nodegroup --region "$REGION" \
               --cluster-name "$crossplane_cluster" --nodegroup-name "$ng_name" \
               --query 'nodegroup.{status:status,tags:tags}' --output json 2>/dev/null)" || continue
  ng_kind="$(printf '%s' "$ng_desc" | jq -r '.tags["crossplane-kind"] // empty')"
  if [ "$ng_kind" = "nodegroup.eks.aws.m.upbound.io" ]; then
    found_ng="$ng_name"
    found_ng_status="$(printf '%s' "$ng_desc" | jq -r '.status')"
    break
  fi
done <<EOF
$(printf '%s' "$NODEGROUPS_JSON" | jq -r '.[]')
EOF

if [ -z "$found_ng" ]; then
  skip "no node group tagged crossplane-kind=nodegroup.eks.aws.m.upbound.io on cluster '$crossplane_cluster' (NodeGroup abstraction has not provisioned one)"
fi

if [ "$found_ng_status" != "ACTIVE" ]; then
  ng "PlatformCluster EKS node group '$found_ng' on '$crossplane_cluster' is '$found_ng_status', not ACTIVE"
  exit 1
fi

ok "PlatformCluster-provisioned EKS node group '$found_ng' on '$crossplane_cluster' is ACTIVE"
covers "$KIND"
exit "$LIVE_RC_PASS"
