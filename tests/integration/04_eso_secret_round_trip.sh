#!/usr/bin/env bash
# 04: Secrets Manager → ESO → Kubernetes Secret round-trip.
#
# Creates a Secrets Manager entry under the project prefix, declares a
# ClusterSecretStore + ExternalSecret, waits for the k8s Secret to
# materialize with the expected value. Deletes the SM secret on teardown.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws
require_ns external-secrets

REGION="${AWS_REGION:-us-east-1}"
SM_NAME="k8-platform/integ-${RUN_ID}"
SM_VALUE="hello-from-integ-${RUN_ID}"
STORE="integ-store-${RUN_ID}"
ES="integ-es-${RUN_ID}"
TEST_NS="integ-${RUN_ID}"

trace aws secretsmanager create-secret \
  --name "$SM_NAME" \
  --secret-string "$SM_VALUE" \
  --region "$REGION" >/dev/null

add_cleanup "aws secretsmanager delete-secret --secret-id $SM_NAME --force-delete-without-recovery --region $REGION"

cat <<YAML | trace kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: { name: $TEST_NS, labels: { $INTEG_LABEL_KEY: "true" } }
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: $STORE
  labels: { $INTEG_LABEL_KEY: "true" }
spec:
  provider:
    aws:
      service: SecretsManager
      region: $REGION
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: $ES
  namespace: $TEST_NS
spec:
  refreshInterval: 30s
  secretStoreRef:
    name: $STORE
    kind: ClusterSecretStore
  target:
    name: integ-secret
    creationPolicy: Owner
  data:
    - secretKey: greeting
      remoteRef: { key: "$SM_NAME" }
YAML

add_cleanup "kubectl delete clustersecretstore $STORE --wait=false"
add_cleanup "kubectl delete ns $TEST_NS --wait=false"

wait_for "ExternalSecret $ES becomes Ready" 90 3 -- \
  bash -c "kubectl get externalsecret -n $TEST_NS $ES -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"

wait_for "k8s Secret integ-secret materialized" 30 2 -- \
  bash -c "kubectl get secret -n $TEST_NS integ-secret -o jsonpath='{.data.greeting}' 2>/dev/null | grep -q ."

GOT=$(kubectl get secret -n $TEST_NS integ-secret -o jsonpath='{.data.greeting}' | base64 -d)
if [ "$GOT" = "$SM_VALUE" ]; then
  ok "ESO synced Secrets Manager → k8s Secret correctly (\"$GOT\")"
else
  ng "synced value mismatch: got=$GOT want=$SM_VALUE"
fi
