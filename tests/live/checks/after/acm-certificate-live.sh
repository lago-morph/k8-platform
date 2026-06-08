#!/usr/bin/env bash
# LIVE behavioral check (after tier) — a Crossplane-provisioned ACM Certificate
# is real and ISSUED.
#
# This is the BEHAVIORAL oracle for acm.aws.m.upbound.io/Certificate per
# ADR-0006: it proves the PlatformCluster abstraction actually produced a
# healthy ACM certificate, not that a manifest says so. It selects by the
# Composition's own tag (crossplane-kind=certificate.acm.aws.m.upbound.io,
# PlatformAbstraction=PlatformCluster) so a Terraform-managed cert does NOT
# count.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (list/describe/list-tags only) -- safe in
# `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="acm.aws.m.upbound.io/Certificate"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Tooling / creds preconditions -- not-applicable (skip), not a failure.
for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (ACM Certificate live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"

log "looking for a Crossplane PlatformCluster-provisioned ACM Certificate (region $REGION)"

# List all ACM certificates; for each, read its tags and select the one the
# PlatformCluster Composition stamps (crossplane-kind=certificate.acm.aws.m.upbound.io,
# PlatformAbstraction=PlatformCluster).
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

# No PlatformCluster-tagged certificate -- the kind is unprovisioned for this
# account. Return SKIP; the orchestrator promotes it to FAIL iff git declares
# the kind (expect-full).
if [ -z "$found_arn" ]; then
  skip "no ACM certificate tagged crossplane-kind=certificate.acm.aws.m.upbound.io + PlatformAbstraction=PlatformCluster (PlatformCluster abstraction has not provisioned one)"
fi

# Health check: the certificate must be ISSUED.
CERT_STATUS="$(aws acm describe-certificate --certificate-arn "$found_arn" --region "$REGION" \
  --query 'Certificate.Status' --output text 2>/dev/null)" \
  || { ng "failed to describe ACM certificate $found_arn"; exit 1; }

if [ "$CERT_STATUS" != "ISSUED" ]; then
  ng "PlatformCluster ACM certificate '$found_arn' is '$CERT_STATUS', not 'ISSUED'"
  exit 1
fi

ok "PlatformCluster-provisioned ACM certificate '$found_arn' is ISSUED"
covers "$KIND"
exit "$LIVE_RC_PASS"
