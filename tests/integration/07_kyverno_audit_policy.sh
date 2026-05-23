#!/usr/bin/env bash
# 07: Kyverno audit policy produces a PolicyReport violation for a known-bad
# resource.
#
# Creates a Deployment using the default ServiceAccount in a fresh namespace.
# Policy 05 (no-default-sa-with-workload) should mark this as a fail in the
# PolicyReport for that namespace. Asserts the report shows the violation
# within 30s.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_ns kyverno

# Confirm the policy we expect to trigger is actually installed.
if ! kubectl get clusterpolicy no-default-sa-with-workload >/dev/null 2>&1; then
  skip "ClusterPolicy 'no-default-sa-with-workload' not installed"
fi

TEST_NS="integ-kv-${RUN_ID}"

cat <<YAML | trace kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: { name: $TEST_NS, labels: { $INTEG_LABEL_KEY: "true" } }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad-sa
  namespace: $TEST_NS
  labels: { $INTEG_LABEL_KEY: "true" }
spec:
  replicas: 1
  selector: { matchLabels: { app: bad-sa } }
  template:
    metadata: { labels: { app: bad-sa } }
    spec:
      # Intentionally no serviceAccountName — should trigger policy 05.
      containers:
        - name: busybox
          image: busybox:1.36
          command: ["sleep", "3600"]
YAML

add_cleanup "kubectl delete ns $TEST_NS --wait=false"

wait_for "PolicyReport in $TEST_NS records a fail for policy 'no-default-sa-with-workload'" 60 3 -- \
  bash -c "kubectl get policyreports.wgpolicyk8s.io -n $TEST_NS -o json 2>/dev/null | jq -e '.items[].results[]? | select(.policy==\"no-default-sa-with-workload\" and .result==\"fail\")' >/dev/null"

ok "Kyverno detected and recorded the policy violation in PolicyReport"
