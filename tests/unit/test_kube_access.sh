#!/usr/bin/env bash
# Static guards for the sandbox-kubectl-via-SSM-tunnel mechanism
# (docs/decisions/0008): the hub terraform (kube-access.tf), the platform-cluster
# Composition wiring, and the kubeconfig helper. Several checks are regression
# guards for bugs found during live bring-up (2026-06-07):
#   - EKS access entry 409 (cloud_user is already the hub cluster creator)
#   - invalid SG-rule description charset ('->' is rejected by AWS)
#   - orphaned session-manager-plugin (killing the parent, not the group)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

KA="$HERE/../../terraform/management/kube-access.tf"
P3="$HERE/../../terraform/management/crossplane-phase3.tf"
COMP="$HERE/../../crossplane/compositions/platform-cluster.yaml"
HELPER="$HERE/../../scripts/sandbox-kubeconfig.sh"
for f in "$KA" "$P3" "$COMP" "$HELPER"; do
  [ -f "$f" ] || { echo "missing $f"; exit 2; }
done

# ── hub terraform: the relay ────────────────────────────────────────────────
grep -qE 'resource "aws_instance" "kube_relay"' "$KA" \
  && pass "kube-access.tf declares the relay instance" \
  || fail "kube-access.tf must declare aws_instance.kube_relay"

grep -qE 'http_tokens +=  *"required"' "$KA" \
  && pass "relay requires IMDSv2 (http_tokens required)" \
  || fail "relay must set metadata_options http_tokens=required (IMDSv2)"

# Security invariant: the relay SG is OUTBOUND-ONLY. No inline `ingress {` block
# anywhere in the file — cluster reach is granted by the cluster SG admitting the
# relay (a separate aws_vpc_security_group_ingress_rule), never an inbound rule
# on the relay itself.
if grep -qE '^[[:space:]]*ingress[[:space:]]*\{' "$KA"; then
  fail "kube-access.tf must NOT give the relay an inbound rule" \
       "the relay is outbound-only; cluster reach is via the cluster SG admitting it."
else
  pass "relay SG is outbound-only (no inline ingress block)"
fi

# The cluster admits the relay to the API on 443.
grep -qE 'resource "aws_vpc_security_group_ingress_rule" "kube_relay_to_mgmt"' "$KA" \
  && pass "kube-access.tf admits the relay to the mgmt API (ingress rule)" \
  || fail "kube-access.tf must add an ingress rule admitting the relay SG on 443"
grep -qE 'from_port *= *443' "$KA" && grep -qE 'referenced_security_group_id *= *aws_security_group.kube_relay.id' "$KA" \
  && pass "ingress rule is 443 from the relay SG" \
  || fail "the relay ingress rule must be 443 referencing the relay SG"

# Regression (409): do NOT create an EKS access entry for the sandbox on the hub —
# cloud_user is the cluster creator and already has an entry
# (enable_cluster_creator_admin_permissions). A duplicate is ResourceInUseException.
if grep -qE 'resource "aws_eks_access_entry"' "$KA"; then
  fail "kube-access.tf must NOT create an aws_eks_access_entry on the hub" \
       "cloud_user is the cluster creator and already has an entry → 409 ResourceInUseException."
else
  pass "no duplicate hub access entry (relies on creator-admin; regression for 409)"
fi

# Regression (charset): SG-rule descriptions must not contain '<' or '>' (not in
# AWS's allowed description charset; '->' broke the apply).
if grep -E 'description' "$KA" | grep -qE '[<>]'; then
  fail "kube-access.tf SG descriptions must not contain < or >" \
       "AWS rejects them: 'Invalid rule description'. Use 'to' not '->'."
else
  pass "SG-rule descriptions use a valid charset (no < or >)"
fi

# ── EnvironmentConfig + provider plumbing for the Composition ────────────────
grep -qE 'relaySecurityGroupId *= *aws_security_group.kube_relay.id' "$P3" \
  && pass "relay SG id is published to the cluster-network EnvironmentConfig" \
  || fail "crossplane-phase3.tf must publish relaySecurityGroupId for the Composition"

grep -qE 'name: provider-aws-ec2' "$P3" \
  && pass "provider-aws-ec2 is in the child-provider set (for the relay-ingress MR)" \
  || fail "crossplane-phase3.tf must install provider-aws-ec2 (SecurityGroupIngressRule)"

# ── Composition wiring ──────────────────────────────────────────────────────
grep -qE 'kind: SecurityGroupIngressRule' "$COMP" \
  && pass "Composition admits the shared relay via a SecurityGroupIngressRule MR" \
  || fail "Composition must add a SecurityGroupIngressRule admitting the relay"
grep -qE 'fromFieldPath: relaySecurityGroupId' "$COMP" \
  && pass "Composition ingress rule sources the relay SG from the env" \
  || fail "Composition ingress rule must read relaySecurityGroupId from the env"
grep -qE 'AmazonEKSAdminViewPolicy' "$COMP" \
  && pass "Composition grants the sandbox a READ-ONLY access entry (AdminView)" \
  || fail "Composition must use AmazonEKSAdminViewPolicy (read-only) for the sandbox"
# Regression (charset) in the Composition too.
if grep -E 'description:' "$COMP" | grep -qE '[<>]'; then
  fail "Composition SG-rule description must not contain < or >"
else
  pass "Composition SG descriptions use a valid charset"
fi

# ── kubeconfig helper ───────────────────────────────────────────────────────
bash -n "$HELPER" && pass "sandbox-kubeconfig.sh is syntactically valid" \
  || fail "sandbox-kubeconfig.sh has a syntax error"
# Regression (orphaned plugin): must kill the process GROUP, not just the parent.
grep -qE 'kill -TERM -- "-\$\{pid\}"' "$HELPER" \
  && pass "helper kills the tunnel process group (regression: orphaned plugin)" \
  || fail "helper must kill the process group so session-manager-plugin is reaped"
grep -qE 'tls-server-name' "$HELPER" \
  && pass "helper sets tls-server-name (so the real cluster CA SAN verifies)" \
  || fail "helper must set tls-server-name to the real endpoint host"
grep -qE 'tag:Role,Values=kube-relay' "$HELPER" \
  && pass "helper discovers the shared relay by tag Role=kube-relay" \
  || fail "helper must discover the relay by tag Role=kube-relay"

summary
