#!/usr/bin/env bash
# 06: Crossplane v2 XRD + Composition + XR → composite Ready + AWS resource.
#
# Defines a tiny PlatformTestBucket XRD (apiextensions.crossplane.io/v2,
# spec.scope: Namespaced, no claimNames) with one parameter (bucketName),
# a Composition that produces a single S3 Bucket MR, applies the XR
# directly (no v1 claim → XR promotion), waits for the XR to be Ready,
# asserts the underlying S3 bucket exists. Tears everything down on exit.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws
require_ns crossplane-system

if ! kubectl get providers.pkg.crossplane.io provider-family-aws \
     -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null \
     | grep -q True; then
  skip "Crossplane AWS provider not Healthy"
fi

BUCKET="integ-xrd-${RUN_ID}"
TEST_NS="integ-${RUN_ID}"
REGION="${AWS_REGION:-us-east-1}"

cat <<'YAML' | RUN_ID=$RUN_ID BUCKET=$BUCKET REGION=$REGION TEST_NS=$TEST_NS envsubst | trace kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v2
kind: CompositeResourceDefinition
metadata:
  name: xplatformtestbuckets.test.k8-platform.local
  labels: { test.k8-platform/integration: "true" }
spec:
  # v2: scope MUST be set explicitly. Without it the XRD defaults to
  # LegacyCluster scope, the namespace on the XR apply is silently
  # ignored, and wait-for-XR fails. claimNames is REMOVED in v2 —
  # the user creates the XR directly in their namespace.
  scope: Namespaced
  group: test.k8-platform.local
  names:
    kind: XPlatformTestBucket
    plural: xplatformtestbuckets
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                bucketName: { type: string }
                region: { type: string }
              required: [bucketName, region]
---
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: testbucket-aws
  labels:
    test.k8-platform/integration: "true"
    crossplane.io/xrd: xplatformtestbuckets.test.k8-platform.local
spec:
  compositeTypeRef:
    apiVersion: test.k8-platform.local/v1alpha1
    kind: XPlatformTestBucket
  resources:
    - name: bucket
      base:
        apiVersion: s3.aws.m.upbound.io/v1beta1
        kind: Bucket
        spec:
          forProvider: {}
      patches:
        - fromFieldPath: spec.bucketName
          toFieldPath: metadata.name
        - fromFieldPath: spec.region
          toFieldPath: spec.forProvider.region
---
apiVersion: v1
kind: Namespace
metadata: { name: $TEST_NS, labels: { test.k8-platform/integration: "true" } }
---
# v2: apply the XR directly in $TEST_NS (no v1 claim → XR promotion).
apiVersion: test.k8-platform.local/v1alpha1
kind: XPlatformTestBucket
metadata:
  name: $BUCKET
  namespace: $TEST_NS
spec:
  bucketName: $BUCKET
  region: $REGION
YAML

add_cleanup "kubectl delete xplatformtestbucket -n $TEST_NS $BUCKET --wait=true --timeout=60s || true"
add_cleanup "kubectl delete composition testbucket-aws --wait=false"
add_cleanup "kubectl delete xrd xplatformtestbuckets.test.k8-platform.local --wait=false"
add_cleanup "kubectl delete ns $TEST_NS --wait=false"

# SPEC-S7: canonical wait + auto-dump on timeout. v2 XR kind, namespaced.
"$HERE/../../scripts/wait-for-claim.sh" XPlatformTestBucket "$BUCKET" "$TEST_NS" 240

wait_for "S3 bucket $BUCKET exists in AWS" 60 3 -- \
  bash -c "aws s3api head-bucket --bucket $BUCKET 2>/dev/null"

ok "XRD + Composition + Claim → real S3 bucket $BUCKET"
