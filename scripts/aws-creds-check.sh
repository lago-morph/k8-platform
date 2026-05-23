#!/usr/bin/env bash
# Verify AWS creds reach STS and that the account prerequisites are present
# (Route53 zone, etc.). Run this first when picking up a new session; if it
# fails, no other script in this directory will work.

set -uo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,5p' "$0"; exit 0
fi

echo "── sts: who am I? ─────────────────────────────────────────────────"
if ! aws sts get-caller-identity 2>&1 | sed 's/^/  /'; then
  echo ""
  echo "STS call failed. Likely causes:"
  echo "  - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY not set"
  echo "  - Credentials revoked or rotated"
  exit 1
fi

echo ""
echo "── region ─────────────────────────────────────────────────────────"
echo "  AWS_REGION=${AWS_REGION:-(unset)}"
echo "  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-(unset)}"
[ -n "${AWS_REGION:-}${AWS_DEFAULT_REGION:-}" ] || \
  echo "  WARN: no region set — tools may default to us-east-1 silently."

echo ""
echo "── hosted zone discovery ──────────────────────────────────────────"
ZONES=$(aws route53 list-hosted-zones --query 'HostedZones[*].{Name:Name,Id:Id}' --output json 2>/dev/null)
COUNT=$(echo "$ZONES" | jq 'length')
echo "  found $COUNT hosted zone(s)"
echo "$ZONES" | jq -r '.[] | "  - \(.Name)  (\(.Id))"'
if [ "$COUNT" -ne 1 ]; then
  echo "  WARN: expected exactly 1 zone. CI auto-picks the first."
fi

echo ""
echo "── EKS cluster (if any) ───────────────────────────────────────────"
CLUSTERS=$(aws eks list-clusters --output json 2>/dev/null | jq -r '.clusters[]?')
if [ -z "$CLUSTERS" ]; then
  echo "  (no EKS clusters in this account yet)"
else
  echo "$CLUSTERS" | sed 's/^/  - /'
fi

echo ""
echo "── S3 state buckets ───────────────────────────────────────────────"
aws s3 ls 2>/dev/null | grep -E 'k8-platform|tfstate' | sed 's/^/  /' || \
  echo "  (no state buckets found)"
