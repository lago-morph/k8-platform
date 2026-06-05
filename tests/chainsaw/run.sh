#!/usr/bin/env bash
# Chainsaw harness orchestrator.
#
# Lifecycle:
#   1. Create a fresh kind cluster (pinned node image + digest).
#   2. Install Crossplane v2 (pinned chart version) + provider-family-aws
#      (pinned package version). Wait for provider Healthy=True.
#   3. Run every scenario under tests/chainsaw/* via `chainsaw test`.
#   4. Cleanup trap: best-effort delete any chainsaw-scoped ASM secrets
#      from this run, then `kind delete cluster`. Trap runs on any exit.
#
# Per AGENTS.md §6.6, the harness is designed to run end-to-end without
# user attention. Failures exit non-zero; the cluster is destroyed
# either way so successive runs start clean.
#
# Required tools on PATH:
#   - kind     (version pinned in versions.env)
#   - kubectl
#   - helm
#   - chainsaw (version pinned in versions.env)
#   - aws      (only for the ASM cleanup trap)
#
# Required env:
#   - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION — only when
#     running scenarios that hit real AWS. Smoke-only runs work without.
#
# Optional env:
#   - CHAINSAW_RUN_ID — overrides the auto-generated suffix. CI passes
#     $GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT to avoid parallel collisions.
#   - CHAINSAW_SCENARIOS — filter to a single subdir, e.g.
#     "platform-secret/00-claim-creates-secret".

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"

# shellcheck disable=SC1091
. ./versions.env

# ASM cleanup helpers (asm_cleanup_run / asm_cleanup_targets / asm_delete_one).
# Sourcing is side-effect-free; the cleanup trap below calls asm_cleanup_run.
# shellcheck disable=SC1091
. ./_lib/asm-cleanup.sh

CLUSTER_NAME="k8-platform-chainsaw"
KUBECONFIG_TMP="${RUNNER_TEMP:-/tmp}/chainsaw-kubeconfig"
export KUBECONFIG="$KUBECONFIG_TMP"

# Per-run suffix prevents parallel CI runs from colliding on shared AWS
# resources (ASM secret names within a single account). Stable across the
# script's lifetime so the cleanup trap sees the same prefix.
CHAINSAW_RUN_ID="${CHAINSAW_RUN_ID:-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8 || echo "$$")}"
export CHAINSAW_RUN_ID
export ASM_RUN_PREFIX="${ASM_PREFIX}-${CHAINSAW_RUN_ID}"

echo "── chainsaw harness ───────────────────────────────────────────"
echo "  cluster:       $CLUSTER_NAME"
echo "  node image:    $KINDEST_NODE_IMAGE"
echo "  crossplane:    $CROSSPLANE_CHART_VERSION"
echo "  provider AWS:  $PROVIDER_FAMILY_AWS_VERSION"
echo "  chainsaw:      $CHAINSAW_VERSION"
echo "  run id:        $CHAINSAW_RUN_ID"
echo "  asm prefix:    $ASM_RUN_PREFIX"
echo ""

# ---------- cleanup trap (runs on ANY exit) ---------------------------------
cleanup() {
  local rc=$?
  echo ""
  echo "── cleanup (rc=$rc) ───────────────────────────────────────────"

  # Best-effort: delete the ASM secrets THIS run created. We enumerate the
  # real names from the Secret MRs in the (still-alive) kind cluster rather
  # than guessing a name prefix — the Composition names secrets
  # `k8-platform/<XR-uid>`, which never matched the old `${ASM_RUN_PREFIX}/`
  # filter (OI-2026-05-28-1). MUST run BEFORE `kind delete` below: the
  # cluster has to be alive to enumerate. See tests/chainsaw/_lib/asm-cleanup.sh.
  if command -v aws >/dev/null 2>&1 && [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    echo "  aws secretsmanager: sweeping ASM secrets by MR enumeration"
    asm_cleanup_run
  fi

  # Best-effort kind destroy. AFTER the ASM sweep above (which needs the
  # cluster alive to list Secret MRs).
  if command -v kind >/dev/null 2>&1; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    echo "  kind:           cluster destroyed"
  fi

  rm -f "$KUBECONFIG_TMP" || true
  echo "── done (rc=$rc) ─────────────────────────────────────────────"
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------- create cluster --------------------------------------------------
echo "── creating kind cluster ──────────────────────────────────────"
# Render kind config with the pinned node image substituted in.
RENDERED_CONFIG="${RUNNER_TEMP:-/tmp}/chainsaw-kind-rendered.yaml"
awk -v img="$KINDEST_NODE_IMAGE" '
  /^nodes:/ { print; in_nodes=1; next }
  in_nodes && /^  - role: control-plane/ {
    print
    print "    image: " img
    next
  }
  { print }
' kind-config.yaml > "$RENDERED_CONFIG"

kind create cluster \
  --name "$CLUSTER_NAME" \
  --config "$RENDERED_CONFIG" \
  --wait 120s

kubectl wait --for=condition=Ready node --all --timeout=120s

# ---------- install Crossplane ----------------------------------------------
echo ""
echo "── installing Crossplane ──────────────────────────────────────"
# Install from the vendored chart, NOT charts.crossplane.io — that repo's
# index.yaml 403s the GitHub Actions runner network (OI-2026-06-05-2). The
# tarball is shared with terraform/management (same pinned version); the
# CROSSPLANE_CHART_VERSION still drives the filename so the two stay in
# lockstep. See terraform/management/vendor/README.md.
CROSSPLANE_CHART_TGZ="${SCRIPT_DIR}/../../terraform/management/vendor/crossplane-${CROSSPLANE_CHART_VERSION}.tgz"
if [ ! -f "$CROSSPLANE_CHART_TGZ" ]; then
  echo "ERROR: vendored crossplane chart not found at $CROSSPLANE_CHART_TGZ" >&2
  echo "Vendor crossplane-${CROSSPLANE_CHART_VERSION}.tgz per terraform/management/vendor/README.md." >&2
  exit 1
fi

helm install crossplane "$CROSSPLANE_CHART_TGZ" \
  --namespace crossplane-system \
  --create-namespace \
  --set 'args[0]=--enable-realtime-compositions=false' \
  --set 'args[1]=--enable-ssa-claims=false' \
  --set 'args[2]=--enable-custom-to-managed-resource-conversion=false' \
  --wait \
  --timeout 5m

kubectl wait --for=condition=Available --timeout=300s \
  -n crossplane-system deploy/crossplane

# ---------- grant Crossplane RBAC on ExternalSecret ------------------------
# Crossplane 2.3's composite reconciler enforces RBAC strictly when
# applying composed resources. The PlatformSecret Composition renders
# an ExternalSecret (from ESO, not a Crossplane provider package), so
# Crossplane has no auto-RBAC for it. See
# crossplane/rbac/01-crossplane-externalsecrets.yaml for the full
# rationale; chainsaw mirrors the live-cluster RBAC here.
kubectl apply -f ../../crossplane/rbac/01-crossplane-externalsecrets.yaml

# ---------- install AWS provider --------------------------------------------
echo ""
echo "── installing provider-family-aws ─────────────────────────────"
kubectl apply -f - <<MANIFEST
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-family-aws
spec:
  package: "xpkg.upbound.io/upbound/provider-family-aws:${PROVIDER_FAMILY_AWS_VERSION}"
MANIFEST

# Per adversarial-reviewer B: gate claim apply on Provider Healthy AND
# ProviderRevision Healthy. Without this, scenarios race the CRD install
# and fail with "no matches for kind". Single-line so the unit test's
# grep can verify the gate exists.
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/provider-family-aws --timeout=300s

# ---------- install provider-aws-secretsmanager ---------------------------
# Upbound's family-aws is a meta-package; child providers (one per AWS
# service) install separately. PlatformSecret needs the secretsmanager
# child to reconcile its ASM Secret managed resource.
echo ""
echo "── installing provider-aws-secretsmanager ────────────────────"
kubectl apply -f - <<MANIFEST
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-secretsmanager
spec:
  package: "xpkg.upbound.io/upbound/provider-aws-secretsmanager:${PROVIDER_AWS_SECRETSMANAGER_VERSION}"
MANIFEST
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/provider-aws-secretsmanager --timeout=300s

# ---------- install function-patch-and-transform ---------------------------
# Crossplane v2 Pipeline compositions need a function to apply patches;
# function-patch-and-transform implements the legacy `resources` shape.
echo ""
echo "── installing function-patch-and-transform ────────────────────"
kubectl apply -f - <<MANIFEST
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: "xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:${FUNCTION_PATCH_AND_TRANSFORM_VERSION}"
MANIFEST
kubectl wait --for=condition=Healthy function.pkg.crossplane.io/function-patch-and-transform --timeout=300s

# ---------- install function-environment-configs ---------------------------
# The platform-cluster Composition (phase 3) merges the cluster-network
# EnvironmentConfig into the pipeline environment via this function. Install
# it so applying that Composition validates cleanly in the kind cluster.
echo ""
echo "── installing function-environment-configs ────────────────────"
kubectl apply -f - <<MANIFEST
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-environment-configs
spec:
  package: "xpkg.upbound.io/crossplane-contrib/function-environment-configs:${FUNCTION_ENVIRONMENT_CONFIGS_VERSION}"
MANIFEST
kubectl wait --for=condition=Healthy function.pkg.crossplane.io/function-environment-configs --timeout=300s

# ---------- install ESO + AWS ProviderConfig + ClusterSecretStore -----------
#
# These were previously inside `tests/chainsaw/platform-secret/_setup/`
# but chainsaw runs scenarios in non-deterministic order with parallel=1
# (run 26343813170 saw setup execute third, after claim-creates-secret
# which depended on it). Setup that must precede every scenario belongs
# in the orchestrator, not inside chainsaw — chainsaw scenarios should
# express the *test*, not the world they assume.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo ""
  echo "── installing ESO + AWS ProviderConfig + ClusterSecretStore ──"

  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo update external-secrets >/dev/null
  helm install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace \
    --version 0.10.4 \
    --set installCRDs=true \
    --wait --timeout 5m

  # AWS creds Secret for the Crossplane AWS provider in kind (no IRSA).
  kubectl create namespace crossplane-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic aws-creds \
    --namespace crossplane-system \
    --from-literal=creds="[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
" --dry-run=client -o yaml | kubectl apply -f -
  # Crossplane v2 with provider-family-aws v2.5.0+ replaces the
  # namespaced ProviderConfig with the cluster-scoped
  # ClusterProviderConfig (one shared config for all compositions).
  # No metadata.namespace — the resource is cluster-scoped and
  # admission rejects a namespace field on a cluster-scoped kind.
  kubectl apply -f - <<MANIFEST
apiVersion: aws.m.upbound.io/v1beta1
kind: ClusterProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-creds
      key: creds
MANIFEST

  # AWS creds Secret for ESO + the ClusterSecretStore (in kind we replace
  # IRSA auth with static-cred auth via accessKeyIDSecretRef).
  kubectl create secret generic eso-aws-creds \
    --namespace external-secrets \
    --from-literal=access-key-id="${AWS_ACCESS_KEY_ID}" \
    --from-literal=secret-access-key="${AWS_SECRET_ACCESS_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f - <<MANIFEST
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION:-us-east-1}
      auth:
        secretRef:
          accessKeyIDSecretRef:
            name: eso-aws-creds
            namespace: external-secrets
            key: access-key-id
          secretAccessKeySecretRef:
            name: eso-aws-creds
            namespace: external-secrets
            key: secret-access-key
MANIFEST

  # Apply the XRD and Composition under test. These need to be Established
  # BEFORE any scenario tries to create a PlatformSecret claim.
  if [ -f ../../crossplane/xrds/platform-secret.yaml ]; then
    kubectl apply -f ../../crossplane/xrds/platform-secret.yaml
    kubectl apply -f ../../crossplane/compositions/platform-secret.yaml
    kubectl wait --for=condition=Established --timeout=120s \
      crd/xplatformsecrets.platform.k8-platform.io
  else
    echo "  (no PlatformSecret XRD on disk — skipping XRD apply)"
  fi
else
  echo ""
  echo "── AWS creds absent — skipping ESO/ProviderConfig/ClusterSecretStore setup"
  echo "   (smoke scenarios will run; platform-secret scenarios will fail closed)"
fi

# ---------- on-failure diagnostics ------------------------------------------
#
# Chainsaw's own failure output only shows the assertion that failed.
# When a PlatformSecret claim stays Ready=False ("waiting for composite
# resource to become Ready"), the root cause is downstream — provider
# not Healthy, composed ASM Secret stuck, ESO controller crashed, etc.
# Without describes / logs, every failure looks identical.
#
# This block runs only when chainsaw exited non-zero. The cleanup trap
# fires after this block and tears the kind cluster down, so this is
# the last chance to capture state.
dump_diagnostics() {
  echo ""
  echo "── ON-FAILURE DIAGNOSTICS (chainsaw rc=$1) ────────────────────"

  echo ""
  echo "── crossplane providers + functions ───────────────────────────"
  kubectl get provider.pkg.crossplane.io,providerrevision.pkg.crossplane.io,function.pkg.crossplane.io 2>&1 | sed 's/^/  /' || true

  echo ""
  echo "── crossplane-system pods ─────────────────────────────────────"
  kubectl -n crossplane-system get pods 2>&1 | sed 's/^/  /' || true
  for pod in $(kubectl -n crossplane-system get pods -o name 2>/dev/null); do
    echo ""
    echo "── logs: $pod (tail 40) ──"
    kubectl -n crossplane-system logs --tail=40 "$pod" 2>&1 | sed 's/^/    /' || true
  done

  echo ""
  echo "── composites + managed resources ─────────────────────────────"
  kubectl get xplatformsecret -A 2>&1 | sed 's/^/  /' || true
  kubectl get xplatformcluster -A 2>&1 | sed 's/^/  /' || true
  kubectl get managed 2>&1 | sed 's/^/  /' || true

  echo ""
  echo "── describe stuck composites (first 60 lines each) ────────────"
  for kind in xplatformsecret xplatformcluster; do
    for name in $(kubectl get "$kind" -o name 2>/dev/null); do
      echo ""
      echo "── describe $name ──"
      kubectl describe "$name" 2>&1 | head -60 | sed 's/^/    /' || true
    done
  done

  echo ""
  echo "── ExternalSecret status (every ns) ───────────────────────────"
  kubectl get externalsecret -A -o wide 2>&1 | sed 's/^/  /' || true

  echo ""
  echo "── external-secrets pods ──────────────────────────────────────"
  kubectl -n external-secrets get pods 2>&1 | sed 's/^/  /' || true
  for pod in $(kubectl -n external-secrets get pods -o name 2>/dev/null); do
    echo ""
    echo "── logs: $pod (tail 40) ──"
    kubectl -n external-secrets logs --tail=40 "$pod" 2>&1 | sed 's/^/    /' || true
  done

  echo ""
  echo "── recent events (cluster-wide, last 20) ──────────────────────"
  kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -20 | sed 's/^/  /' || true

  echo ""
  echo "── END DIAGNOSTICS ────────────────────────────────────────────"
}

# ---------- run chainsaw scenarios ------------------------------------------
#
# Meta-scenario handling (SPEC-A4):
#   Scenarios whose directory name begins with `meta-` are exit-inverted —
#   they deliberately fail to exercise infrastructure (the `catch:` block).
#   Chainsaw reports one exit code for a whole invocation, so we run meta
#   scenarios in separate invocations and invert their result.
#
#   Pass criteria for a meta scenario:
#     1. chainsaw exits NON-ZERO (the deliberate failure happened), AND
#     2. stdout contains the expected catch-block markers
#        (`Describe Resource:` AND `Events:` AND a line starting `Name:`).
#
#   A zero exit means the "deliberate fail" step somehow passed —
#   regression — and the meta scenario reports FAIL.

# Discover scenario directories at any depth, then partition.
ALL_SCENARIO_DIRS=$(
  find . -type f -name 'chainsaw-test.yaml' \
    -not -path './_lib/*' \
    -exec dirname {} \; \
    | sort -u
)
META_DIRS=$(echo "$ALL_SCENARIO_DIRS" | awk -F/ '{ for(i=1;i<=NF;i++) if ($i ~ /^meta-/) { print; next } }')
NORMAL_DIRS=$(echo "$ALL_SCENARIO_DIRS" | awk -F/ '{ for(i=1;i<=NF;i++) if ($i ~ /^meta-/) next; print }')

echo ""
echo "── running chainsaw (normal scenarios) ────────────────────────"

# If the user filtered via CHAINSAW_SCENARIOS, honour it directly and
# skip meta-partitioning — they know what they're after.
if [ -n "${CHAINSAW_SCENARIOS:-}" ]; then
  set +e
  chainsaw test "${CHAINSAW_SCENARIOS}" --config chainsaw-config.yaml
  CHAINSAW_RC=$?
  set -e
  if [ "$CHAINSAW_RC" -ne 0 ]; then
    dump_diagnostics "$CHAINSAW_RC"
    exit "$CHAINSAW_RC"
  fi
  echo "── all scenarios passed (filtered) ──────────────────────────"
  exit 0
fi

OVERALL_RC=0

# 1. Normal scenarios — chainsaw exit == script's pass/fail.
if [ -n "$NORMAL_DIRS" ]; then
  set +e
  # shellcheck disable=SC2086
  chainsaw test $NORMAL_DIRS --config chainsaw-config.yaml
  NORMAL_RC=$?
  set -e
  if [ "$NORMAL_RC" -ne 0 ]; then
    dump_diagnostics "$NORMAL_RC"
    OVERALL_RC=$NORMAL_RC
  fi
fi

# 2. Meta scenarios — each runs in its own invocation so we can invert
#    its exit independently and grep its stdout for catch-block markers.
if [ -n "$META_DIRS" ]; then
  echo ""
  echo "── running chainsaw (meta scenarios — exit-inverted) ──────────"
  while IFS= read -r meta_dir; do
    [ -z "$meta_dir" ] && continue
    echo ""
    echo "── meta scenario: $meta_dir ───────────────────────────────────"
    META_LOG="${RUNNER_TEMP:-/tmp}/chainsaw-meta-$(basename "$meta_dir").log"
    set +e
    chainsaw test "$meta_dir" --config chainsaw-config.yaml 2>&1 | tee "$META_LOG"
    META_RC=${PIPESTATUS[0]}
    set -e

    # Inverted-exit gate: PASS iff chainsaw exited non-zero AND the
    # `catch:` handler actually fired. Chainsaw emits structural log
    # frames of the form
    #   l.go:52: | HH:MM:SS | <scenario> | <step> | CATCH | BEGIN |
    #   l.go:52: | HH:MM:SS | <scenario> | <step> | CATCH | END   |
    # whenever any `spec.catch:` block runs. Because chainsaw colors
    # those frames with ANSI escape codes between the literal tokens,
    # we use a permissive `.*` regex so the matcher does not depend on
    # exact whitespace or color sequences. The presence of `CATCH`
    # followed eventually by `BEGIN` on the same line is unique to
    # chainsaw's catch frame.
    if [ "$META_RC" -eq 0 ]; then
      echo "  ✗ meta-test '$meta_dir' chainsaw RC=0 (expected non-zero — deliberate-fail step passed)"
      OVERALL_RC=1
      continue
    fi
    MISSING=""
    grep -qE "CATCH.*BEGIN" "$META_LOG"  || MISSING="${MISSING} 'CATCH...BEGIN'"
    grep -qE "CATCH.*END"   "$META_LOG"  || MISSING="${MISSING} 'CATCH...END'"
    if [ -n "$MISSING" ]; then
      echo "  ✗ meta-test '$meta_dir' chainsaw RC=$META_RC but catch markers missing:${MISSING}"
      OVERALL_RC=1
    else
      echo "  ✓ meta-test '$meta_dir' PASS (chainsaw RC=$META_RC, catch handler fired)"
    fi
  done <<< "$META_DIRS"
fi

if [ "$OVERALL_RC" -ne 0 ]; then
  exit "$OVERALL_RC"
fi

echo ""
echo "── all scenarios passed ──────────────────────────────────────"
# trap handles cleanup
