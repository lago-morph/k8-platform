#!/usr/bin/env bash
# 05: Raw Crossplane Managed Resource → cloud resource exists.
#
# Bypasses XRDs: applies an S3 Bucket MR directly using the AWS provider's
# v2 namespaced Bucket type (s3.aws.m.upbound.io/v1beta1), waits for
# Ready, asserts the bucket exists in AWS, deletes the MR, asserts the
# bucket is gone.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws
require_ns crossplane-system

BUCKET="integ-cp-${RUN_ID}"
REGION="${AWS_REGION:-us-east-1}"

# Confirm the AWS provider is installed.
if ! kubectl get providers.pkg.crossplane.io provider-family-aws \
     -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null \
     | grep -q True; then
  skip "Crossplane AWS provider not Healthy (run terraform_data.crossplane_aws_provider first?)"
fi

cat <<YAML | trace kubectl apply -f -
apiVersion: s3.aws.m.upbound.io/v1beta1
kind: Bucket
metadata:
  name: $BUCKET
  # v2 s3.aws.m.upbound.io/v1beta1 Bucket is namespaced. Place the MR
  # in crossplane-system (symmetric with where the chainsaw harness
  # applies the ClusterProviderConfig). v2 also disallows
  # deletionPolicy on namespaced MRs — relies on the default managed
  # lifecycle instead.
  namespace: crossplane-system
  labels: { $INTEG_LABEL_KEY: "true" }
spec:
  forProvider:
    region: $REGION
YAML

add_cleanup "kubectl delete bucket.s3.aws.m.upbound.io -n crossplane-system $BUCKET --wait=false"

# SPEC-S7: canonical wait + auto-dump on timeout. Bucket is namespaced
# in v2; pass crossplane-system as the namespace argument.
"$HERE/../../scripts/wait-for-claim.sh" bucket.s3.aws.m.upbound.io "$BUCKET" "crossplane-system" 180

wait_for "S3 bucket exists in AWS" 60 3 -- \
  bash -c "aws s3api head-bucket --bucket $BUCKET 2>/dev/null"

ok "Crossplane MR Bucket $BUCKET created the real bucket"

# Delete and assert teardown.
trace kubectl delete bucket.s3.aws.m.upbound.io -n crossplane-system $BUCKET --wait=true --timeout=120s || \
  ng "could not delete MR cleanly"

wait_for "S3 bucket $BUCKET removed from AWS" 60 3 -- \
  bash -c "! aws s3api head-bucket --bucket $BUCKET 2>/dev/null"

ok "Crossplane MR teardown removed the real bucket"
