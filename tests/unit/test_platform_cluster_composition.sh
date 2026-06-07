#!/usr/bin/env bash
# Unit tests for crossplane/compositions/platform-cluster.yaml.
#
# Bug class defended: Composition silently renders wrong managed
# resource shape — wrong IAM policy ARN (cluster wouldn't bootstrap),
# missing role/cluster selector linkage (NodeGroup never attaches),
# wrong subnetIds source (EKS rejects empty subnet list), or a missing
# cert resource (cluster has no TLS). Cross-file invariants checked
# against the XRD.
#
# Phase 3 (docs/decisions/0003): the Composition gained a
# function-environment-configs pipeline step (loads the cluster-network
# EnvironmentConfig with subnets/zone/domain from base Terraform output)
# and three ACM cert resources. The patch-and-transform step is now
# selected by functionRef name rather than positional index, so the
# tests don't break when pipeline-step order changes.

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

COMP=crossplane/compositions/platform-cluster.yaml
XRD=crossplane/xrds/platform-cluster.yaml

# Select the patch-and-transform step's input by functionRef name (robust
# to pipeline-step ordering). Usage: yq -r "${PT} ..." "$COMP"
PT='.spec.pipeline[] | select(.functionRef.name == "function-patch-and-transform") | .input'

# ---- 1. compositeTypeRef matches XRD ------------------------------------
COMP_TYPE_API=$(yq -r '.spec.compositeTypeRef.apiVersion' "$COMP")
COMP_TYPE_KIND=$(yq -r '.spec.compositeTypeRef.kind' "$COMP")
XRD_GROUP=$(yq -r '.spec.group' "$XRD")
XRD_VERSION=$(yq -r '.spec.versions[0].name' "$XRD")
XRD_KIND=$(yq -r '.spec.names.kind' "$XRD")
assert_eq "composition_typeRef_apiVersion" "${XRD_GROUP}/${XRD_VERSION}" "$COMP_TYPE_API"
assert_eq "composition_typeRef_kind"       "$XRD_KIND"                    "$COMP_TYPE_KIND"

# ---- 2. v2 Pipeline mode + both functions present ----------------------
MODE=$(yq -r '.spec.mode' "$COMP")
assert_eq "composition_mode_pipeline" "Pipeline" "$MODE"

# function-environment-configs must be present (loads the cluster-network
# EnvironmentConfig: subnets/zone/domain from base Terraform output).
ENV_STEP=$(yq -r '.spec.pipeline[] | select(.functionRef.name == "function-environment-configs") | .functionRef.name' "$COMP")
assert_eq "composition_has_environment_configs_step" "function-environment-configs" "$ENV_STEP"

# The cluster-network EnvironmentConfig is referenced by name.
ENV_REF=$(yq -r '.spec.pipeline[] | select(.functionRef.name == "function-environment-configs") | .input.spec.environmentConfigs[0].ref.name' "$COMP")
assert_eq "composition_env_config_ref_cluster_network" "cluster-network" "$ENV_REF"

# function-patch-and-transform must be present.
FN_REF=$(yq -r '.spec.pipeline[] | select(.functionRef.name == "function-patch-and-transform") | .functionRef.name' "$COMP")
assert_eq "composition_function_ref" "function-patch-and-transform" "$FN_REF"

# ---- 3. Fourteen resources rendered -----------------------------------
# 2 roles, 4 attachments, cluster, node group, + 3 cert resources
# (acm Certificate, route53 validation Record, acm CertificateValidation),
# + 3 sandbox kubectl access resources (SecurityGroupIngressRule,
# AccessEntry, AccessPolicyAssociation — docs/decisions/0006).
RES_COUNT=$(yq -r "${PT}.resources | length" "$COMP")
assert_eq "composition_resource_count" "14" "$RES_COUNT"

# Names — fixed set gives readable test failures.
for n in cluster-role cluster-role-policy node-role node-worker-policy \
         node-cni-policy node-ecr-policy eks-cluster eks-nodegroup \
         cluster-certificate cluster-cert-validation-record cluster-cert-validation \
         kube-relay-ingress sandbox-access-entry sandbox-access-policy; do
  c=$(yq -r "${PT}.resources[] | select(.name == \"$n\") | .name" "$COMP")
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
  # Capture-then-grep (NOT `yq ... | grep -qF`): under `set -o pipefail`,
  # grep -q exits on first match and SIGPIPEs the still-writing yq, whose 141
  # then propagates as the pipeline's status — an intermittent false FAIL
  # (~10% observed; OI-2026-06-05-1). A here-string has no upstream process.
  policy_arns="$(yq -r "${PT}.resources[].base.spec.forProvider.policyArn // \"\"" "$COMP")"
  if grep -qF "$arn" <<<"$policy_arns"; then
    _pass "composition_policy_$(basename "$arn")"
  else
    _fail "composition_policy_$(basename "$arn")" "missing policyArn $arn"
  fi
done

# ---- 5. EKS Cluster uses upbound provider, not contrib ------------------
# v2: namespaced .m.upbound.io group (was .aws.upbound.io in v1).
CLUSTER_API=$(yq -r "${PT}.resources[] | select(.name == \"eks-cluster\") | .base.apiVersion" "$COMP")
assert_eq "composition_eks_cluster_api" "eks.aws.m.upbound.io/v1beta1" "$CLUSTER_API"

NG_API=$(yq -r "${PT}.resources[] | select(.name == \"eks-nodegroup\") | .base.apiVersion" "$COMP")
assert_eq "composition_eks_nodegroup_api" "eks.aws.m.upbound.io/v1beta1" "$NG_API"

# ---- 5a. EKS Cluster enables API access entries (auto-012) --------------
# Bug class: the EKS default authenticationMode is CONFIG_MAP, under which
# the EKS API rejects AccessEntry create/list. The whole hub->spoke trust
# plane (XSpokeAccess AccessEntry/AccessPolicyAssociation + the ArgoCD
# cluster Secret's exec-auth argocd role) silently cannot provision until
# the cluster is API or API_AND_CONFIG_MAP. Without this assertion the gap
# is invisible at author time and only surfaces as an
# InvalidRequestException at spoke-registration time on a live cluster.
CLUSTER_AUTHMODE=$(yq -r "${PT}.resources[] | select(.name == \"eks-cluster\") | .base.spec.forProvider.accessConfig.authenticationMode" "$COMP")
case "$CLUSTER_AUTHMODE" in
  API|API_AND_CONFIG_MAP)
    _pass "composition_eks_cluster_access_entries_enabled" ;;
  *)
    _fail "composition_eks_cluster_access_entries_enabled" \
          "eks-cluster accessConfig.authenticationMode is '${CLUSTER_AUTHMODE}'; must be API or API_AND_CONFIG_MAP for EKS AccessEntries" ;;
esac

# ---- 5b. Cert resources use the modern .m.upbound.io provider groups ----
# Phase 3 (docs/decisions/0003). Wrong group = MR never reconciles.
CERT_API=$(yq -r "${PT}.resources[] | select(.name == \"cluster-certificate\") | .base.apiVersion" "$COMP")
assert_eq "composition_certificate_api" "acm.aws.m.upbound.io/v1beta1" "$CERT_API"
REC_API=$(yq -r "${PT}.resources[] | select(.name == \"cluster-cert-validation-record\") | .base.apiVersion" "$COMP")
assert_eq "composition_validation_record_api" "route53.aws.m.upbound.io/v1beta1" "$REC_API"
CV_API=$(yq -r "${PT}.resources[] | select(.name == \"cluster-cert-validation\") | .base.apiVersion" "$COMP")
assert_eq "composition_cert_validation_api" "acm.aws.m.upbound.io/v1beta1" "$CV_API"

# Certificate must use DNS validation (not EMAIL) — automatic, no inbox.
CERT_VALIDATION=$(yq -r "${PT}.resources[] | select(.name == \"cluster-certificate\") | .base.spec.forProvider.validationMethod" "$COMP")
assert_eq "composition_certificate_dns_validation" "DNS" "$CERT_VALIDATION"

# The wildcard domain is built by CombineFromEnvironment [subdomain, domain]
# on the Certificate, and subdomain is staged into the environment by a
# top-level environment patch. Both must be present or domainName is empty.
COMBINE=$(yq -r "${PT}.resources[] | select(.name == \"cluster-certificate\") | .patches[] | select(.type == \"CombineFromEnvironment\") | .toFieldPath" "$COMP")
assert_eq "composition_cert_domain_combine" "spec.forProvider.domainName" "$COMBINE"
ENV_SUBDOMAIN=$(yq -r "${PT}.environment.patches[] | select(.toFieldPath == \"subdomain\") | .fromFieldPath" "$COMP")
assert_eq "composition_env_subdomain_patch" "spec.dns.subdomain" "$ENV_SUBDOMAIN"

# CertificateValidation gates on Ready=True (this is the "confirm the cert
# is ISSUED" step that holds the XR un-Ready until TLS is real).
CV_READY=$(yq -r "${PT}.resources[] | select(.name == \"cluster-cert-validation\") | .readinessChecks[0].matchCondition.status" "$COMP")
assert_eq "composition_cert_validation_ready_gate" "True" "$CV_READY"

# ---- 6. Cluster→role selector linkage works -----------------------------
#
# The EKS Cluster references the cluster IAM role by selector. If the
# selector label doesn't match the cluster-role's base.metadata.labels,
# the cluster MR sits with no roleArn and EKS rejects creation. Same
# logic for node-role and the NodeGroup.
CLUSTER_ROLE_SELECTOR=$(yq -r "${PT}.resources[] | select(.name == \"eks-cluster\") | .base.spec.forProvider.roleArnSelector.matchLabels[\"platform.k8-platform.io/role\"]" "$COMP")
CLUSTER_ROLE_LABEL=$(yq -r "${PT}.resources[] | select(.name == \"cluster-role\") | .base.metadata.labels[\"platform.k8-platform.io/role\"]" "$COMP")
assert_eq "composition_cluster_role_selector_match" "$CLUSTER_ROLE_LABEL" "$CLUSTER_ROLE_SELECTOR"

NG_NODE_SELECTOR=$(yq -r "${PT}.resources[] | select(.name == \"eks-nodegroup\") | .base.spec.forProvider.nodeRoleArnSelector.matchLabels[\"platform.k8-platform.io/role\"]" "$COMP")
NODE_ROLE_LABEL=$(yq -r "${PT}.resources[] | select(.name == \"node-role\") | .base.metadata.labels[\"platform.k8-platform.io/role\"]" "$COMP")
assert_eq "composition_node_role_selector_match" "$NODE_ROLE_LABEL" "$NG_NODE_SELECTOR"

NG_CLUSTER_SELECTOR=$(yq -r "${PT}.resources[] | select(.name == \"eks-nodegroup\") | .base.spec.forProvider.clusterNameSelector.matchLabels[\"platform.k8-platform.io/role\"]" "$COMP")
EKS_CLUSTER_LABEL=$(yq -r "${PT}.resources[] | select(.name == \"eks-cluster\") | .base.metadata.labels[\"platform.k8-platform.io/role\"]" "$COMP")
assert_eq "composition_ng_cluster_selector_match" "$EKS_CLUSTER_LABEL" "$NG_CLUSTER_SELECTOR"

# ---- 7. subnetIds sourced from the environment onto cluster + nodegroup --
#
# Phase 3: subnets come from the cluster-network EnvironmentConfig
# (FromEnvironmentFieldPath privateSubnetIds), NOT from the XR. A common
# bug: patch subnetIds onto the cluster only, leaving the NodeGroup empty.
CLUSTER_SUBNETS=$(yq -r "${PT}.resources[] | select(.name == \"eks-cluster\") | .patches[] | select(.type == \"FromEnvironmentFieldPath\" and .fromFieldPath == \"privateSubnetIds\") | .toFieldPath" "$COMP")
NG_SUBNETS=$(yq -r "${PT}.resources[] | select(.name == \"eks-nodegroup\") | .patches[] | select(.type == \"FromEnvironmentFieldPath\" and .fromFieldPath == \"privateSubnetIds\") | .toFieldPath" "$COMP")
[ -n "$CLUSTER_SUBNETS" ] && [ "$CLUSTER_SUBNETS" != "null" ] \
  && _pass "composition_cluster_subnets_from_env" \
  || _fail "composition_cluster_subnets_from_env" "no env subnetIds patch on eks-cluster"
[ -n "$NG_SUBNETS" ] && [ "$NG_SUBNETS" != "null" ] \
  && _pass "composition_nodegroup_subnets_from_env" \
  || _fail "composition_nodegroup_subnets_from_env" "no env subnetIds patch on eks-nodegroup"

# ---- 8. AssumeRolePolicy principals are not swapped ---------------------
#
# The cluster role trusts eks.amazonaws.com; the node role trusts
# ec2.amazonaws.com. Swapping them produces an inscrutable apply-time
# failure with no admission-time guard.
CLUSTER_TRUST=$(yq -r "${PT}.resources[] | select(.name == \"cluster-role\") | .base.spec.forProvider.assumeRolePolicy" "$COMP")
NODE_TRUST=$(yq -r "${PT}.resources[] | select(.name == \"node-role\") | .base.spec.forProvider.assumeRolePolicy" "$COMP")
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
# kind: ClusterProviderConfig on every base block that declares a
# providerConfigRef — including the three new cert resources.
PCR_KINDS=$(yq -r "${PT}.resources[] | select(.base.spec.providerConfigRef.kind != null) | .base.spec.providerConfigRef.kind" "$COMP")
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
