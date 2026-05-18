#!/usr/bin/env bash
# E2E: confirm AWS credentials are present and active. Read-only,
# uses sts:GetCallerIdentity which has no IAM cost.

set -uo pipefail
cd "$(dirname "$0")/../.."

. tests/lib/assert.sh

echo "── e2e: aws credentials ──────────────────────────────────────"

if ! command -v aws >/dev/null 2>&1; then
  _fail "aws CLI installed" "aws binary not on PATH"
  assert_summary
  exit 1
fi

set +e
output=$(aws sts get-caller-identity --output json 2>&1)
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  _fail "sts:GetCallerIdentity succeeds" "$output"
  assert_summary
  exit 1
fi

account=$(echo "$output" | jq -r '.Account // empty')
arn=$(echo "$output"     | jq -r '.Arn // empty')

[ -n "$account" ] && _pass "Account ID returned ($account)" || _fail "Account ID returned" "$output"
[ -n "$arn" ]     && _pass "Caller ARN returned ($arn)"     || _fail "Caller ARN returned"  "$output"

# Region must be set; the workflow exports AWS_DEFAULT_REGION from secrets.
if [ -n "${AWS_DEFAULT_REGION:-${AWS_REGION:-}}" ]; then
  _pass "AWS region is set"
else
  _fail "AWS region is set" "neither AWS_DEFAULT_REGION nor AWS_REGION exported"
fi

assert_summary
