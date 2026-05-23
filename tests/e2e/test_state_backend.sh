#!/usr/bin/env bash
# E2E: verify that the workflow's Bootstrap step has created the
# S3 state bucket and DynamoDB lock table in the account.
# These are required for terraform init.
#
# Note: this test passes only AFTER `phase=base, action=plan` (or any
# other action that triggers bootstrap) has run at least once.
# Standalone `phase=test, action=test-e2e` runs do NOT trigger
# bootstrap, so when invoked alone this test will fail unless the
# bucket already exists. That's intentional — the test is verifying
# the side-effect we expect bootstrap to produce.

set -uo pipefail
cd "$(dirname "$0")/../.."

. tests/lib/assert.sh

echo "── e2e: terraform state backend ──────────────────────────────"

account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$account" ]; then
  _fail "AWS account discoverable" "sts:GetCallerIdentity returned empty"
  assert_summary
  exit 1
fi

BUCKET="k8-platform-tfstate-${account}"
TABLE="k8-platform-tfstate-lock"

set +e
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null
bucket_rc=$?

aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1
table_rc=$?
set -e

if [ "$bucket_rc" -eq 0 ]; then
  _pass "state bucket exists ($BUCKET)"
else
  echo "  (note: bucket missing is expected when test-e2e runs without prior bootstrap)"
  _fail "state bucket exists" "head-bucket on $BUCKET returned $bucket_rc"
fi

if [ "$table_rc" -eq 0 ]; then
  _pass "lock table exists ($TABLE)"
else
  echo "  (note: table missing is expected when test-e2e runs without prior bootstrap)"
  _fail "lock table exists" "describe-table on $TABLE returned $table_rc"
fi

assert_summary
