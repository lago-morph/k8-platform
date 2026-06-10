#!/usr/bin/env bash
# LIVE behavioral check (after tier) — a Crossplane-provisioned Route53 Record
# actually wrote the DNS validation record for the PlatformCluster ACM cert.
#
# This is the BEHAVIORAL oracle for route53.aws.m.upbound.io/Record per
# ADR-0006: it proves the Composition's Route53 Record MR actually committed a
# real DNS record to the hosted zone — a Terraform lookalike would NOT have
# created the crossplane-stamped cert, so selection via that cert's own
# crossplane tag is the indirect stamp that excludes it.
#
# Route53 records cannot be AWS-tagged, so we select INDIRECTLY:
#   1. Find the crossplane ACM cert tagged crossplane-kind=certificate.acm.aws.m.upbound.io
#   2. Read the cert's DomainValidationOptions to get the expected validation
#      CNAME name+value (the record the Composition's Record MR should write).
#   3. Discover the hosted zone by suffix-matching the validation record name.
#   4. Assert the CNAME exists in the zone and the value matches.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (list/describe only) -- safe in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="route53.aws.m.upbound.io/Record"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (Route53 record live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for Crossplane PlatformCluster ACM cert (crossplane-kind=certificate.acm.aws.m.upbound.io)"

# Step 1: Find the crossplane-stamped ACM cert.
CERT_LIST="$(aws acm list-certificates --region "$REGION" \
  --query 'CertificateSummaryList[].CertificateArn' \
  --output json 2>/dev/null)" || skip "acm:ListCertificates not permitted / unavailable here"

COUNT="$(printf '%s' "$CERT_LIST" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no ACM certificates in the account (PlatformCluster path not provisioned)"

cert_arn=""
while IFS= read -r arn; do
  [ -z "$arn" ] && continue
  tags="$(aws acm list-tags-for-certificate --certificate-arn "$arn" --region "$REGION" \
           --query 'Tags' --output json 2>/dev/null)" || continue
  is_crossplane="$(printf '%s' "$tags" | jq -r '
    (map({(.Key): .Value}) | add) as $t
    | if ($t["crossplane-kind"] == "certificate.acm.aws.m.upbound.io") then "yes" else "no" end')"
  if [ "$is_crossplane" = "yes" ]; then
    cert_arn="$arn"
    break
  fi
done <<EOF
$(printf '%s' "$CERT_LIST" | jq -r '.[]')
EOF

if [ -z "$cert_arn" ]; then
  skip "no ACM certificate tagged crossplane-kind=certificate.acm.aws.m.upbound.io (PlatformCluster cert not provisioned)"
fi

log "found crossplane ACM cert: $cert_arn"

# Step 2: Read the validation record from the cert.
CERT_DETAIL="$(aws acm describe-certificate --certificate-arn "$cert_arn" --region "$REGION" \
  --output json 2>/dev/null)" || skip "acm:DescribeCertificate not permitted for $cert_arn"

EXPECTED_NAME="$(printf '%s' "$CERT_DETAIL" | jq -r '
  .Certificate.DomainValidationOptions[]
  | select(.ResourceRecord != null)
  | .ResourceRecord.Name' | head -1)"

EXPECTED_VALUE="$(printf '%s' "$CERT_DETAIL" | jq -r '
  .Certificate.DomainValidationOptions[]
  | select(.ResourceRecord != null)
  | .ResourceRecord.Value' | head -1)"

EXPECTED_TYPE="$(printf '%s' "$CERT_DETAIL" | jq -r '
  .Certificate.DomainValidationOptions[]
  | select(.ResourceRecord != null)
  | .ResourceRecord.Type' | head -1)"

if [ -z "$EXPECTED_NAME" ] || [ "$EXPECTED_NAME" = "null" ]; then
  skip "ACM cert $cert_arn has no ResourceRecord yet (validation record not emitted -- cert pending)"
fi

log "expected DNS validation record: $EXPECTED_TYPE $EXPECTED_NAME -> $EXPECTED_VALUE"

# Step 3: Discover the hosted zone by suffix-matching the validation record name.
# Strip the trailing dot from EXPECTED_NAME for matching, then find a zone whose
# Name (with trailing dot) is a suffix of the record name.
ZONES="$(aws route53 list-hosted-zones --output json 2>/dev/null \
  --query 'HostedZones[].{id:Id,name:Name}')" || skip "route53:ListHostedZones not permitted / unavailable here"

zone_id=""
while IFS= read -r row; do
  [ -z "$row" ] && continue
  zname="$(printf '%s' "$row" | jq -r '.name')"   # e.g. "<account-id>.realhandsonlabs.net."
  zid_raw="$(printf '%s' "$row" | jq -r '.id')"   # e.g. "/hostedzone/Z0427196330MCUVARWMSF"
  zid="${zid_raw##*/}"                             # strip /hostedzone/ prefix

  # The validation record name ends with a dot; the zone name also ends with dot.
  # Check that EXPECTED_NAME ends with the zone name (suffix match).
  case "$EXPECTED_NAME" in
    *"${zname}") zone_id="$zid"; break ;;
  esac
done <<EOF
$(printf '%s' "$ZONES" | jq -c '.[]')
EOF

if [ -z "$zone_id" ]; then
  skip "no hosted zone whose name is a suffix of the validation record '$EXPECTED_NAME' (zone not present in account)"
fi

log "matched hosted zone: $zone_id -- querying record sets"

# Step 4: Assert the CNAME record exists and its value matches.
RECORD_SETS="$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
  --output json 2>/dev/null)" || skip "route53:ListResourceRecordSets not permitted for zone $zone_id"

# Find the record whose Name matches EXPECTED_NAME and whose type matches EXPECTED_TYPE.
MATCH="$(printf '%s' "$RECORD_SETS" | jq -r --arg name "$EXPECTED_NAME" --arg type "$EXPECTED_TYPE" '
  .ResourceRecordSets[]
  | select(.Name == $name and .Type == $type)
  | .ResourceRecords[].Value')"

if [ -z "$MATCH" ]; then
  ng "Route53 zone $zone_id has no $EXPECTED_TYPE record matching name '$EXPECTED_NAME' (Record MR did not write the DNS record)"
  exit 1
fi

if [ "$MATCH" != "$EXPECTED_VALUE" ]; then
  ng "Route53 record '$EXPECTED_NAME' value '$MATCH' does not match expected '$EXPECTED_VALUE' (Record MR wrote wrong value)"
  exit 1
fi

ok "Route53 $EXPECTED_TYPE record '$EXPECTED_NAME' matches expected ACM validation value in zone $zone_id"
covers "$KIND"
exit "$LIVE_RC_PASS"
