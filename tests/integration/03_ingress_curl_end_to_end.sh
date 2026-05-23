#!/usr/bin/env bash
# 03: NLB → nginx → backend HTTP round-trip.
#
# Deploys a tiny echo server, exposes it via Ingress + external-dns hostname,
# waits for DNS + Route53, then curls the public URL and asserts a 200
# from the echo server (proves TLS terminates at the NLB, nginx routes by
# Host header, and the backend pod receives traffic).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws
require_ns ingress-nginx
require_ns external-dns

DOMAIN=$(discover_domain)
ZONE_ID=$(discover_zone_id)
HOST="integ-echo-${RUN_ID}.management.${DOMAIN}"
TEST_NS="integ-${RUN_ID}"

cat <<YAML | trace kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $TEST_NS
  labels: { $INTEG_LABEL_KEY: "true" }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: $TEST_NS
  labels: { $INTEG_LABEL_KEY: "true" }
spec:
  replicas: 1
  selector: { matchLabels: { app: echo } }
  template:
    metadata: { labels: { app: echo } }
    spec:
      serviceAccountName: default  # tolerated; policy will audit
      containers:
        - name: echo
          image: ealen/echo-server:0.9.2
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: $TEST_NS
spec:
  selector: { app: echo }
  ports: [{ port: 80, targetPort: 80 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo
  namespace: $TEST_NS
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
              service: { name: echo, port: { number: 80 } }
YAML

add_cleanup "kubectl delete ns $TEST_NS --wait=false"

wait_for "echo pod Running" 90 3 -- \
  bash -c "kubectl get pods -n $TEST_NS -l app=echo --no-headers 2>/dev/null | grep -q ' Running '"

wait_for "Route53 record for $HOST" 180 5 -- \
  bash -c "aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID --query \"ResourceRecordSets[?Name=='${HOST}.']\" --output text | grep -q ."

# Even after Route53 has the record, the NLB target group may need a minute
# to register the new nginx endpoint. Retry the curl.
wait_for "curl https://$HOST returns 200" 180 6 -- \
  bash -c "curl -sk -o /dev/null -w '%{http_code}' --max-time 10 'https://$HOST' | grep -q '^200$'"

ok "End-to-end: NLB → nginx → echo round-tripped over HTTPS"
