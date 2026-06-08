#!/usr/bin/env bash
# LIVE behavioral check (after tier) -- a Crossplane-provisioned ACM
# CertificateValidation has driven DNS validation to completion.
#
# This is the BEHAVIORAL oracle for acm.aws.m.upbound.io/CertificateValidation
# per ADR-0006. CertificateValidation has NO standalone AWS object; its effect
# is that the gated Certificate completed DNS validation and reached ISSUED.
#
# Behavioral oracle: find the PlatformCluster-stamped ACM Certificate
# (crossplane-kind=certificate.acm.aws.m.upbound.io, PlatformAbstraction=PlatformCluster)
# and assert:
#   1. Certificate.Status == "ISSUED"
#   2. Every DomainValidationOption has ValidationMethod == "DNS"
#   3. Every DomainValidationOption has ValidationStatus == "SUCCESS"
#
# This proves the CertificateValidation MR actually drove DNS validation to
# completion -- a Terraform-managed cert cannot satisfy the crossplane-kind tag.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (list/describe/list-tags only) -- safe in
# `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="acm.aws.m.upbound.io/CertificateValidation"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (ACM CertificateValidation live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for a Crossplane PlatformCluster-provisioned ACM Certificate to verify DNS validation (region $REGION)"

# List all ACM certificates; select the PlatformCluster-stamped one
# (crossplane-kind=certificate.acm.aws.m.upbound.io).
CERTS_JSON="$(aws acm list-certificates --region "$REGION" \
  --query 'CertificateSummaryList[].CertificateArn' \
  --output json 2>/dev/null)" || skip "acm:ListCertificates not permitted / unavailable here"

COUNT="$(printf '%s' "$CERTS_JSON" | jq 'length')"
[ "${COUNT:-0}" -gt 0 ] || skip "no ACM certificates in the account (PlatformCluster path not provisioned)"

found_arn=""
while IFS= read -r arn; do
  [ -z "$arn" ] && continue
  tags="$(aws acm list-tags-for-certificate --certificate-arn "$arn" --region "$REGION" \
            --query 'Tags' --output json 2>/dev/null)" || continue
  is_xpc="$(printf '%s' "$tags" | jq -r '
    (map({(.Key): .Value}) | add) as $t
    | if ($t["crossplane-kind"] == "certificate.acm.aws.m.upbound.io"
          and $t["PlatformAbstraction"] == "PlatformCluster")
      then "yes" else "no" end')"
  if [ "$is_xpc" = "yes" ]; then
    found_arn="$arn"
    break
  fi
done <<EOF
$(printf '%s' "$CERTS_JSON" | jq -r '.[]')
EOF

# No PlatformCluster-tagged certificate -- CertificateValidation cannot have
# fired either. Return SKIP; the orchestrator promotes to FAIL iff git
# declares the kind (expect-full).
if [ -z "$found_arn" ]; then
  skip "no ACM certificate tagged crossplane-kind=certificate.acm.aws.m.upbound.io + PlatformAbstraction=PlatformCluster (CertificateValidation effect is unverifiable -- Certificate absent)"
fi

# Fetch the full certificate details.
CERT_JSON="$(aws acm describe-certificate --certificate-arn "$found_arn" --region "$REGION" \
  --query 'Certificate' --output json 2>/dev/null)" \
  || { ng "failed to describe ACM certificate $found_arn"; exit 1; }

# Assert 1: Status must be ISSUED.
CERT_STATUS="$(printf '%s' "$CERT_JSON" | jq -r '.Status')"
if [ "$CERT_STATUS" != "ISSUED" ]; then
  ng "PlatformCluster ACM certificate '$found_arn' status is '$CERT_STATUS', not 'ISSUED' -- CertificateValidation did not complete"
  exit 1
fi

# Assert 2 & 3: Every DomainValidationOption must use DNS and show SUCCESS.
VALIDATION_CHECK="$(printf '%s' "$CERT_JSON" | jq -r '
  .DomainValidationOptions // []
  | if length == 0 then "no-options"
    elif all(.ValidationMethod == "DNS") then
      if all(.ValidationStatus == "SUCCESS") then "ok"
      else "not-success"
      end
    else "not-dns"
    end')"

case "$VALIDATION_CHECK" in
  ok)
    ;;
  no-options)
    ng "ACM certificate '$found_arn' has no DomainValidationOptions -- cannot confirm CertificateValidation drove DNS validation"
    exit 1
    ;;
  not-dns)
    ng "ACM certificate '$found_arn' has DomainValidationOptions not using DNS method -- CertificateValidation oracle mismatch"
    exit 1
    ;;
  not-success)
    ng "ACM certificate '$found_arn' has DomainValidationOptions where ValidationStatus != SUCCESS -- CertificateValidation did not complete"
    exit 1
    ;;
  *)
    ng "ACM certificate '$found_arn' DomainValidationOptions check returned unexpected result: $VALIDATION_CHECK"
    exit 1
    ;;
esac

ok "PlatformCluster ACM certificate '$found_arn' is ISSUED with all DNS DomainValidationOptions SUCCESS -- CertificateValidation completed"
covers "$KIND"
exit "$LIVE_RC_PASS"
