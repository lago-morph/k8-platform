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

for app in "$SPOKE_DIR"/*.yaml; do
  [ -e "$app" ] || continue
  base="$(basename "$app")"
  found=1
  kind="$(yq -r '.kind' "$app")"
  [ "$kind" = "Application" ] || { echo "FAIL[$base]: kind is $kind, want Application"; FAIL=1; continue; }

  # project must be the dedicated spoke project (NOT k8-platform — that project
  # forbids spoke destinations + third-party charts).
  proj="$(yq -r '.spec.project' "$app")"
  [ "$proj" = "platform-spoke" ] && echo "ok[$base]: project=platform-spoke" \
    || { echo "FAIL[$base]: project=$proj, want platform-spoke"; FAIL=1; }

  # destination by NAME (spoke cluster secret), never the hub server.
  dname="$(yq -r '.spec.destination.name' "$app")"
  dserver="$(yq -r '.spec.destination.server' "$app")"
  [ "$dname" != "null" ] && [ -n "$dname" ] && echo "ok[$base]: destination.name=$dname" \
    || { echo "FAIL[$base]: destination.name must be set (spoke by name)"; FAIL=1; }
  [ "$dserver" = "null" ] || { echo "FAIL[$base]: destination.server set ($dserver) — spokes are by name"; FAIL=1; }

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
[ "$FAIL" -eq 0 ] && echo "PASS: spoke Applications contracts" || echo "FAILED"
exit "$FAIL"
