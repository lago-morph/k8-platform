#!/usr/bin/env bash
# Gates the platform-spoke AppProject's blast-radius invariants (auto-008 S1).
# The project maps the hub ArgoCD to cluster-admin on spokes, so its sourceRepos
# (pinned, no wildcards) + destination scoping are the real control.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

PROJ="$HERE/../../argocd/projects/platform-spoke.yaml"
FAIL=0

[ -f "$PROJ" ] || { echo "FAIL: $PROJ missing"; exit 1; }

# 1. No wildcard in any sourceRepos entry (a wildcard would let ArgoCD pull an
#    arbitrary chart repo onto a cluster-admin-capable destination).
if yq -e '.spec.sourceRepos[] | select(test("\\*"))' "$PROJ" >/dev/null 2>&1; then
  echo "FAIL: platform-spoke sourceRepos contains a wildcard entry"; FAIL=1
else
  echo "ok: sourceRepos has no wildcard entries"
fi

# 2. Must include this repo (values live in git, multi-source).
if yq -e '.spec.sourceRepos[] | select(. == "https://github.com/lago-morph/k8-platform.git")' "$PROJ" >/dev/null 2>&1; then
  echo "ok: this repo is an allowed source"
else
  echo "FAIL: platform-spoke must allow this repo as a source"; FAIL=1
fi

# 3. Destinations must NOT target the hub in-cluster server (that's k8-platform's
#    exclusive territory; spokes are addressed by name).
if yq -e '.spec.destinations[] | select(.server == "https://kubernetes.default.svc")' "$PROJ" >/dev/null 2>&1; then
  echo "FAIL: platform-spoke must not target the hub (kubernetes.default.svc)"; FAIL=1
else
  echo "ok: no hub in-cluster destination"
fi

# 4. Must address spokes by name (destination.name set, not server).
if yq -e '.spec.destinations[] | select(.name != null)' "$PROJ" >/dev/null 2>&1; then
  echo "ok: spokes addressed by destination.name"
else
  echo "FAIL: platform-spoke destinations must use .name (spoke cluster secret)"; FAIL=1
fi

# 5. The workload kinds the add-on charts need must be whitelisted (CRD + cluster
#    RBAC are the easy-to-miss ones that block ingress-nginx/prometheus installs).
for kind in CustomResourceDefinition ClusterRole ClusterRoleBinding; do
  if yq -e ".spec.clusterResourceWhitelist[] | select(.kind == \"$kind\")" "$PROJ" >/dev/null 2>&1; then
    echo "ok: clusterResourceWhitelist includes $kind"
  else
    echo "FAIL: platform-spoke clusterResourceWhitelist missing $kind"; FAIL=1
  fi
done

[ "$FAIL" -eq 0 ] && echo "PASS: platform-spoke AppProject invariants" || echo "FAILED"
exit "$FAIL"
