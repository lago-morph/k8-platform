#!/usr/bin/env bash
# List record sets in the account's hosted zone (discovered the same way
# CI discovers it). Useful for confirming ExternalDNS is reconciling and
# spotting stale records.
# Usage: scripts/route53-records.sh

set -uo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,5p' "$0"; exit 0
fi

ZONE_JSON=$(aws route53 list-hosted-zones --query 'HostedZones[0]' --output json 2>/dev/null)
if [ -z "$ZONE_JSON" ] || [ "$ZONE_JSON" = "null" ]; then
  echo "no hosted zone found in this account" >&2
  exit 1
fi

ZONE_ID=$(echo "$ZONE_JSON" | jq -r '.Id' | sed 's@^/hostedzone/@@')
ZONE_NAME=$(echo "$ZONE_JSON" | jq -r '.Name' | sed 's/\.$//')

echo "── zone $ZONE_NAME ($ZONE_ID) ──────────────────────────────────────"
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query 'ResourceRecordSets[*].{Name:Name,Type:Type,TTL:TTL,Target:(AliasTarget.DNSName || ResourceRecords[0].Value)}' \
  --output table 2>&1 | sed 's/^/  /'
