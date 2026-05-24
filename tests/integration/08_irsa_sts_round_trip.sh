#!/usr/bin/env bash
# 08: IRSA assume-role round-trip from inside a pod.
#
# Creates a SA annotated with an IRSA role ARN, runs a one-shot pod using
# the official aws-cli image with that SA, calls sts:GetCallerIdentity, and
# asserts the assumed-role ARN matches the expected role. Catches IRSA
# binding regressions silently — a pod with a bad SA → role mapping will
# fall back to no AWS auth at all.
#
# Uses the existing external-dns IRSA role (no extra IAM setup needed for
# the test itself; the test only needs to PROVE it assumes the role, not
# do real work with it). The pod runs in a fresh namespace so the SA
# matches the role's namespace_service_accounts entry.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws

# Look up the IRSA role ARN from the existing SA in external-dns.
ROLE_ARN=$(kubectl get sa -n external-dns external-dns \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
if [ -z "$ROLE_ARN" ]; then
  skip "external-dns SA missing IRSA annotation — phase 1 not deployed"
fi

POD="integ-irsa-${RUN_ID}"

# Pod runs in the external-dns namespace using the existing SA — that's the
# only valid (sa,namespace) pair for this role under the trust policy.
cat <<YAML | trace kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: external-dns
  labels: { $INTEG_LABEL_KEY: "true" }
spec:
  serviceAccountName: external-dns
  restartPolicy: Never
  containers:
    - name: awscli
      image: amazon/aws-cli:2.15.27
      command: ["aws", "sts", "get-caller-identity", "--output", "json"]
YAML

add_cleanup "kubectl delete pod -n external-dns $POD --wait=false"

wait_for "pod $POD completes" 90 3 -- \
  bash -c "kubectl get pod -n external-dns $POD -o jsonpath='{.status.phase}' 2>/dev/null | grep -qE '^(Succeeded|Failed)$'"

PHASE=$(kubectl get pod -n external-dns $POD -o jsonpath='{.status.phase}')
if [ "$PHASE" != "Succeeded" ]; then
  ng "pod $POD finished in phase=$PHASE — see logs:"
  kubectl logs -n external-dns "$POD" || true
  exit 1
fi

OUT=$(kubectl logs -n external-dns "$POD")
ASSUMED=$(echo "$OUT" | jq -r .Arn)

# The assumed-role ARN looks like:
# arn:aws:sts::ACCT:assumed-role/k8-platform-mgmt-external-dns/<sessionname>
# The role name embedded in it should match the basename of $ROLE_ARN.
ROLE_NAME="${ROLE_ARN##*/}"
if echo "$ASSUMED" | grep -q ":assumed-role/${ROLE_NAME}/"; then
  ok "Pod assumed IRSA role $ROLE_NAME via STS"
else
  ng "expected assumed-role/$ROLE_NAME, got: $ASSUMED"
fi
