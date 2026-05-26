#!/usr/bin/env bash
# Unit tests for crossplane/compositions/platform-cluster.yaml.
#
# Bug class defended: Composition silently renders wrong managed
# resource shape — wrong IAM policy ARN (cluster wouldn't bootstrap),
# missing role/cluster selector linkage (NodeGroup never attaches),
# wrong subnetIds patch path (EKS rejects empty subnet list).
# Cross-file invariants checked against the XRD.

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

COMP=crossplane/compositions/platform-cluster.yaml
XRD=crossplane/xrds/platform-cluster.yaml

# ---- 1. compositeTypeRef matches XRD ------------------------------------
COMP_TYPE_API=$(yq -r '.spec.compositeTypeRef.apiVersion' "$COMP")
COMP_TYPE_KIND=$(yq -r '.spec.compositeTypeRef.kind' "$COMP")
XRD_GROUP=$(yq -r '.spec.group' "$XRD")
XRD_VERSION=$(yq -r '.spec.versions[0].name' "$XRD")
XRD_KIND=$(yq -r '.spec.names.kind' "$XRD")
assert_eq "composition_typeRef_apiVersion" "${XRD_GROUP}/${XRD_VERSION}" "$COMP_TYPE_API"
assert_eq "composition_typeRef_kind"       "$XRD_KIND"                    "$COMP_TYPE_KIND"

# ---- 2. v2 Pipeline mode + function-patch-and-transform -----------------
MODE=$(yq -r '.spec.mode' "$COMP")
assert_eq "composition_mode_pipeline" "Pipeline" "$MODE"
FN_REF=$(yq -r '.spec.pipeline[0].functionRef.name' "$COMP")
assert_eq "composition_function_ref" "function-patch-and-transform" "$FN_REF"

# ---- 3. Eight resources rendered (2 roles, 4 attachments, cluster, NG) --
RES_COUNT=$(yq -r '.spec.pipeline[0].input.resources | length' "$COMP")
assert_eq "composition_resource_count" "8" "$RES_COUNT"

# Names — fixed order assumption gives readable test failures.
for n in cluster-role cluster-role-policy node-role node-worker-policy \
         node-cni-policy node-ecr-policy eks-cluster eks-nodegroup; do
  c=$(yq -r ".spec.pipeline[0].input.resources[] | select(.name == \"$n\") | .name" "$COMP")
  assert_eq "composition_has_resource_${n//-/_}" "$n" "$c"
done

# ---- 4. The four required EKS node group IAM policies are present -------
#
# AWS docs are explicit that the managed node group role MUST have
# these four policies; missing any one means nodes never join the
# cluster. Tests by exact ARN.
for arn in \
  "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy" \
  "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" \
  "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" \
  "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"; do
  if yq -r '.spec.pipeline[0].input.resources[].base.spec.forProvider.policyArn // ""' "$COMP" \
       | grep -qF "$arn"; then
    _pass "composition_policy_$(basename "$arn")"
  else
    _fail "composition_policy_$(basename "$arn")" "missing policyArn $arn"
  fi
done

# ---- 5. EKS Cluster uses upbound provider, not contrib ------------------
# v2: namespaced .m.upbound.io group (was .aws.upbound.io in v1).
CLUSTER_API=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "eks-cluster") | .base.apiVersion' "$COMP")
assert_eq "composition_eks_cluster_api" "eks.aws.m.upbound.io/v1beta1" "$CLUSTER_API"

NG_API=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "eks-nodegroup") | .base.apiVersion' "$COMP")
assert_eq "composition_eks_nodegroup_api" "eks.aws.m.upbound.io/v1beta1" "$NG_API"

# ---- 6. Cluster→role selector linkage works -----------------------------
#
# The EKS Cluster references the cluster IAM role by selector. If the
# selector label doesn't match the cluster-role's base.metadata.labels,
# the cluster MR sits with no roleArn and EKS rejects creation. Same
# logic for node-role and the NodeGroup.
CLUSTER_ROLE_SELECTOR=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "eks-cluster") | .base.spec.forProvider.roleArnSelector.matchLabels["platform.k8-platform.io/role"]' "$COMP")
CLUSTER_ROLE_LABEL=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "cluster-role") | .base.metadata.labels["platform.k8-platform.io/role"]' "$COMP")
assert_eq "composition_cluster_role_selector_match" "$CLUSTER_ROLE_LABEL" "$CLUSTER_ROLE_SELECTOR"

NG_NODE_SELECTOR=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "eks-nodegroup") | .base.spec.forProvider.nodeRoleArnSelector.matchLabels["platform.k8-platform.io/role"]' "$COMP")
NODE_ROLE_LABEL=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "node-role") | .base.metadata.labels["platform.k8-platform.io/role"]' "$COMP")
assert_eq "composition_node_role_selector_match" "$NODE_ROLE_LABEL" "$NG_NODE_SELECTOR"

NG_CLUSTER_SELECTOR=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "eks-nodegroup") | .base.spec.forProvider.clusterNameSelector.matchLabels["platform.k8-platform.io/role"]' "$COMP")
EKS_CLUSTER_LABEL=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "eks-cluster") | .base.metadata.labels["platform.k8-platform.io/role"]' "$COMP")
assert_eq "composition_ng_cluster_selector_match" "$EKS_CLUSTER_LABEL" "$NG_CLUSTER_SELECTOR"

# ---- 7. subnetIds patched onto both cluster and nodegroup ---------------
#
# A common bug: patch subnetIds onto the cluster only, leaving the
# NodeGroup empty. NodeGroup then fails admission with a misleading
# "no subnets" error after the cluster is already half-created.
CLUSTER_SUBNETS=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "eks-cluster") | .patches[] | select(.fromFieldPath == "spec.vpc.subnetIds") | .toFieldPath' "$COMP")
NG_SUBNETS=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "eks-nodegroup") | .patches[] | select(.fromFieldPath == "spec.vpc.subnetIds") | .toFieldPath' "$COMP")
[ -n "$CLUSTER_SUBNETS" ] && [ "$CLUSTER_SUBNETS" != "null" ] \
  && _pass "composition_cluster_subnets_patched" \
  || _fail "composition_cluster_subnets_patched" "no subnetIds patch on eks-cluster"
[ -n "$NG_SUBNETS" ] && [ "$NG_SUBNETS" != "null" ] \
  && _pass "composition_nodegroup_subnets_patched" \
  || _fail "composition_nodegroup_subnets_patched" "no subnetIds patch on eks-nodegroup"

# ---- 8. AssumeRolePolicy principals are not swapped ---------------------
#
# The cluster role trusts eks.amazonaws.com; the node role trusts
# ec2.amazonaws.com. Swapping them produces an inscrutable apply-time
# failure with no admission-time guard. Asserted here so a swap shows
# up at unit-test time.
CLUSTER_TRUST=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "cluster-role") | .base.spec.forProvider.assumeRolePolicy' "$COMP")
NODE_TRUST=$(yq -r \
  '.spec.pipeline[0].input.resources[] | select(.name == "node-role") | .base.spec.forProvider.assumeRolePolicy' "$COMP")
echo "$CLUSTER_TRUST" | grep -q "eks.amazonaws.com" \
  && _pass "composition_cluster_role_trusts_eks" \
  || _fail "composition_cluster_role_trusts_eks" "cluster-role does not trust eks.amazonaws.com"
echo "$NODE_TRUST" | grep -q "ec2.amazonaws.com" \
  && _pass "composition_node_role_trusts_ec2" \
  || _fail "composition_node_role_trusts_ec2" "node-role does not trust ec2.amazonaws.com"

# ---- 9. Every providerConfigRef uses ClusterProviderConfig (v2) ---------
#
# Cross-segment hard pin: see test_platform_secret_composition.sh §11
# for the full rationale. v2 + provider-family-aws v2.5.0 mandates
# kind: ClusterProviderConfig (cluster-scoped) on every base block
# that declares a providerConfigRef. The namespaced kind: ProviderConfig
# is also offered by the provider but the migration pre-committed to a
# single shared ClusterProviderConfig named `default` — using anything
# else only fails at apply time.
PCR_KINDS=$(yq -r '.spec.pipeline[0].input.resources[].base.spec.providerConfigRef.kind // empty' "$COMP")
if [ -z "$PCR_KINDS" ]; then
  _fail "composition_providerConfigRef_kinds_present" \
        "no providerConfigRef.kind found on any base; v2 requires explicit kind: ClusterProviderConfig"
else
  PCR_BAD=$(printf '%s\n' "$PCR_KINDS" | grep -v -x ClusterProviderConfig || true)
  if [ -z "$PCR_BAD" ]; then
    _pass "composition_providerConfigRef_kind_ClusterProviderConfig"
  else
    _fail "composition_providerConfigRef_kind_ClusterProviderConfig" \
          "non-ClusterProviderConfig values: $(printf '%s' "$PCR_BAD" | tr '\n' ',' )"
  fi
fi

assert_summary
