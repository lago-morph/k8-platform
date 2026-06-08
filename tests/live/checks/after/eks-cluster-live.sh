#!/usr/bin/env bash
# LIVE behavioral check (after tier) -- a Crossplane-provisioned EKS cluster is
# real and healthy.
#
# This is the BEHAVIORAL oracle for eks.aws.m.upbound.io/Cluster per ADR-0006:
# it proves the PlatformCluster abstraction actually produced a healthy EKS
# cluster, not that a manifest says so. It selects by the Composition's own tag
# (crossplane-kind=cluster.eks.aws.m.upbound.io) -- a Terraform cluster (e.g.
# k8-platform-mgmt, ManagedBy=terraform) does NOT count.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only (describe/list only) -- safe in
# `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="eks.aws.m.upbound.io/Cluster"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (EKS cluster live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for a Crossplane PlatformCluster-provisioned EKS cluster (region $REGION)"

# List all EKS clusters; then describe each to inspect tags.
CLUSTERS_JSON="$(aws eks list-clusters --region "$REGION" \
  --query 'clusters' --output json 2>/dev/null)" \
  || skip "eks:ListClusters not permitted / unavailable here"

COUNT="$(printf '%s' "$CLUSTERS_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no EKS clusters in the account (PlatformCluster path not provisioned)"

found_name=""; found_status=""
while IFS= read -r cluster_name; do
  [ -z "$cluster_name" ] && continue
  desc="$(aws eks describe-cluster --region "$REGION" --name "$cluster_name" \
            --query 'cluster.{status:status,tags:tags}' --output json 2>/dev/null)" || continue
  crossplane_kind="$(printf '%s' "$desc" | jq -r '.tags["crossplane-kind"] // empty')"
  managed_by="$(printf '%s' "$desc" | jq -r '.tags["ManagedBy"] // empty')"
  # Select by crossplane stamp; exclude the Terraform mgmt cluster.
  if [ "$crossplane_kind" = "cluster.eks.aws.m.upbound.io" ] && [ "$managed_by" != "terraform" ]; then
    found_name="$cluster_name"
    found_status="$(printf '%s' "$desc" | jq -r '.status')"
    break
  fi
done <<EOF
$(printf '%s' "$CLUSTERS_JSON" | jq -r '.[]')
EOF

# No crossplane-stamped cluster => the kind is unprovisioned for this account.
if [ -z "$found_name" ]; then
  skip "no EKS cluster tagged crossplane-kind=cluster.eks.aws.m.upbound.io (the PlatformCluster abstraction has not provisioned one)"
fi

if [ "$found_status" != "ACTIVE" ]; then
  ng "PlatformCluster EKS cluster '$found_name' is '$found_status', not ACTIVE"
  exit 1
fi

ok "PlatformCluster-provisioned EKS cluster '$found_name' is ACTIVE"
covers "$KIND"
exit "$LIVE_RC_PASS"
