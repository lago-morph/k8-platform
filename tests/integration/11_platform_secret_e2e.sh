#!/usr/bin/env bash
# 11: PlatformSecret XRD end-to-end on the live management cluster.
#
# Verifies REQ-XP-01 / REQ-XP-04 against the real management cluster:
# applying a PlatformSecret claim provisions a real ASM secret AND an
# ExternalSecret AND ESO syncs a value out of ASM into a K8s Secret.
# Complements tests/chainsaw/platform-secret/ which exercises the same
# flow in a kind cluster — this test catches the things only the real
# cluster can show (live IRSA, real ESO sync timing, real ASM
# eventual-consistency on first read).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws

# Phase-2 resources only land once the bootstrap App syncs argocd/.
# Skip cleanly if the XRD isn't on the cluster — that's a phase-2
# pre-condition, not this test's failure.
if ! kubectl get crd platformsecrets.platform.k8-platform.io >/dev/null 2>&1; then
  skip "PlatformSecret CRD not present (phase 2 not synced yet?)"
fi

if ! kubectl get clustersecretstore aws-secrets-manager \
     -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
     | grep -q True; then
  skip "ClusterSecretStore aws-secrets-manager not Ready"
fi

CLAIM="integ-platsec-${RUN_ID}"
TEST_NS="integ-${RUN_ID}"
REGION="${AWS_REGION:-us-east-1}"
EXPECTED_VALUE="hello-from-integration-${RUN_ID}"

# Pre-create the test namespace + ensure the namespace allowlist policy
# from policies/audit/09 doesn't block claim apply. The namespace label
# `test.k8-platform/integration: true` matches the integration-test
# cleanup selector at the top of run.sh.
trace kubectl create ns "$TEST_NS" --dry-run=client -o yaml \
  | kubectl label --local -f - test.k8-platform/integration=true -o yaml \
  | kubectl apply -f -

# Cleanup runs even if the test fails. Order matters — claim first so
# its finalizers can drive ASM teardown, then ns.
add_cleanup "kubectl delete platformsecret -n $TEST_NS $CLAIM --wait=true --timeout=120s || true"
add_cleanup "kubectl delete ns $TEST_NS --wait=false || true"

# The 09 audit policy restricts to platform/apps/default. Override the
# allowlist for the integration-test namespace via a one-off label.
# (If the policy were Enforce we'd need a wider mechanism; in Audit
# mode it just records a violation we tolerate for the test.)

# ---- 1. Apply claim ------------------------------------------------------
note "applying PlatformSecret claim $CLAIM"
cat <<YAML | trace kubectl apply -f -
apiVersion: platform.k8-platform.io/v1alpha1
kind: PlatformSecret
metadata:
  name: $CLAIM
  namespace: $TEST_NS
  labels:
    test.k8-platform/integration: "true"
spec:
  refreshInterval: 10s
  region: $REGION
  description: "integration test 11 — e2e claim from $RUN_ID"
YAML

# ---- 2. Wait for claim Ready --------------------------------------------
wait_for "PlatformSecret/$CLAIM Ready=True" 180 5 -- \
  bash -c "kubectl get platformsecret -n $TEST_NS $CLAIM -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"

# ---- 3. Resolve the ASM key from the composite UID ----------------------
XR=$(kubectl get platformsecret -n "$TEST_NS" "$CLAIM" -o jsonpath='{.spec.resourceRef.name}')
[ -n "$XR" ] || ng "could not find composite XR name for claim"
UID=$(kubectl get xplatformsecret "$XR" -o jsonpath='{.metadata.uid}')
[ -n "$UID" ] || ng "could not find XR uid for $XR"
ASM_KEY="k8-platform/${UID}"
log "ASM key: $ASM_KEY"

# ---- 4. Verify ASM secret exists in AWS ----------------------------------
wait_for "ASM secret $ASM_KEY exists" 60 5 -- \
  bash -c "aws secretsmanager describe-secret --secret-id '$ASM_KEY' --region '$REGION' >/dev/null 2>&1"
ok "ASM secret $ASM_KEY exists"

# ---- 5. Put a real value into ASM (Composition only creates the shell) --
trace aws secretsmanager put-secret-value \
  --secret-id "$ASM_KEY" \
  --secret-string "{\"greeting\":\"$EXPECTED_VALUE\"}" \
  --region "$REGION" >/dev/null

# ---- 6. Wait for ESO to materialize the K8s Secret -----------------------
wait_for "K8s Secret $CLAIM materialized in $TEST_NS" 120 5 -- \
  bash -c "kubectl get secret -n $TEST_NS $CLAIM -o jsonpath='{.data.greeting}' 2>/dev/null | grep -q ."

ACTUAL_B64=$(kubectl get secret -n "$TEST_NS" "$CLAIM" -o jsonpath='{.data.greeting}')
ACTUAL=$(printf '%s' "$ACTUAL_B64" | base64 -d 2>/dev/null || echo "<decode-failed>")
if [ "$ACTUAL" = "$EXPECTED_VALUE" ]; then
  ok "K8s Secret greeting key matches the value put into ASM"
else
  ng "expected '$EXPECTED_VALUE', got '$ACTUAL'"
fi

# ---- 7. Rotate value, assert ESO refreshes within refreshInterval -------
ROTATED="rotated-${RUN_ID}"
trace aws secretsmanager put-secret-value \
  --secret-id "$ASM_KEY" \
  --secret-string "{\"greeting\":\"$ROTATED\"}" \
  --region "$REGION" >/dev/null

wait_for "K8s Secret reflects rotated ASM value (refreshInterval=10s)" 60 3 -- \
  bash -c "kubectl get secret -n $TEST_NS $CLAIM -o jsonpath='{.data.greeting}' | base64 -d 2>/dev/null | grep -q '^$ROTATED\$'"
ok "ESO refresh path works on the live cluster"

# ---- 8. Delete claim, verify cleanup ------------------------------------
trace kubectl delete platformsecret -n "$TEST_NS" "$CLAIM" --wait=true --timeout=120s

wait_for "K8s Secret $CLAIM removed after claim delete" 60 3 -- \
  bash -c "! kubectl get secret -n $TEST_NS $CLAIM >/dev/null 2>&1"

wait_for "ExternalSecret $CLAIM removed after claim delete" 60 3 -- \
  bash -c "! kubectl get externalsecret -n $TEST_NS $CLAIM >/dev/null 2>&1"

# ASM secret should be gone too (recoveryWindowInDays=0 in Composition).
wait_for "ASM secret $ASM_KEY gone (recoveryWindowInDays=0)" 60 3 -- \
  bash -c "! aws secretsmanager describe-secret --secret-id '$ASM_KEY' --region '$REGION' >/dev/null 2>&1"

ok "PlatformSecret end-to-end: apply → ASM + K8s Secret → rotation → delete"
