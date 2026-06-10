#!/usr/bin/env bash
# Unit tests for argocd/apps/spoke/*.yaml — the spoke add-on ApplicationSets
# (ADR-0010). Every file in this dir is an ApplicationSet whose cluster
# generator selects labeled spoke cluster Secrets and templates the
# cluster-facts contract into helm values (the per-key contract lint lives in
# test_cluster_facts_contract.sh; THIS file gates the ApplicationSet shape).
#
# Shape contract per file:
#   - kind ApplicationSet, goTemplate + missingkey=error,
#     preserveResourcesOnDeletion, ONE clusters generator selecting
#     k8-platform.io/cluster-role=spoke
#   - template destination by NAME from the generator ({{.name}}), project
#     platform-spoke — EXCEPT the one deliberate hub app (the Alloy agent),
#     which pins project hub-addons + the hub in-cluster server (its full
#     contract is gated by test_observability_apps.sh §3)
#   - every template source targetRevision pinned; automated prune+selfHeal;
#     sync-wave on the GENERATED Application (template metadata)
#
# Assertion shape carried over from the auto-008 Round-1/Round-2 adversarial
# waves (multi-source, destination-by-name, sync-wave ordering, project
# scoping), re-based onto .spec.template by the ADR-0010 conversion.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

SPOKE_DIR="$HERE/../../argocd/apps/spoke"
FAIL=0
found=0
hub_count=0   # appsets in this dir that legitimately target the HUB (hub-addons)

for app in "$SPOKE_DIR"/*.yaml; do
  [ -e "$app" ] || continue
  base="$(basename "$app")"
  found=1
  kind="$(yq -r '.kind' "$app")"
  [ "$kind" = "ApplicationSet" ] || { echo "FAIL[$base]: kind is $kind, want ApplicationSet (ADR-0010)"; FAIL=1; continue; }

  # goTemplate + missingkey=error: a registration Secret missing a contract
  # key must fail generation loudly, never render an empty value.
  gt="$(yq -r '.spec.goTemplate' "$app")"
  gto="$(yq -r '.spec.goTemplateOptions[0]' "$app")"
  [ "$gt" = "true" ] && echo "ok[$base]: goTemplate=true" \
    || { echo "FAIL[$base]: spec.goTemplate must be true"; FAIL=1; }
  [ "$gto" = "missingkey=error" ] && echo "ok[$base]: goTemplateOptions missingkey=error" \
    || { echo "FAIL[$base]: goTemplateOptions[0] must be missingkey=error (got $gto)"; FAIL=1; }

  # A deleted/relabeled cluster Secret must never cascade-delete live spoke
  # workloads (ADR-0010 review MINOR-3).
  prd="$(yq -r '.spec.syncPolicy.preserveResourcesOnDeletion' "$app")"
  [ "$prd" = "true" ] && echo "ok[$base]: preserveResourcesOnDeletion=true" \
    || { echo "FAIL[$base]: spec.syncPolicy.preserveResourcesOnDeletion must be true"; FAIL=1; }

  # Exactly one clusters generator selecting the spoke role label.
  ngen="$(yq -r '.spec.generators | length' "$app")"
  [ "$ngen" = "1" ] || { echo "FAIL[$base]: expected exactly 1 generator, got $ngen"; FAIL=1; }
  role="$(yq -r '.spec.generators[0].clusters.selector.matchLabels."k8-platform.io/cluster-role"' "$app")"
  [ "$role" = "spoke" ] && echo "ok[$base]: clusters generator selects cluster-role=spoke" \
    || { echo "FAIL[$base]: generator must select k8-platform.io/cluster-role=spoke (got $role)"; FAIL=1; }

  proj="$(yq -r '.spec.template.spec.project' "$app")"
  dname="$(yq -r '.spec.template.spec.destination.name' "$app")"
  dserver="$(yq -r '.spec.template.spec.destination.server' "$app")"

  # Branch on PROJECT rather than excluding a file by NAME: a real spoke app
  # that accidentally sets destination.server must still FAIL, and a hub app
  # that drifts into the spoke project must FAIL too.
  #   - k8-platform : never allowed here (locked first-party hub project).
  #   - hub-addons  : the one allowed hub-destination exception (Grafana Alloy
  #                   agent) — generator reads the SPOKE Secret for facts but
  #                   the template hard-codes the hub destination (ADR-0010
  #                   reverses auto-008 F1 deliberately; see the file header).
  #   - platform-spoke: the normal spoke-app contract (destination from the
  #                   generator, never a server).
  if [ "$proj" = "k8-platform" ]; then
    echo "FAIL[$base]: template project=k8-platform not allowed under apps/spoke/"; FAIL=1; continue
  elif [ "$proj" = "hub-addons" ]; then
    hub_count=$((hub_count + 1))
    { [ "$dserver" = "https://kubernetes.default.svc" ] && [ "$dname" = "null" ]; } \
      && echo "ok[$base]: hub-addons template targets the hub by server" \
      || { echo "FAIL[$base]: hub-addons template must use destination.server=kubernetes.default.svc and no .name"; FAIL=1; }
  else
    [ "$proj" = "platform-spoke" ] && echo "ok[$base]: template project=platform-spoke" \
      || { echo "FAIL[$base]: template project=$proj, want platform-spoke (or hub-addons for the hub agent)"; FAIL=1; }
    # destination by NAME from the generator: the matched cluster Secret's
    # name ({{.name}}), NEVER a hard-coded cluster or the hub server.
    [ "$dname" = '{{.name}}' ] && echo "ok[$base]: template destination.name={{.name}}" \
      || { echo "FAIL[$base]: template destination.name must be '{{.name}}' (got $dname)"; FAIL=1; }
    [ "$dserver" = "null" ] || { echo "FAIL[$base]: template destination.server set ($dserver) — spokes are by generated name"; FAIL=1; }
    # Generated Application names carry the short-name prefix so today's
    # names (spoke-*, workload1-*) are preserved (PR #210's live check keys
    # on spoke-hello).
    tname="$(yq -r '.spec.template.metadata.name' "$app")"
    case "$tname" in
      '{{index .metadata.labels "k8-platform.io/short-name"}}-'*)
        echo "ok[$base]: template name is short-name-prefixed ($tname)";;
      *)
        echo "FAIL[$base]: template metadata.name must start with the short-name label template (got $tname)"; FAIL=1;;
    esac
  fi

  # every template source's targetRevision must be pinned, not HEAD/empty.
  revs="$(yq -r '[.spec.template.spec.source.targetRevision] + [.spec.template.spec.sources[]?.targetRevision] | .[] | select(. != null)' "$app")"
  [ -n "$revs" ] || { echo "FAIL[$base]: no targetRevision found on any template source"; FAIL=1; }
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    case "$r" in
      HEAD|null) echo "FAIL[$base]: targetRevision '$r' not pinned"; FAIL=1;;
      *) :;;
    esac
  done <<< "$revs"
  echo "ok[$base]: all template source targetRevisions pinned"

  # automated prune + selfHeal on the generated Applications.
  prune="$(yq -r '.spec.template.spec.syncPolicy.automated.prune' "$app")"
  sh="$(yq -r '.spec.template.spec.syncPolicy.automated.selfHeal' "$app")"
  { [ "$prune" = "true" ] && [ "$sh" = "true" ]; } && echo "ok[$base]: automated prune+selfHeal" \
    || { echo "FAIL[$base]: generated apps need automated prune+selfHeal (prune=$prune selfHeal=$sh)"; FAIL=1; }

  # sync-wave must ride the GENERATED Application (template metadata) — waves
  # on the ApplicationSet object itself order nothing (ADR-0010 review M2).
  wave="$(yq -r '.spec.template.metadata.annotations."argocd.argoproj.io/sync-wave"' "$app")"
  [ "$wave" != "null" ] && [ -n "$wave" ] && echo "ok[$base]: template sync-wave=$wave" \
    || { echo "FAIL[$base]: missing argocd.argoproj.io/sync-wave on template metadata"; FAIL=1; }
done

[ "$found" -eq 1 ] || { echo "FAIL: no spoke appsets found under $SPOKE_DIR"; FAIL=1; }

# Exactly ONE appset in this dir may target the hub (the Alloy agent). More than
# one means a spoke app silently drifted to the hub destination; zero means the
# Alloy agent regressed.
[ "$hub_count" -eq 1 ] && echo "ok: exactly one hub-addons appset under apps/spoke/ (the Alloy agent)" \
  || { echo "FAIL: expected exactly 1 hub-addons appset under apps/spoke/, found $hub_count"; FAIL=1; }

[ "$FAIL" -eq 0 ] && echo "PASS: spoke ApplicationSet contracts" || echo "FAILED"
exit "$FAIL"
