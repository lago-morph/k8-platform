#!/usr/bin/env bash
# LIVE behavioral check (after tier) — sandbox kubectl reaches the cluster via
# the shared SSM relay (docs/decisions/0008).
#
# This is the BEHAVIORAL oracle for the kube-relay-ingress MR, per ADR-0006: it
# proves the thing WORKS, not that a manifest says so. A static yq/grep that the
# Composition *contains* a SecurityGroupRule is a lint; THIS opens the real
# SSM tunnel to the cluster-under-test and runs a real `kubectl get nodes`. It
# passes only if the API answers — which requires the cluster's SG to actually
# admit the relay on 443 (the kube-relay-ingress MR) AND the sandbox identity's
# read-only access entry to actually authorize the call.
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only — safe in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

CLUSTER="${LIVE_CLUSTER:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
HELPER="$REPO_ROOT/scripts/sandbox-kubeconfig.sh"

[ -n "$CLUSTER" ] || skip "no LIVE_CLUSTER set (no cluster under test)"

# Tooling / creds preconditions — not-applicable, not a failure, if absent.
for bin in aws kubectl jq session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (sandbox-kubectl path not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"
[ -x "$HELPER" ] || skip "helper $HELPER missing/not executable"

# The shared relay must exist. If it doesn't, the kube-relay path is unprovisioned;
# return SKIP and let the orchestrator promote to FAIL iff git declares the kind
# (expect-full) for this cluster.
# Distinguish "the describe call failed" (permissions — e.g. a scoped role
# without ec2:DescribeInstances, live-verify run 28759141867) from a real
# empty result: a denied read must never be reported as "not provisioned".
if ! DESCRIBE_OUT=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=kube-relay" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[0].InstanceId' --output text 2>&1); then
  skip "ec2:DescribeInstances failed for the relay lookup (${DESCRIBE_OUT%%$'\n'*}) — cannot tell whether the relay exists; fix the caller's permissions"
fi
RELAY_ID=$(printf '%s' "$DESCRIBE_OUT" | tr -d '[:space:]')
{ [ -n "$RELAY_ID" ] && [ "$RELAY_ID" != "None" ]; } \
  || skip "no running kube-relay instance (relay not provisioned)"

log "driving kubectl get nodes for '$CLUSTER' through relay $RELAY_ID"
OUT="$("$HELPER" -c "$CLUSTER" -r "$REGION" --exec kubectl get nodes --no-headers 2>/dev/null)" || {
  ng "kubectl through the SSM relay FAILED for $CLUSTER (SG ingress / access entry not effective)"
  echo "$OUT" | tail -5
  exit 1
}
READY=$(printf '%s\n' "$OUT" | grep -c ' Ready ' || true)
[ "$READY" -ge 1 ] || { ng "kubectl reached $CLUSTER but found 0 Ready nodes"; exit 1; }

ok "sandbox kubectl reached $CLUSTER via the relay — $READY Ready node(s)"
# Reaching the private API through the relay proves the SG ingress rule admits it.
covers ec2.aws.m.upbound.io/SecurityGroupRule
exit "$LIVE_RC_PASS"
