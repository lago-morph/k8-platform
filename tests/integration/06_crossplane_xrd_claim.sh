#!/usr/bin/env bash
# 06: Crossplane XRD + Composition + Claim → composite Ready + AWS resource.
#
# Defines a tiny PlatformTestBucket XRD with one parameter (bucketName),
# a Composition that produces a single S3 Bucket MR, applies a Claim,
# waits for composite Ready, asserts the underlying S3 bucket exists.
# Tears everything down on exit.

set -uo pipefail
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
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: platformtestbuckets.test.k8-platform.local
  labels: { test.k8-platform/integration: "true" }
spec:
  group: test.k8-platform.local
  names:
    kind: PlatformTestBucket
    plural: platformtestbuckets
  claimNames:
    kind: TestBucket
    plural: testbuckets
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
    crossplane.io/xrd: platformtestbuckets.test.k8-platform.local
spec:
  compositeTypeRef:
    apiVersion: test.k8-platform.local/v1alpha1
    kind: PlatformTestBucket
  resources:
    - name: bucket
      base:
        apiVersion: s3.aws.upbound.io/v1beta1
        kind: Bucket
        spec:
          forProvider: {}
          deletionPolicy: Delete
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
apiVersion: test.k8-platform.local/v1alpha1
kind: TestBucket
metadata:
  name: $BUCKET
  namespace: $TEST_NS
spec:
  bucketName: $BUCKET
  region: $REGION
YAML

add_cleanup "kubectl delete testbucket -n $TEST_NS $BUCKET --wait=true --timeout=60s || true"
add_cleanup "kubectl delete composition testbucket-aws --wait=false"
add_cleanup "kubectl delete xrd platformtestbuckets.test.k8-platform.local --wait=false"
add_cleanup "kubectl delete ns $TEST_NS --wait=false"

wait_for "Claim TestBucket/$BUCKET becomes Ready" 240 5 -- \
  bash -c "kubectl get testbucket -n $TEST_NS $BUCKET -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"

wait_for "S3 bucket $BUCKET exists in AWS" 60 3 -- \
  bash -c "aws s3api head-bucket --bucket $BUCKET 2>/dev/null"

ok "XRD + Composition + Claim → real S3 bucket $BUCKET"
