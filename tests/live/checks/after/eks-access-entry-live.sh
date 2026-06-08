#!/usr/bin/env bash
# LIVE behavioral check (after tier) — a Crossplane-provisioned EKS AccessEntry
# exists and is healthy.
#
# This is the BEHAVIORAL oracle for eks.aws.m.upbound.io/AccessEntry per
# ADR-0006: it proves the PlatformCluster abstraction actually produced a real
# EKS access entry, not that a manifest says so. It locates the crossplane
# EKS cluster by tag (crossplane-kind=cluster.eks.aws.m.upbound.io), then
# enumerates access entries on that cluster and selects the one tagged
# crossplane-kind=accessentry.eks.aws.m.upbound.io (or
# PlatformAbstraction=PlatformCluster). A Terraform-created entry does NOT
# count; only the crossplane-delivered artifact does.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only (describe/list only) -- safe
# in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="eks.aws.m.upbound.io/AccessEntry"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (EKS AccessEntry live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for the Crossplane PlatformCluster EKS cluster (region $REGION)"

# Find the Crossplane-provisioned EKS cluster by the composition stamp tag.
# The Terraform mgmt cluster (k8-platform-mgmt) is excluded -- it carries
# ManagedBy=terraform, not crossplane-kind=cluster.eks.aws.m.upbound.io.
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

log "found crossplane EKS cluster: $crossplane_cluster -- enumerating access entries"

# List all access entries on the crossplane cluster.
ENTRIES_JSON="$(aws eks list-access-entries --cluster-name "$crossplane_cluster" \
  --region "$REGION" --query 'accessEntries' --output json 2>/dev/null)" \
  || skip "eks:ListAccessEntries not permitted / unavailable here"

ENTRY_COUNT="$(printf '%s' "$ENTRIES_JSON" | jq 'length')"
[ "${ENTRY_COUNT:-0}" -gt 0 ] \
  || skip "no access entries on cluster $crossplane_cluster (AccessEntry not provisioned)"

# Walk each access entry; describe it and check for the crossplane stamp tag.
found_arn=""
found_principal=""
while IFS= read -r principal_arn; do
  [ -z "$principal_arn" ] && continue
  desc_json="$(aws eks describe-access-entry \
    --cluster-name "$crossplane_cluster" \
    --principal-arn "$principal_arn" \
    --region "$REGION" --output json 2>/dev/null)" || continue
  entry_arn="$(printf '%s' "$desc_json" | jq -r '.accessEntry.accessEntryArn // empty')"
  [ -z "$entry_arn" ] && continue
  # Read tags directly from the describe output.
  is_crossplane="$(printf '%s' "$desc_json" | jq -r '
    (.accessEntry.tags // {}) as $t
    | if (($t["crossplane-kind"] == "accessentry.eks.aws.m.upbound.io")
          or ($t["PlatformAbstraction"] == "PlatformCluster")) then "yes" else "no" end')"
  if [ "$is_crossplane" = "yes" ]; then
    found_arn="$entry_arn"
    found_principal="$principal_arn"
    break
  fi
done <<EOF
$(printf '%s' "$ENTRIES_JSON" | jq -r '.[]')
EOF

if [ -z "$found_arn" ]; then
  skip "no access entry on cluster $crossplane_cluster tagged crossplane-kind=accessentry.eks.aws.m.upbound.io (or PlatformAbstraction=PlatformCluster) -- AccessEntry not provisioned"
fi

# Health check: describe returned an accessEntryArn -- the entry exists.
ok "Crossplane AccessEntry on cluster '$crossplane_cluster' for principal '$found_principal' exists (arn: $found_arn)"
covers "$KIND"
exit "$LIVE_RC_PASS"
