#!/usr/bin/env bash
# 09: Second app behind a different hostname — full DNS + HTTP path.
#
# This is a near-duplicate of test 03, but on a different hostname and in
# a different namespace, to confirm ExternalDNS and ingress-nginx handle
# multiple consumers (not just argocd-server). Catches the failure mode
# where domainFilter or txtOwnerId is set such that only the bootstrap
# ingress is reconciled.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws
require_ns ingress-nginx
require_ns external-dns

DOMAIN=$(discover_domain)
ZONE_ID=$(discover_zone_id)
HOST="integ-second-${RUN_ID}.management.${DOMAIN}"
TEST_NS="integ-second-${RUN_ID}"

cat <<YAML | trace kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: { name: $TEST_NS, labels: { $INTEG_LABEL_KEY: "true" } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: hello, namespace: $TEST_NS }
spec:
  replicas: 1
  selector: { matchLabels: { app: hello } }
  template:
    metadata: { labels: { app: hello } }
    spec:
      containers:
        - name: hello
          image: hashicorp/http-echo:1.0
          args: ["-text=hello-from-${RUN_ID}", "-listen=:8080"]
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata: { name: hello, namespace: $TEST_NS }
spec:
  selector: { app: hello }
  ports: [{ port: 80, targetPort: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
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
            backend: { service: { name: hello, port: { number: 80 } } }
YAML

add_cleanup "kubectl delete ns $TEST_NS --wait=false"

wait_for "hello pod Running" 60 3 -- \
  bash -c "kubectl get pods -n $TEST_NS -l app=hello --no-headers 2>/dev/null | grep -q ' Running '"

wait_for "Route53 record for $HOST" 180 5 -- \
  bash -c "aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID --query \"ResourceRecordSets[?Name=='${HOST}.']\" --output text | grep -q ."

wait_for "curl https://$HOST returns expected body" 180 6 -- \
  bash -c "curl -sk --max-time 10 'https://$HOST' | grep -q 'hello-from-${RUN_ID}'"

ok "Secondary ingress round-tripped: NLB → nginx → http-echo on $HOST"
