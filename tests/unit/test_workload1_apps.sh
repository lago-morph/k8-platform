#!/usr/bin/env bash
# Unit tests for the phase-6 workload1 cluster scaffolding (REQ-WL-01..05).
#
# Three assertion groups:
#   1. Spoke-app contract for the workload1 add-on Applications
#      (argocd/apps/spoke/workload1-*.yaml): plain Applications under the
#      platform-spoke project, destination.name=workload1-spoke (NEVER the hub
#      server), pinned source revisions, automated prune+selfHeal, sync-wave
#      present (20/20/30). Same shape as test_spoke_apps.sh, narrowed to the
#      workload1-* files so this file is their dedicated gate.
#   2. The cluster-creation Application (argocd/apps/workload1-cluster.yaml) is
#      MANUAL-SYNC: project=k8-platform, no syncPolicy.automated block, header
#      documents the manual-sync choice (the literal test_argocd_app_revision_
#      pinned.sh keys on), path resolves to clusters/workload1, and the XR +
#      namespace it ships are well-formed.
#   3. The workload1 external-dns scoping is DISJOINT from BOTH the hub
#      (management.<domain> / k8-platform-mgmt) AND the platform spoke
#      (platform.<domain> / k8-platform-platform) — extends the disjoint-filter
#      idea in test_external_dns_disjoint_filters.sh to the THIRD instance, since
#      all three share the one account Route53 zone (auto-008 §6 / S3).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
SPOKE_DIR="$ROOT/argocd/apps/spoke"
FAIL=0

# ───────────────────────────────────────────────────────────────────────────
# 1. Spoke-app contract for the workload1-* add-on Applications.
# ───────────────────────────────────────────────────────────────────────────
found=0
for app in "$SPOKE_DIR"/workload1-*.yaml; do
  [ -e "$app" ] || continue
  base="$(basename "$app")"
  found=1

  kind="$(yq -r '.kind' "$app")"
  [ "$kind" = "Application" ] || { echo "FAIL[$base]: kind is $kind, want Application"; FAIL=1; continue; }

  # project must be the dedicated spoke project (NOT k8-platform).
  proj="$(yq -r '.spec.project' "$app")"
  [ "$proj" = "platform-spoke" ] && echo "ok[$base]: project=platform-spoke" \
    || { echo "FAIL[$base]: project=$proj, want platform-spoke"; FAIL=1; }

  # destination by NAME = workload1-spoke; the hub server must NOT be set.
  dname="$(yq -r '.spec.destination.name' "$app")"
  dserver="$(yq -r '.spec.destination.server' "$app")"
  [ "$dname" = "workload1-spoke" ] && echo "ok[$base]: destination.name=workload1-spoke" \
    || { echo "FAIL[$base]: destination.name=$dname, want workload1-spoke"; FAIL=1; }
  [ "$dserver" = "null" ] || { echo "FAIL[$base]: destination.server set ($dserver) — spokes are by name"; FAIL=1; }

  # every source's targetRevision pinned (main / a version), not HEAD/empty.
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

  # automated prune + selfHeal (add-ons self-heal; the manual carve-out is the
  # cluster XR, which is NOT in this dir).
  prune="$(yq -r '.spec.syncPolicy.automated.prune' "$app")"
  sh="$(yq -r '.spec.syncPolicy.automated.selfHeal' "$app")"
  { [ "$prune" = "true" ] && [ "$sh" = "true" ]; } && echo "ok[$base]: automated prune+selfHeal" \
    || { echo "FAIL[$base]: workload1 spoke apps need automated prune+selfHeal (prune=$prune selfHeal=$sh)"; FAIL=1; }

  # sync-wave present.
  wave="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$app")"
  [ "$wave" != "null" ] && [ -n "$wave" ] && echo "ok[$base]: sync-wave=$wave" \
    || { echo "FAIL[$base]: missing argocd.argoproj.io/sync-wave annotation"; FAIL=1; }
done

[ "$found" -eq 1 ] || { echo "FAIL: no workload1-* spoke apps found under $SPOKE_DIR"; FAIL=1; }

# Assert the three expected spoke apps exist with the right sync-waves
# (ingress 20, external-dns 20, hello 30 — ordering ingress/dns < hello).
assert_wave() {
  local f="$SPOKE_DIR/$1" want="$2"
  [ -f "$f" ] || { echo "FAIL: expected $f missing"; FAIL=1; return; }
  local got; got="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$f")"
  [ "$got" = "$want" ] && echo "ok[$1]: sync-wave=$want" \
    || { echo "FAIL[$1]: sync-wave=$got, want $want"; FAIL=1; }
}
assert_wave "workload1-ingress-nginx.yaml" "20"
assert_wave "workload1-external-dns.yaml" "20"
assert_wave "workload1-hello.yaml" "30"

# hello publishes to the workload1 subdomain (disjoint from the platform spoke's).
hello_sub="$(yq -r '.spec.source.helm.valuesObject.subdomain' "$SPOKE_DIR/workload1-hello.yaml")"
[ "$hello_sub" = "workload1" ] && echo "ok: workload1-hello subdomain=workload1" \
  || { echo "FAIL: workload1-hello subdomain=$hello_sub, want workload1"; FAIL=1; }

# ───────────────────────────────────────────────────────────────────────────
# 2. The cluster-creation Application is MANUAL-SYNC.
# ───────────────────────────────────────────────────────────────────────────
CLUSTER_APP="$ROOT/argocd/apps/workload1-cluster.yaml"
[ -f "$CLUSTER_APP" ] || { echo "FAIL: $CLUSTER_APP missing"; FAIL=1; }

if [ -f "$CLUSTER_APP" ]; then
  cproj="$(yq -r '.spec.project' "$CLUSTER_APP")"
  [ "$cproj" = "k8-platform" ] && echo "ok[workload1-cluster]: project=k8-platform" \
    || { echo "FAIL[workload1-cluster]: project=$cproj, want k8-platform"; FAIL=1; }

  # No automated sync block (manual sync only).
  cauto="$(yq -r '.spec.syncPolicy.automated' "$CLUSTER_APP")"
  [ "$cauto" = "null" ] && echo "ok[workload1-cluster]: no syncPolicy.automated (manual sync)" \
    || { echo "FAIL[workload1-cluster]: syncPolicy.automated present — must be manual sync"; FAIL=1; }

  # Header documents the manual-sync choice (the literal test_argocd_app_revision_
  # pinned.sh keys on to accept the absent automated block).
  if grep -q "manual sync only\|without automated sync\|no syncPolicy.automated" "$CLUSTER_APP"; then
    echo "ok[workload1-cluster]: manual-sync choice documented in header"
  else
    echo "FAIL[workload1-cluster]: header must document the manual-sync choice"; FAIL=1
  fi

  # path resolves to clusters/workload1 (a real dir).
  cpath="$(yq -r '.spec.source.path' "$CLUSTER_APP")"
  [ "$cpath" = "clusters/workload1" ] && [ -d "$ROOT/$cpath" ] \
    && echo "ok[workload1-cluster]: source.path=clusters/workload1 (exists)" \
    || { echo "FAIL[workload1-cluster]: source.path=$cpath not clusters/workload1 or missing"; FAIL=1; }

  crev="$(yq -r '.spec.source.targetRevision' "$CLUSTER_APP")"
  case "$crev" in
    ""|null|HEAD) echo "FAIL[workload1-cluster]: targetRevision '$crev' not pinned"; FAIL=1;;
    *) echo "ok[workload1-cluster]: targetRevision pinned ($crev)";;
  esac
fi

# The XR + namespace the cluster app ships are well-formed.
XR="$ROOT/clusters/workload1/workload-cluster.yaml"
NS="$ROOT/clusters/workload1/00-namespace.yaml"
[ -f "$XR" ] || { echo "FAIL: $XR missing"; FAIL=1; }
[ -f "$NS" ] || { echo "FAIL: $NS missing"; FAIL=1; }

if [ -f "$XR" ]; then
  xkind="$(yq -r '.kind' "$XR")"
  [ "$xkind" = "XPlatformCluster" ] && echo "ok[XR]: kind=XPlatformCluster (XRD reuse)" \
    || { echo "FAIL[XR]: kind=$xkind, want XPlatformCluster"; FAIL=1; }
  xns="$(yq -r '.metadata.namespace' "$XR")"
  [ "$xns" = "workload1" ] && echo "ok[XR]: namespace=workload1 (v2 namespaced XR)" \
    || { echo "FAIL[XR]: namespace=$xns, want workload1"; FAIL=1; }
  xname="$(yq -r '.spec.name' "$XR")"
  [ "$xname" = "k8-platform-workload1" ] && echo "ok[XR]: spec.name=k8-platform-workload1" \
    || { echo "FAIL[XR]: spec.name=$xname, want k8-platform-workload1"; FAIL=1; }
  xsub="$(yq -r '.spec.dns.subdomain' "$XR")"
  [ "$xsub" = "workload1" ] && echo "ok[XR]: dns.subdomain=workload1" \
    || { echo "FAIL[XR]: dns.subdomain=$xsub, want workload1"; FAIL=1; }
  xwave="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$XR")"
  [ "$xwave" = "10" ] && echo "ok[XR]: sync-wave=10 (mirrors platform XR)" \
    || { echo "FAIL[XR]: sync-wave=$xwave, want 10"; FAIL=1; }
fi

if [ -f "$NS" ]; then
  nsname="$(yq -r '.metadata.name' "$NS")"
  nskind="$(yq -r '.kind' "$NS")"
  { [ "$nskind" = "Namespace" ] && [ "$nsname" = "workload1" ]; } \
    && echo "ok[NS]: Namespace workload1" \
    || { echo "FAIL[NS]: kind=$nskind name=$nsname, want Namespace/workload1"; FAIL=1; }
fi

# ───────────────────────────────────────────────────────────────────────────
# 3. workload1 external-dns scoping disjoint from BOTH hub AND platform spoke.
# ───────────────────────────────────────────────────────────────────────────
WL_VALUES="$ROOT/platform-services/external-dns/workload1-values.yaml"
PLAT_VALUES="$ROOT/platform-services/external-dns/values.yaml"
HELM_TF="$ROOT/terraform/management/helm.tf"
[ -f "$WL_VALUES" ] || { echo "FAIL: $WL_VALUES missing"; FAIL=1; }

if [ -f "$WL_VALUES" ]; then
  wl_filter="$(yq -r '.domainFilters[0]' "$WL_VALUES")"
  wl_owner="$(yq -r '.txtOwnerId' "$WL_VALUES")"
  wl_prefix="$(yq -r '.txtPrefix' "$WL_VALUES")"

  # workload1 scoping itself.
  case "$wl_filter" in
    workload1.*) echo "ok: workload1 domainFilters scoped to workload1.<domain> ($wl_filter)";;
    *) echo "FAIL: workload1 domainFilters[0] must be workload1.<...> (found: $wl_filter)"; FAIL=1;;
  esac
  [ "$wl_owner" = "k8-platform-workload1" ] && echo "ok: workload1 txtOwnerId = k8-platform-workload1" \
    || { echo "FAIL: workload1 txtOwnerId must be k8-platform-workload1 (found: $wl_owner)"; FAIL=1; }
  { [ -n "$wl_prefix" ] && [ "$wl_prefix" != "null" ]; } && echo "ok: workload1 txtPrefix set ($wl_prefix)" \
    || { echo "FAIL: workload1 txtPrefix must be set (distinct TXT names)"; FAIL=1; }

  # Disjoint from the PLATFORM spoke.
  if [ -f "$PLAT_VALUES" ]; then
    plat_filter="$(yq -r '.domainFilters[0]' "$PLAT_VALUES")"
    plat_owner="$(yq -r '.txtOwnerId' "$PLAT_VALUES")"
    plat_prefix="$(yq -r '.txtPrefix' "$PLAT_VALUES")"
    [ "$wl_owner" != "$plat_owner" ] && echo "ok: workload1 txtOwnerId disjoint from platform ($plat_owner)" \
      || { echo "FAIL: workload1 txtOwnerId collides with platform spoke ($wl_owner)"; FAIL=1; }
    [ "$wl_filter" != "$plat_filter" ] && echo "ok: workload1 domainFilters disjoint from platform ($plat_filter)" \
      || { echo "FAIL: workload1 domainFilters collide with platform spoke ($wl_filter)"; FAIL=1; }
    [ "$wl_prefix" != "$plat_prefix" ] && echo "ok: workload1 txtPrefix disjoint from platform ($plat_prefix)" \
      || { echo "FAIL: workload1 txtPrefix collides with platform spoke ($wl_prefix)"; FAIL=1; }
  else
    echo "FAIL: platform spoke values ($PLAT_VALUES) missing — cannot check disjointness"; FAIL=1
  fi

  # Disjoint from the HUB (terraform/management/helm.tf — k8-platform-mgmt /
  # management.<domain>). Mirror test_external_dns_disjoint_filters.sh extraction.
  [ "$wl_owner" != "k8-platform-mgmt" ] && echo "ok: workload1 txtOwnerId disjoint from hub (k8-platform-mgmt)" \
    || { echo "FAIL: workload1 txtOwnerId collides with the hub (k8-platform-mgmt)"; FAIL=1; }
  case "$wl_filter" in
    management.*) echo "FAIL: workload1 domainFilters overlap the hub's management.<domain>"; FAIL=1;;
    *) echo "ok: workload1 domainFilters disjoint from hub (management.<domain>)";;
  esac
  if [ -f "$HELM_TF" ]; then
    hub_owner_line="$(grep -A2 'name  = "txtOwnerId"' "$HELM_TF" | grep 'value' | head -1)"
    if echo "$hub_owner_line" | grep -q '"k8-platform-mgmt"'; then
      echo "ok: hub txtOwnerId still k8-platform-mgmt (disjoint anchor intact)"
    else
      echo "FAIL: hub txtOwnerId changed unexpectedly (found: $hub_owner_line)"; FAIL=1
    fi
  fi
fi

[ "$FAIL" -eq 0 ] && echo "PASS: workload1 cluster + spoke apps + disjoint external-dns" || echo "FAILED"
exit "$FAIL"
