#!/usr/bin/env bash
# 01: ArgoCD Application creates and syncs a Deployment.
#
# Creates a minimal ArgoCD Application pointing at a public manifest path,
# waits for it to reach Synced + Healthy, asserts the deployment's pods are
# running. Tears down the Application (auto-prunes the deployment via the
# `prune: true` syncPolicy).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_ns argocd

APP="integ-httpbin-${RUN_ID}"
TEST_NS="integ-${RUN_ID}"

cat <<YAML | trace kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $TEST_NS
  labels: { $INTEG_LABEL_KEY: "true" }
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP
  namespace: argocd
  labels: { $INTEG_LABEL_KEY: "true" }
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    path: guestbook
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: $TEST_NS
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
YAML

add_cleanup "kubectl delete application -n argocd $APP --wait=false"
add_cleanup "kubectl delete ns $TEST_NS --wait=false"

wait_for "Application $APP reaches Synced+Healthy" 180 5 -- \
  bash -c "kubectl get application -n argocd $APP -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null | grep -qE '^Synced/Healthy$'"

# Argo's example guestbook has a Deployment named "guestbook-ui".
wait_for "pod guestbook-ui in $TEST_NS becomes Running" 60 3 -- \
  bash -c "kubectl get pods -n $TEST_NS --no-headers 2>/dev/null | grep -q ' Running '"

ok "Application $APP synced and deployed $TEST_NS/guestbook-ui"
