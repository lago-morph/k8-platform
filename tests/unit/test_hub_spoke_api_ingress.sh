#!/usr/bin/env bash
# OI-2026-06-07-4 / SUBSTRATE row 2 — the hub→hosted-cluster EKS-API 443
# security-group rule has a DURABLE form in the platform-cluster
# Composition. The live form (aws ec2 authorize-security-group-ingress,
# auto-012 + auto-016) died with each account; without the durable rule the
# hub ArgoCD application-controller cannot reach a fresh spoke's private
# API endpoint and every bring-up strands.
#
# Bug classes defended:
#   - the rule dropped/renamed from the Composition
#   - regression to SecurityGroupIngressRule (provider-aws-ec2 v2.5.0
#     cannot observe it — "Missing Resource Identity After Read",
#     hashicorp/terraform-provider-aws#45303; the kube-relay-ingress
#     comment documents the same trap)
#   - the source SG patched from anywhere but the EnvironmentConfig key
#     terraform publishes (a committed SG literal would be
#     account-ephemeral — AGENTS §8.1)
#   - terraform stops publishing managementNodeSecurityGroupId
set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

COMP=crossplane/compositions/platform-cluster.yaml
P3=terraform/management/crossplane-phase3.tf
FIX=crossplane/xrds/platform-cluster/render-fixtures/required-resources.yaml
for f in "$COMP" "$P3" "$FIX"; do
  [ -f "$f" ] || { _fail "file_exists:$f" "$f not found"; assert_summary; }
done
_pass "files_exist"

PT='.spec.pipeline[] | select(.functionRef.name == "function-patch-and-transform") | .input'
R="${PT}.resources[] | select(.name==\"hub-eks-api-ingress\")"

# the resource exists and is the CLASSIC rule kind
assert_eq "rule_kind_classic" "SecurityGroupRule" "$(yq -r "${R} | .base.kind" "$COMP")"
assert_eq "rule_apiVersion" "ec2.aws.m.upbound.io/v1beta1" "$(yq -r "${R} | .base.apiVersion" "$COMP")"

# 443/tcp ingress
assert_eq "rule_type_ingress" "ingress" "$(yq -r "${R} | .base.spec.forProvider.type" "$COMP")"
assert_eq "rule_protocol" "tcp" "$(yq -r "${R} | .base.spec.forProvider.protocol" "$COMP")"
assert_eq "rule_fromPort" "443" "$(yq -r "${R} | .base.spec.forProvider.fromPort" "$COMP")"
assert_eq "rule_toPort" "443" "$(yq -r "${R} | .base.spec.forProvider.toPort" "$COMP")"

# target = THIS cluster's EKS-managed SG (routed via XR status); source =
# the mgmt node SG from the EnvironmentConfig (never a committed literal)
assert_eq "rule_target_from_cluster_status" "status.clusterSecurityGroupId" \
  "$(yq -r "${R} | .patches[] | select(.toFieldPath==\"spec.forProvider.securityGroupId\") | .fromFieldPath" "$COMP")"
SRC_PATCH_TYPE=$(yq -r "${R} | .patches[] | select(.toFieldPath==\"spec.forProvider.sourceSecurityGroupId\") | .type" "$COMP")
assert_eq "rule_source_patch_is_env" "FromEnvironmentFieldPath" "$SRC_PATCH_TYPE"
assert_eq "rule_source_env_key" "managementNodeSecurityGroupId" \
  "$(yq -r "${R} | .patches[] | select(.toFieldPath==\"spec.forProvider.sourceSecurityGroupId\") | .fromFieldPath" "$COMP")"

# the Composition must not regress to the unobservable kind anywhere
if yq -r "${PT}.resources[].base.kind" "$COMP" | grep -qx 'SecurityGroupIngressRule'; then
  _fail "no_SecurityGroupIngressRule" "SecurityGroupIngressRule present — provider-aws-ec2 v2.5.0 cannot observe it (tf-aws#45303)"
else
  _pass "no_SecurityGroupIngressRule"
fi

# terraform publishes the key the Composition reads
grep -qE 'managementNodeSecurityGroupId *= *module\.eks\.node_security_group_id' "$P3" \
  && _pass "terraform_publishes_mgmt_node_sg" \
  || _fail "terraform_publishes_mgmt_node_sg" "crossplane-phase3.tf must publish managementNodeSecurityGroupId from module.eks.node_security_group_id"

# the render fixture EnvironmentConfig carries the key (else the golden
# renders without sourceSecurityGroupId and the contract goes untested)
grep -q 'managementNodeSecurityGroupId:' "$FIX" \
  && _pass "render_fixture_has_mgmt_node_sg" \
  || _fail "render_fixture_has_mgmt_node_sg" "$FIX missing managementNodeSecurityGroupId stub"

assert_summary
