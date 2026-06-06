#!/usr/bin/env bash
# Gates the hub-addons AppProject's blast-radius invariants (phase 4, Option A —
# decisions/2026-06-06-phase4-alloy-phase5-db.md). This project is the ONLY one
# that pairs a third-party chart repo with the HUB in-cluster destination, so it
# is hub-privileged: its no-wildcard sourceRepos + enumerated (non-wildcard) kind
# whitelists are the real control. Mirrors test_platform_spoke_appproject.sh but
# asserts the INVERSE destination rule (hub-addons DOES target
# kubernetes.default.svc; platform-spoke must NOT) — so a future edit cannot
# collapse the two projects into the same scope.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

PROJ="$HERE/../../argocd/projects/hub-addons.yaml"
FAIL=0
[ -f "$PROJ" ] || { echo "FAIL: $PROJ missing"; exit 1; }

# 1. No wildcard in any sourceRepos entry.
if yq -e '.spec.sourceRepos[] | select(test("\\*"))' "$PROJ" >/dev/null 2>&1; then
  echo "FAIL: hub-addons sourceRepos contains a wildcard entry"; FAIL=1
else
  echo "ok: sourceRepos has no wildcard entries"
fi

# 2. EXACTLY two sourceRepos (a third entry silently widens the hub door with no
#    wildcard). Set-equality, not subset.
nrepos="$(yq -r '.spec.sourceRepos | length' "$PROJ")"
[ "$nrepos" = "2" ] && echo "ok: exactly 2 sourceRepos" \
  || { echo "FAIL: hub-addons must have exactly 2 sourceRepos, got $nrepos"; FAIL=1; }
for repo in "https://github.com/lago-morph/k8-platform.git" "https://grafana.github.io/helm-charts"; do
  if yq -e ".spec.sourceRepos[] | select(. == \"$repo\")" "$PROJ" >/dev/null 2>&1; then
    echo "ok: sourceRepos includes $repo"
  else
    echo "FAIL: hub-addons sourceRepos must include $repo"; FAIL=1
  fi
done

# 3. INVERSE of platform-spoke: hub-addons DOES target the hub in-cluster server.
ndest="$(yq -r '.spec.destinations | length' "$PROJ")"
[ "$ndest" = "1" ] && echo "ok: exactly 1 destination" \
  || { echo "FAIL: hub-addons must have exactly 1 destination, got $ndest"; FAIL=1; }
if yq -e '.spec.destinations[] | select(.server == "https://kubernetes.default.svc")' "$PROJ" >/dev/null 2>&1; then
  echo "ok: targets the hub in-cluster server (inverse of platform-spoke)"
else
  echo "FAIL: hub-addons must target https://kubernetes.default.svc"; FAIL=1
fi
# 4. Must NOT address by name (that's the spoke pattern) and ns must be the
#    scoped monitoring-agent, never a wildcard.
if yq -e '.spec.destinations[] | select(.name != null)' "$PROJ" >/dev/null 2>&1; then
  echo "FAIL: hub-addons must not use destination.name (hub is by server)"; FAIL=1
else
  echo "ok: no destination.name (hub is addressed by server)"
fi
if yq -e '.spec.destinations[] | select(.namespace == "*")' "$PROJ" >/dev/null 2>&1; then
  echo "FAIL: hub-addons destination namespace must not be wildcard"; FAIL=1
else
  echo "ok: destination namespace is not wildcard"
fi
[ "$(yq -r '.spec.destinations[0].namespace' "$PROJ")" = "monitoring-agent" ] \
  && echo "ok: destination namespace = monitoring-agent" \
  || { echo "FAIL: hub-addons destination namespace must be monitoring-agent"; FAIL=1; }

# 5. No wildcard KIND or GROUP in either whitelist (the header brags
#    "enumerated, not *" — enforce it; platform-spoke uses kind:"*" in its
#    namespaceResourceWhitelist, so a copy-paste from it would silently grant
#    hub-wide kind access).
for wl in clusterResourceWhitelist namespaceResourceWhitelist; do
  if yq -e ".spec.${wl}[] | select(.kind == \"*\" or .group == \"*\")" "$PROJ" >/dev/null 2>&1; then
    echo "FAIL: hub-addons $wl contains a wildcard kind/group"; FAIL=1
  else
    echo "ok: $wl has no wildcard kind/group"
  fi
done

# 6. clusterResourceWhitelist is EXACTLY {Namespace, ClusterRole,
#    ClusterRoleBinding} (set equality — an added CRD/Webhook kind must fail, not
#    pass as a superset).
got_cluster="$(yq -r '[.spec.clusterResourceWhitelist[].kind] | sort | join(",")' "$PROJ")"
want_cluster="ClusterRole,ClusterRoleBinding,Namespace"
[ "$got_cluster" = "$want_cluster" ] \
  && echo "ok: clusterResourceWhitelist is exactly {$want_cluster}" \
  || { echo "FAIL: clusterResourceWhitelist must be exactly {$want_cluster}, got {$got_cluster}"; FAIL=1; }

[ "$FAIL" -eq 0 ] && echo "PASS: hub-addons AppProject invariants" || echo "FAILED"
exit "$FAIL"
