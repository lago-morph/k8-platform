#!/usr/bin/env bash
# 10: ArgoCD GitOps loop — Application syncs in-cluster manifest changes
# from the official example repo.
#
# Strategy: create an Application pointing at the argocd-example-apps
# kustomize-guestbook path, wait for initial sync, then trigger a hard
# refresh + apply a temporary in-cluster patch to a synced object. With
# selfHeal: true, Argo should revert the drift within its refresh
# interval. Asserts the revert happened.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-lib.sh"

require_kube
require_ns argocd

APP="integ-gitops-${RUN_ID}"
TEST_NS="integ-gitops-${RUN_ID}"

cat <<YAML | trace kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: { name: $TEST_NS, labels: { $INTEG_LABEL_KEY: "true" } }
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
    path: kustomize-guestbook
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

wait_for "Application $APP Synced+Healthy" 180 5 -- \
  bash -c "kubectl get application -n argocd $APP -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null | grep -qE '^Synced/Healthy$'"

# Manually drift the replicas of the kustomize-guestbook-ui deployment.
DEP="kustomize-guestbook-ui"
ORIG=$(kubectl get deploy -n $TEST_NS $DEP -o jsonpath='{.spec.replicas}')
note "original replicas=$ORIG; setting to 3 to drift"
trace kubectl scale deploy -n $TEST_NS $DEP --replicas=3

wait_for "Argo self-heal reverts replicas to $ORIG" 180 5 -- \
  bash -c "[ \"\$(kubectl get deploy -n $TEST_NS $DEP -o jsonpath='{.spec.replicas}')\" = \"$ORIG\" ]"

ok "ArgoCD GitOps loop: drift detected and reverted (replicas $ORIG→3→$ORIG)"
