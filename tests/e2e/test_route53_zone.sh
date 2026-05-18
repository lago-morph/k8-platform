#!/usr/bin/env bash
# E2E: confirm the sandbox account has a pre-created public Route53
# hosted zone (the workflow's Discover Route53 zone step depends on this).

set -uo pipefail
cd "$(dirname "$0")/../.."

. tests/lib/assert.sh

echo "── e2e: route53 hosted zone discovery ────────────────────────"

set +e
zone_json=$(aws route53 list-hosted-zones \
  --query 'HostedZones[?Config.PrivateZone==`false`] | [0]' \
  --output json 2>&1)
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  _fail "list-hosted-zones succeeds" "$zone_json"
  assert_summary
  exit 1
fi

if [ "$zone_json" = "null" ] || [ -z "$zone_json" ]; then
  _fail "at least one public zone exists" "list returned null"
  assert_summary
  exit 1
fi
_pass "at least one public zone exists"

zone_id=$(echo "$zone_json" | jq -r '.Id // empty')
zone_name=$(echo "$zone_json" | jq -r '.Name // empty')

[ -n "$zone_id" ]   && _pass "zone has Id ($zone_id)"     || _fail "zone has Id"   "$zone_json"
[ -n "$zone_name" ] && _pass "zone has Name ($zone_name)" || _fail "zone has Name" "$zone_json"

# Zone must be reachable — describe must succeed.
clean_id="${zone_id#/hostedzone/}"
set +e
aws route53 get-hosted-zone --id "$clean_id" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  _pass "zone is reachable via get-hosted-zone"
else
  _fail "zone is reachable via get-hosted-zone" "get-hosted-zone returned $rc"
fi

assert_summary
