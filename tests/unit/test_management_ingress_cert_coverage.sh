#!/usr/bin/env bash
# Regression test for OI-2026-06-05-5: the management ingress NLB must present a
# TLS cert whose wildcard actually COVERS the service hostnames it serves.
#
# The bug: the ingress published argocd.management.<domain> (two labels under the
# apex) but the NLB served the base *.<domain> cert, which matches only one
# label — so the presented cert did not name-match the host. CI's `curl -sk`
# masked it; a strict TLS verifier (the sandbox egress gateway) rejected it on
# SAN and 503'd. This test is pure-static (no AWS) and fails if the ingress host
# is ever served by a cert that doesn't cover it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HELM_TF="$HERE/../../terraform/management/helm.tf"
ACM_TF="$HERE/../../terraform/management/acm-management.tf"
FAIL=0

[ -f "$HELM_TF" ] || { echo "FAIL: $HELM_TF missing"; exit 1; }
[ -f "$ACM_TF" ]  || { echo "FAIL: $ACM_TF missing (the *.management cert fix)"; exit 1; }

# 1. The ingress-nginx ssl-cert annotation must reference the management-subdomain
#    cert, NOT the base account wildcard (acm_certificate_arn from base state).
sslcert_block="$(grep -A1 'aws-load-balancer-ssl-cert"' "$HELM_TF" | grep 'value' | head -1)"
if echo "$sslcert_block" | grep -q 'local.management_acm_certificate_arn'; then
  echo "ok: ingress ssl-cert uses local.management_acm_certificate_arn"
else
  echo "FAIL: ingress ssl-cert is not the *.management cert (found: $sslcert_block)"
  echo "      a base *.<domain> wildcard does NOT cover <svc>.management.<domain>"; FAIL=1
fi
if echo "$sslcert_block" | grep -q 'outputs.acm_certificate_arn'; then
  echo "FAIL: ingress ssl-cert still points at the base *.<domain> wildcard (the bug)"; FAIL=1
fi

# 2. The management cert must be the management-subdomain wildcard.
cert_domain="$(grep -E '^\s*domain_name\s*=' "$ACM_TF" | head -1 | sed -E 's/.*=\s*"([^"]+)".*/\1/')"
if [ "$cert_domain" = '*.management.${var.domain}' ]; then
  echo "ok: management cert domain is *.management.\${var.domain}"
else
  echo "FAIL: management cert domain is '$cert_domain', want '*.management.\${var.domain}'"; FAIL=1
fi

# 3. Coverage check: every management ingress hostname must be exactly ONE label
#    under the cert's wildcard base (management.<domain>) — i.e. matchable by
#    *.management.<domain>. Extract every server.ingress.hostname literal.
hosts="$(grep -A1 'server.ingress.hostname\|alpha.kubernetes.io/hostname' "$HELM_TF" \
          | grep 'value' | sed -E 's/.*=\s*"([^"]+)".*/\1/' | sort -u)"
[ -n "$hosts" ] || { echo "FAIL: could not extract any management ingress hostname"; FAIL=1; }
while IFS= read -r host; do
  [ -z "$host" ] && continue
  # Must be: <single-label>.management.${var.domain}
  if echo "$host" | grep -qE '^[a-z0-9-]+\.management\.\$\{var\.domain\}$'; then
    echo "ok: host '$host' is one label under management.<domain> (covered by *.management.<domain>)"
  else
    echo "FAIL: host '$host' is NOT a single label under management.<domain> —"
    echo "      *.management.<domain> would not cover it (wildcard matches one label)"; FAIL=1
  fi
done <<< "$hosts"

# 4. The cert must be DNS-validated and gated (the ingress should consume the
#    *_validation resource so the cert is ISSUED before the NLB listener exists).
if grep -q 'aws_acm_certificate_validation" "management"' "$ACM_TF" \
   && grep -q 'aws_acm_certificate_validation.management.certificate_arn' "$ACM_TF"; then
  echo "ok: cert is DNS-validated and the ARN is gated on validation"
else
  echo "FAIL: management cert must use aws_acm_certificate_validation (ISSUED before NLB)"; FAIL=1
fi

[ "$FAIL" -eq 0 ] && echo "PASS: management ingress cert covers its hostnames" || echo "FAILED"
exit "$FAIL"
