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

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_aws

# Phase-2 resources only land once the bootstrap App syncs argocd/.
# Skip cleanly if the XR CRD isn't on the cluster — that's a phase-2
# pre-condition, not this test's failure. In Crossplane v2 the claim
# CRD `platformsecrets.platform.k8-platform.io` is replaced by the XR
# CRD `xplatformsecrets.platform.k8-platform.io` (the user-facing
# namespaced kind).
if ! kubectl get crd xplatformsecrets.platform.k8-platform.io >/dev/null 2>&1; then
  skip "XPlatformSecret CRD not present (phase 2 not synced yet?)"
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

# Cleanup runs even if the test fails. Order matters — XR first so
# its finalizers can drive ASM teardown, then ns.
add_cleanup "kubectl delete xplatformsecret -n $TEST_NS $CLAIM --wait=true --timeout=120s || true"
add_cleanup "kubectl delete ns $TEST_NS --wait=false || true"

# The 09 audit policy restricts to platform/apps/default. Override the
# allowlist for the integration-test namespace via a one-off label.
# (If the policy were Enforce we'd need a wider mechanism; in Audit
# mode it just records a violation we tolerate for the test.)

# ---- 1. Apply XR ---------------------------------------------------------
# v2: user creates the XR directly in their namespace (no separate
# claim CRD; spec.scope: Namespaced on the XRD).
note "applying XPlatformSecret XR $CLAIM"
cat <<YAML | trace kubectl apply -f -
apiVersion: platform.k8-platform.io/v1alpha1
kind: XPlatformSecret
metadata:
  name: $CLAIM
  namespace: $TEST_NS
  labels:
    test.k8-platform/integration: "true"
spec:
  refreshInterval: 10s
  region: $REGION
  description: "integration test 11 - e2e XR from $RUN_ID"
YAML

# ---- 2. Wait for XR Ready ------------------------------------------------
# SPEC-S7: canonical wait + auto-dump on timeout.
"$HERE/../../scripts/wait-for-claim.sh" XPlatformSecret "$CLAIM" "$TEST_NS" 180

# ---- 3. Resolve the ASM key from the composite UID ----------------------
# v2: the XR is namespaced and shares the user-created resource name
# (no v1 claim → XR promotion pointer), so we can look up the XR
# directly by CLAIM name in $TEST_NS.
XR="$CLAIM"
# NB: NOT `UID=$(...)` — `$UID` is a bash readonly builtin (process
# user id, 1001 on Actions runners). Assignment under `set -u` silently
# fails and downstream code constructs the wrong ASM key. Defended by
# tests/unit/test_shell_readonly_var_assignment.sh.
XR_UID=$(kubectl get xplatformsecret -n "$TEST_NS" "$XR" -o jsonpath='{.metadata.uid}')
[ -n "$XR_UID" ] || ng "could not find XR uid for $XR in $TEST_NS"
ASM_KEY="k8-platform/${XR_UID}"
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

# ---- 8. Delete XR, verify cleanup ---------------------------------------
trace kubectl delete xplatformsecret -n "$TEST_NS" "$CLAIM" --wait=true --timeout=120s

wait_for "K8s Secret $CLAIM removed after XR delete" 60 3 -- \
  bash -c "! kubectl get secret -n $TEST_NS $CLAIM >/dev/null 2>&1"

wait_for "ExternalSecret $CLAIM removed after XR delete" 60 3 -- \
  bash -c "! kubectl get externalsecret -n $TEST_NS $CLAIM >/dev/null 2>&1"

# ASM secret should be gone too (recoveryWindowInDays=0 in Composition).
wait_for "ASM secret $ASM_KEY gone (recoveryWindowInDays=0)" 60 3 -- \
  bash -c "! aws secretsmanager describe-secret --secret-id '$ASM_KEY' --region '$REGION' >/dev/null 2>&1"

ok "XPlatformSecret end-to-end: apply → ASM + K8s Secret → rotation → delete"
