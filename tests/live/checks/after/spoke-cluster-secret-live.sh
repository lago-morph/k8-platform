#!/usr/bin/env bash
# LIVE behavioral check (after tier) — the durable ArgoCD spoke registration
# Secret exists on the HUB and carries the full ADR-0010 cluster-facts
# contract (lane: non-aws, KIND kubernetes.m.crossplane.io/Object).
#
# This is the BEHAVIORAL oracle for kubernetes.m.crossplane.io/Object per
# ADR-0006: it proves the xspokeaccess-aws Composition's spoke-cluster-secret
# Object actually WROTE the registration Secret — labeled for the
# ApplicationSet cluster generators, annotated with all five contract facts,
# and carrying a usable connection config — not that a manifest says so.
# A REST/kubectl hand-registered secret would lack the Crossplane owner
# wiring but COULD satisfy the data shape; the contract checked here is the
# one the consumers (ADR-0010 ApplicationSets) and ArgoCD actually read, and
# the producer path is separately pinned by the unit contract lint + the
# render golden. Drives the real kube API read-only through the shared SSM
# relay (docs/decisions/0008) against the HUB (the Secret lives in the hub
# argocd namespace, whatever spoke is under test).
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# 3=expect-full violation, other=fail. Read-only (kubectl get only) — safe
# in `full` + `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

KIND="kubernetes.m.crossplane.io/Object"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
# The registration Secret lives on the HUB regardless of LIVE_CLUSTER.
HUB="${LIVE_HUB_CLUSTER:-k8-platform-mgmt}"
HELPER="$REPO_ROOT/scripts/sandbox-kubeconfig.sh"

# The five-fact contract + selector labels (mirrors
# tests/unit/test_cluster_facts_contract.sh — the unit lint pins
# producer==consumer==ADR; this check pins live==contract).
ANNOTATION_KEYS="domain subdomain certificate-arn external-dns-role-arn region"

# Tooling / creds preconditions — not-applicable (skip), not a failure.
for bin in aws kubectl jq session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 || skip "$bin not on PATH (registration-Secret live check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 || skip "no usable AWS credentials in this environment"
[ -x "$HELPER" ] || skip "helper $HELPER missing/not executable"

log "reading spoke registration Secrets on hub '$HUB' through the SSM relay"

# Bounded relay retry — a tunnel flake must NOT read as "0 found"
# (the auto-014 check-gap class; same idiom as external-secret-live.sh).
RELAY_ATTEMPTS="${LIVE_RELAY_ATTEMPTS:-4}"
RELAY_INTERVAL="${LIVE_RELAY_INTERVAL:-15}"
OUT=""; relay_ok=0
for attempt in $(seq 1 "$RELAY_ATTEMPTS"); do
  OUT="$("$HELPER" -c "$HUB" -r "$REGION" --exec \
          kubectl get secrets -n argocd \
            -l 'argocd.argoproj.io/secret-type=cluster,k8-platform.io/cluster-role=spoke' \
            -o json 2>/dev/null)"
  if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '.items' >/dev/null 2>&1; then
    relay_ok=1; break
  fi
  log "relay attempt $attempt/$RELAY_ATTEMPTS did not return a parseable list for $HUB; retry in ${RELAY_INTERVAL}s"
  [ "$attempt" -lt "$RELAY_ATTEMPTS" ] && sleep "$RELAY_INTERVAL"
done

if [ "$relay_ok" -ne 1 ]; then
  log "RELAY UNREACHABLE for $HUB after $RELAY_ATTEMPTS attempts."
  log "  → This is a relay/SSM-tunnel failure, NOT evidence the Secret is absent."
  skip "hub kube API not reachable after $RELAY_ATTEMPTS relay attempts (tunnel flake — not an absence)"
fi

TOTAL="$(printf '%s' "$OUT" | jq '.items | length')"
log "labeled spoke registration Secrets found on $HUB: $TOTAL"

# Relay reached + zero Secrets = a GENUINE absence (the producer never wrote
# it — the Object is unprovisioned, or its Required facts never resolved).
# The orchestrator promotes the skip to FAIL iff git declares the kind.
[ "${TOTAL:-0}" -ge 1 ] || skip "no labeled spoke registration Secret on $HUB (producer path not provisioned)"

# Every labeled Secret must carry the COMPLETE contract — the producer is
# complete-or-absent by design (Required-policy patches), so a partial
# Secret here is a real defect, never a wait-state.
fail_count=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  item="$(printf '%s' "$OUT" | jq --arg n "$name" '.items[] | select(.metadata.name==$n)')"
  for k in $ANNOTATION_KEYS; do
    v="$(printf '%s' "$item" | jq -r ".metadata.annotations[\"k8-platform.io/$k\"] // empty")"
    if [ -z "$v" ]; then
      ng "$name: contract annotation k8-platform.io/$k MISSING/empty (partial write — should be impossible)"
      fail_count=$((fail_count + 1))
    fi
  done
  sn="$(printf '%s' "$item" | jq -r '.metadata.labels["k8-platform.io/short-name"] // empty')"
  [ -n "$sn" ] || { ng "$name: k8-platform.io/short-name label missing"; fail_count=$((fail_count + 1)); }
  # connection material: name/server/config data keys, config shape
  for dk in name server config; do
    v="$(printf '%s' "$item" | jq -r ".data[\"$dk\"] // empty")"
    [ -n "$v" ] || { ng "$name: data.$dk missing"; fail_count=$((fail_count + 1)); }
  done
  cfg="$(printf '%s' "$item" | jq -r '.data.config // empty' | base64 -d 2>/dev/null)"
  printf '%s' "$cfg" | jq -e '.awsAuthConfig.clusterName and .tlsClientConfig.caData' >/dev/null 2>&1 \
    || { ng "$name: config is not the awsAuthConfig+caData shape ArgoCD needs"; fail_count=$((fail_count + 1)); }
done < <(printf '%s' "$OUT" | jq -r '.items[].metadata.name')

if [ "$fail_count" -gt 0 ]; then
  ng "$fail_count contract violation(s) on the registration Secret(s) — the fact bus is broken"
  exit 1
fi

ok "all $TOTAL spoke registration Secret(s) on $HUB carry the full ADR-0010 contract"
covers "$KIND"
exit "$LIVE_RC_PASS"
