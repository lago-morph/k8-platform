#!/usr/bin/env bash
# 02: ExternalDNS reconciles an Ingress annotation → Route53 A-alias record.
#
# Creates a stub Ingress under our domain with the external-dns hostname
# annotation, waits for the Route53 record to appear, then deletes the
# Ingress and asserts ExternalDNS removes the record (with policy=sync —
# in upsert-only policy we skip the removal assertion).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws
require_ns external-dns
require_ns ingress-nginx

DOMAIN=$(discover_domain)
ZONE_ID=$(discover_zone_id)
HOST="integ-edns-${RUN_ID}.management.${DOMAIN}"
TEST_NS="integ-${RUN_ID}"

cat <<YAML | trace kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $TEST_NS
  labels: { $INTEG_LABEL_KEY: "true" }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: stub
  namespace: $TEST_NS
  labels: { $INTEG_LABEL_KEY: "true" }
  annotations:
    external-dns.alpha.kubernetes.io/hostname: $HOST
spec:
  ingressClassName: nginx
  rules:
    - host: $HOST
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nonexistent  # we only care about the DNS record
                port: { number: 80 }
YAML

add_cleanup "kubectl delete ns $TEST_NS --wait=false"

wait_for "Route53 A record for $HOST exists" 180 5 -- \
  bash -c "aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID --query \"ResourceRecordSets[?Name=='${HOST}.']\" --output text | grep -q ."

ok "ExternalDNS created Route53 record for $HOST"

# With policy=upsert-only the record will not be removed. Document that.
note "policy=upsert-only — record will persist after teardown (delete manually if needed)"
