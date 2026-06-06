#!/usr/bin/env bash
# Unit tests for argocd/apps/spoke/*.yaml — the phase-3 spoke Applications.
# These target a NON-management cluster by name under the platform-spoke project,
# and (for the chart-backed ones) use multi-source. The existing
# test_argocd_app_revision_pinned.sh globs argocd/apps/*.yaml (non-recursive) and
# assumes single-source + project=k8-platform, so it does not (and should not)
# cover these — this file is their gate. Assertion shape reviewed via the
# auto-008 Round-1/Round-2 adversarial waves (multi-source, destination.name,
# sync-wave ordering, project scoping).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

SPOKE_DIR="$HERE/../../argocd/apps/spoke"
FAIL=0
found=0
hub_count=0   # apps in this dir that legitimately target the HUB (hub-addons)

for app in "$SPOKE_DIR"/*.yaml; do
  [ -e "$app" ] || continue
  base="$(basename "$app")"
  found=1
  kind="$(yq -r '.kind' "$app")"
  [ "$kind" = "Application" ] || { echo "FAIL[$base]: kind is $kind, want Application"; FAIL=1; continue; }

  proj="$(yq -r '.spec.project' "$app")"
  dname="$(yq -r '.spec.destination.name' "$app")"
  dserver="$(yq -r '.spec.destination.server' "$app")"

  # Branch on PROJECT rather than excluding a file by NAME: a real spoke app
  # that accidentally sets destination.server must still FAIL, and a hub app
  # that drifts into the spoke project must FAIL too.
  #   - k8-platform : never allowed here (locked first-party hub project).
  #   - hub-addons  : the one allowed hub-destination exception (Grafana Alloy
  #                   agent, phase 4); correctly uses destination.server. Its
  #                   full contract is gated by test_observability_apps.sh §3 +
  #                   test_hub_addons_appproject.sh — here we only confirm shape.
  #   - platform-spoke: the normal spoke-app contract (destination.name, no server).
  if [ "$proj" = "k8-platform" ]; then
    echo "FAIL[$base]: project=k8-platform not allowed under apps/spoke/"; FAIL=1; continue
  elif [ "$proj" = "hub-addons" ]; then
    hub_count=$((hub_count + 1))
    { [ "$dserver" = "https://kubernetes.default.svc" ] && [ "$dname" = "null" ]; } \
      && echo "ok[$base]: hub-addons app targets the hub by server" \
      || { echo "FAIL[$base]: hub-addons app must use destination.server=kubernetes.default.svc and no .name"; FAIL=1; }
  else
    [ "$proj" = "platform-spoke" ] && echo "ok[$base]: project=platform-spoke" \
      || { echo "FAIL[$base]: project=$proj, want platform-spoke (or hub-addons for the hub agent)"; FAIL=1; }
    # destination by NAME (spoke cluster secret), never the hub server.
    [ "$dname" != "null" ] && [ -n "$dname" ] && echo "ok[$base]: destination.name=$dname" \
      || { echo "FAIL[$base]: destination.name must be set (spoke by name)"; FAIL=1; }
    [ "$dserver" = "null" ] || { echo "FAIL[$base]: destination.server set ($dserver) — spokes are by name"; FAIL=1; }
  fi

  # every source's targetRevision must be pinned (main / a version), not HEAD/empty.
  # Handles single-source and multi-source (sources[]) shapes.
  revs="$(yq -r '[.spec.source.targetRevision] + [.spec.sources[]?.targetRevision] | .[] | select(. != null)' "$app")"
  [ -n "$revs" ] || { echo "FAIL[$base]: no targetRevision found on any source"; FAIL=1; }
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    case "$r" in
      HEAD|null) echo "FAIL[$base]: targetRevision '$r' not pinned"; FAIL=1;;
      *) :;;
    esac
  done <<< "$revs"
  echo "ok[$base]: all source targetRevisions pinned"

  # automated prune + selfHeal (spoke add-ons self-heal; the manual-sync carve
  # out is only the cluster-creation claim, which is NOT in this dir).
  prune="$(yq -r '.spec.syncPolicy.automated.prune' "$app")"
  sh="$(yq -r '.spec.syncPolicy.automated.selfHeal' "$app")"
  { [ "$prune" = "true" ] && [ "$sh" = "true" ]; } && echo "ok[$base]: automated prune+selfHeal" \
    || { echo "FAIL[$base]: spoke apps need automated prune+selfHeal (prune=$prune selfHeal=$sh)"; FAIL=1; }

  # sync-wave present (ordering: project<ingress/dns<hello).
  wave="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$app")"
  [ "$wave" != "null" ] && [ -n "$wave" ] && echo "ok[$base]: sync-wave=$wave" \
    || { echo "FAIL[$base]: missing argocd.argoproj.io/sync-wave annotation"; FAIL=1; }
done

[ "$found" -eq 1 ] || { echo "FAIL: no spoke apps found under $SPOKE_DIR"; FAIL=1; }

# Exactly ONE app in this dir may target the hub (the Alloy agent). More than one
# means a spoke app silently drifted to the hub destination; zero means the Alloy
# conversion regressed back to a .todo.
[ "$hub_count" -eq 1 ] && echo "ok: exactly one hub-addons app under apps/spoke/ (the Alloy agent)" \
  || { echo "FAIL: expected exactly 1 hub-addons app under apps/spoke/, found $hub_count"; FAIL=1; }

[ "$FAIL" -eq 0 ] && echo "PASS: spoke Applications contracts" || echo "FAILED"
exit "$FAIL"
