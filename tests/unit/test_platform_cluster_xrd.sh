#!/usr/bin/env bash
# Unit tests for crossplane/xrds/platform-cluster.yaml.
#
# Bug class defended: XRD schema drift on the second XRD — same shape
# of mistakes that bit PlatformSecret (unserved version,
# x-kubernetes-preserve-unknown-fields silently true, accidental
# regression to v1 claim/composite split). Mirrors
# test_platform_secret_xrd.sh structurally on purpose.
#
# v2 contract: apiextensions.crossplane.io/v2 + spec.scope: Namespaced
# + no spec.claimNames.

set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

XRD=crossplane/xrds/platform-cluster.yaml

if [ ! -f "$XRD" ]; then
  _fail "xrd_file_exists" "$XRD not found"
  assert_summary
fi
_pass "xrd_file_exists"

assert_eq "xrd_apiVersion" "apiextensions.crossplane.io/v2" "$(yq -r '.apiVersion' "$XRD")"
assert_eq "xrd_kind"       "CompositeResourceDefinition"    "$(yq -r '.kind'       "$XRD")"
assert_eq "xrd_group"      "platform.k8-platform.io"        "$(yq -r '.spec.group' "$XRD")"

# v2 namespaced scope (positive) + no v1 claimNames (regression).
# See test_platform_secret_xrd.sh §2 for the full rationale.
SCOPE=$(yq -r '.spec.scope' "$XRD")
assert_eq "xrd_spec_scope_Namespaced" "Namespaced" "$SCOPE"

CLAIM_NAMES=$(yq -r '.spec.claimNames' "$XRD")
assert_eq "xrd_spec_claimNames_absent" "null" "$CLAIM_NAMES"

COMPOSITE_KIND=$(yq -r '.spec.names.kind' "$XRD")
assert_eq "xrd_composite_kind" "XPlatformCluster" "$COMPOSITE_KIND"

for f in plural listKind singular; do
  v=$(yq -r ".spec.names.$f" "$XRD")
  [ -n "$v" ] && [ "$v" != "null" ] \
    && _pass "xrd_composite_names_${f}_present" \
    || _fail "xrd_composite_names_${f}_present" "spec.names.$f missing"
done

SERVED=$(yq -r '.spec.versions[] | select(.name == "v1alpha1") | .served' "$XRD")
REFER=$(yq -r '.spec.versions[] | select(.name == "v1alpha1") | .referenceable' "$XRD")
assert_eq "xrd_v1alpha1_served"        "true" "$SERVED"
assert_eq "xrd_v1alpha1_referenceable" "true" "$REFER"

# defaultCompositionRef must match the Composition's metadata.name —
# missing this means a claim resolves no Composition and stays stuck.
DEFAULT_COMP=$(yq -r '.spec.defaultCompositionRef.name' "$XRD")
assert_eq "xrd_default_composition" "platform-cluster-aws" "$DEFAULT_COMP"

COMP=crossplane/compositions/platform-cluster.yaml
if [ -f "$COMP" ]; then
  COMP_NAME=$(yq -r '.metadata.name' "$COMP")
  assert_eq "xrd_default_composition_matches_composition_file" "$DEFAULT_COMP" "$COMP_NAME"
fi

# Required-fields contract: name and dns must both be required at the
# top level. Without name, two clusters collide on resource-naming
# patches; without dns.subdomain, the wildcard ACM cert domain
# (*.<subdomain>.<domain>) cannot be built and ExternalDNS has no scope.
#
# Phase 3 (docs/decisions/0003): spec.vpc was REMOVED — private subnet
# IDs are account-ephemeral (AGENTS §8.1) and are injected from the
# cluster-network EnvironmentConfig (base Terraform output), not carried
# on the XR. So vpc is intentionally NOT required (and not present).
REQUIRED=$(yq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.required[]' "$XRD")
echo "$REQUIRED" | grep -qx 'name' \
  && _pass "xrd_spec_name_required" \
  || _fail "xrd_spec_name_required" "spec.name not in required"
echo "$REQUIRED" | grep -qx 'dns' \
  && _pass "xrd_spec_dns_required" \
  || _fail "xrd_spec_dns_required" "spec.dns not in required"
echo "$REQUIRED" | grep -qx 'vpc' \
  && _fail "xrd_spec_vpc_removed" "spec.vpc should be removed (subnets come from EnvironmentConfig)" \
  || _pass "xrd_spec_vpc_removed"

# dns.subdomain must exist with a DNS-label pattern. It is the per-cluster
# label used to build *.<subdomain>.<domain> and scope ExternalDNS.
SUBDOMAIN_PATTERN=$(yq -r \
  '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.dns.properties.subdomain.pattern' \
  "$XRD")
[ -n "$SUBDOMAIN_PATTERN" ] && [ "$SUBDOMAIN_PATTERN" != "null" ] \
  && _pass "xrd_dns_subdomain_pattern_present" \
  || _fail "xrd_dns_subdomain_pattern_present" "spec.dns.subdomain.pattern missing"

# The cluster's issued ACM cert ARN must be published on status so the
# cluster's ingress-nginx NLB can consume it (docs/decisions/0003).
CERT_ARN_STATUS=$(yq -r \
  '.spec.versions[0].schema.openAPIV3Schema.properties.status.properties.certificateArn.type' \
  "$XRD")
assert_eq "xrd_status_certificateArn_present" "string" "$CERT_ARN_STATUS"

# Strict schema: no x-kubernetes-preserve-unknown-fields: true anywhere.
# (per adversarial-reviewer A finding 14 — preserve-unknown-fields
# silently allows typos in claims and is the wrong default for a
# platform abstraction.)
if grep -q "x-kubernetes-preserve-unknown-fields:[[:space:]]*true" "$XRD"; then
  _fail "xrd_strict_schema" "x-kubernetes-preserve-unknown-fields: true found"
else
  _pass "xrd_strict_schema"
fi

assert_summary
