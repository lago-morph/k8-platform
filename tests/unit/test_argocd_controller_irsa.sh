#!/usr/bin/env bash
# Regression (auto-012): the ArgoCD application-controller MUST carry the IRSA
# role-arn annotation, not just the server.
#
# Bug-of-record: spoke (managed-cluster) registration validated fine via the
# argocd-SERVER (it had the annotation), but every spoke app sync failed with
#   "argocd-k8s-auth failed with exit code 20 (Client.Timeout exceeded while
#    awaiting headers)"
# because the application-CONTROLLER SA had no eks.amazonaws.com/role-arn
# annotation. The controller is what authenticates to managed clusters (it
# shells out to argocd-k8s-auth → EKS get-token, which needs AWS creds); with
# no IRSA it fell back to IMDS and timed out. irsa.tf already trusted the
# controller SA — only the helm annotation was missing.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

ROOT="$HERE/../.."
HELM_TF="$ROOT/terraform/management/helm.tf"
IRSA_TF="$ROOT/terraform/management/irsa.tf"

[ -f "$HELM_TF" ] || { echo "missing $HELM_TF"; exit 2; }
[ -f "$IRSA_TF" ] || { echo "missing $IRSA_TF"; exit 2; }

# 1. helm.tf annotates BOTH the server and the controller SAs with the
#    irsa_argocd role-arn. The set{} name keys carry escaped dots, so match
#    the component prefix + the annotation path loosely.
for comp in server controller; do
  if grep -qE "${comp}\.serviceAccount\.annotations\.eks.*role-arn" "$HELM_TF"; then
    pass "helm.tf annotates argocd ${comp} SA with eks role-arn"
  else
    fail "helm.tf does NOT annotate argocd ${comp} SA with eks role-arn" \
         "the ${comp} component needs the IRSA annotation (auto-012)"
  fi
done

# 2. The controller SA annotation must reference the argocd IRSA role.
if grep -A1 'controller\.serviceAccount\.annotations\.eks' "$HELM_TF" | grep -qF "module.irsa_argocd.iam_role_arn"; then
  pass "controller SA annotation references module.irsa_argocd.iam_role_arn"
else
  fail "controller SA annotation does not reference module.irsa_argocd.iam_role_arn"
fi

# 3. irsa_argocd must TRUST the application-controller SA (the annotation is
#    useless if the role's trust policy doesn't list the SA).
if grep -qE 'argocd:argocd-application-controller' "$IRSA_TF"; then
  pass "irsa.tf trusts argocd:argocd-application-controller SA"
else
  fail "irsa.tf does NOT trust argocd:argocd-application-controller SA" \
       "the role-arn annotation needs a matching trust-policy subject"
fi

summary
