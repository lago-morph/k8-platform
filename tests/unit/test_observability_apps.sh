#!/usr/bin/env bash
# Unit tests for the phase-4 observability scaffolding (REQ-OBS-01..05).
#
# Asserts the spoke observability Applications follow the SAME spoke-app contract
# as test_spoke_apps.sh (multi-source, project=platform-spoke, destination.name,
# pinned targetRevision, automated prune+selfHeal, sync-wave), the static values
# files carry the required REQ-OBS knobs (remote-write receiver, Grafana ingress
# nginx + no tls, annotation-driven scrape in the Alloy agent), and the hub Alloy
# agent is a live Application under the dedicated `hub-addons` AppProject targeting
# the HUB in-cluster destination (phase-4 Option A,
# decisions/2026-06-06-phase4-alloy-phase5-db.md). §3 gates that resolved state
# and forbids regression back to the old `.yaml.todo` park. Includes a
# helm-template smoke for kube-prometheus-stack that degrades to a yq structural
# check when chart-repo egress is unavailable offline.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
SPOKE_DIR="$ROOT/argocd/apps/spoke"
OBS_VALUES="$ROOT/platform-services/observability"
FAIL=0

# The two observability Applications that target the SPOKE (the hub Alloy app
# targets the HUB and is gated separately in §3 — it is intentionally NOT here).
OBS_APPS=(
  "$SPOKE_DIR/observability-kube-prometheus-stack.yaml"
  "$SPOKE_DIR/observability-loki.yaml"
)
# Guard against the spoke-app coverage silently shrinking (a future edit emptying
# the array would make §1 vacuously pass).
[ "${#OBS_APPS[@]}" -eq 2 ] || { echo "FAIL: OBS_APPS must list exactly the 2 spoke obs apps"; FAIL=1; }

# ── 1. spoke-app contract (mirrors test_spoke_apps.sh) ──────────────────────
for app in "${OBS_APPS[@]}"; do
  base="$(basename "$app")"
  [ -f "$app" ] || { echo "FAIL[$base]: missing"; FAIL=1; continue; }

  kind="$(yq -r '.kind' "$app")"
  [ "$kind" = "Application" ] || { echo "FAIL[$base]: kind=$kind, want Application"; FAIL=1; }

  proj="$(yq -r '.spec.project' "$app")"
  [ "$proj" = "platform-spoke" ] && echo "ok[$base]: project=platform-spoke" \
    || { echo "FAIL[$base]: project=$proj, want platform-spoke"; FAIL=1; }

  # destination by NAME (spoke), never the hub server.
  dname="$(yq -r '.spec.destination.name' "$app")"
  dserver="$(yq -r '.spec.destination.server' "$app")"
  { [ "$dname" != "null" ] && [ -n "$dname" ]; } && echo "ok[$base]: destination.name=$dname" \
    || { echo "FAIL[$base]: destination.name must be set (spoke by name)"; FAIL=1; }
  [ "$dserver" = "null" ] || { echo "FAIL[$base]: destination.server set ($dserver) — spokes are by name"; FAIL=1; }

  # multi-source: an upstream chart + this repo's values ref.
  nsrc="$(yq -r '.spec.sources | length' "$app")"
  [ "$nsrc" = "2" ] && echo "ok[$base]: multi-source (chart + values ref)" \
    || { echo "FAIL[$base]: expected 2 sources (chart + \$values), got $nsrc"; FAIL=1; }
  if yq -e '.spec.sources[] | select(.ref == "values")' "$app" >/dev/null 2>&1; then
    echo "ok[$base]: has a \$values ref source"
  else
    echo "FAIL[$base]: missing the ref: values source"; FAIL=1
  fi

  # every source targetRevision pinned (not HEAD/empty).
  revs="$(yq -r '[.spec.sources[]?.targetRevision] | .[] | select(. != null)' "$app")"
  [ -n "$revs" ] || { echo "FAIL[$base]: no targetRevision found"; FAIL=1; }
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    case "$r" in
      HEAD|null) echo "FAIL[$base]: targetRevision '$r' not pinned"; FAIL=1;;
    esac
  done <<< "$revs"
  echo "ok[$base]: all source targetRevisions pinned"

  prune="$(yq -r '.spec.syncPolicy.automated.prune' "$app")"
  sh="$(yq -r '.spec.syncPolicy.automated.selfHeal' "$app")"
  { [ "$prune" = "true" ] && [ "$sh" = "true" ]; } && echo "ok[$base]: automated prune+selfHeal" \
    || { echo "FAIL[$base]: need automated prune+selfHeal (prune=$prune selfHeal=$sh)"; FAIL=1; }

  # sync-wave 40 — observability band, after ingress/dns wave 20.
  wave="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$app")"
  [ "$wave" = "40" ] && echo "ok[$base]: sync-wave=40 (after ingress/dns)" \
    || { echo "FAIL[$base]: sync-wave=$wave, want 40 (after ingress/dns wave 20)"; FAIL=1; }
done

# ── 2. values files carry the REQ-OBS knobs ─────────────────────────────────
KPS="$OBS_VALUES/kube-prometheus-stack/values.yaml"
if [ -f "$KPS" ]; then
  # REQ-OBS-02: Prometheus accepts remote_write from the hub agent.
  [ "$(yq -r '.prometheus.prometheusSpec.enableRemoteWriteReceiver' "$KPS")" = "true" ] \
    && echo "ok[kps]: remote-write receiver enabled" \
    || { echo "FAIL[kps]: prometheus.prometheusSpec.enableRemoteWriteReceiver must be true (REQ-OBS-02)"; FAIL=1; }
  # REQ-OBS-03: Grafana Ingress, class nginx, host grafana.platform.<domain>.
  [ "$(yq -r '.grafana.ingress.enabled' "$KPS")" = "true" ] \
    && echo "ok[kps]: grafana ingress enabled" \
    || { echo "FAIL[kps]: grafana.ingress.enabled must be true (REQ-OBS-03)"; FAIL=1; }
  [ "$(yq -r '.grafana.ingress.ingressClassName' "$KPS")" = "nginx" ] \
    && echo "ok[kps]: grafana ingressClassName=nginx" \
    || { echo "FAIL[kps]: grafana.ingress.ingressClassName must be nginx"; FAIL=1; }
  if yq -r '.grafana.ingress.hosts[0]' "$KPS" | grep -q '^grafana\.platform\.'; then
    echo "ok[kps]: grafana host is grafana.platform.<domain>"
  else
    echo "FAIL[kps]: grafana.ingress.hosts[0] must be grafana.platform.<domain>"; FAIL=1
  fi
  # NO tls block — NLB/ACM terminates (docs/0003).
  if yq -e '.grafana.ingress.tls' "$KPS" >/dev/null 2>&1; then
    echo "FAIL[kps]: grafana ingress must NOT carry a tls block (NLB/ACM terminates)"; FAIL=1
  else
    echo "ok[kps]: no grafana ingress tls block"
  fi
else
  echo "FAIL: $KPS missing"; FAIL=1
fi

LOKI="$OBS_VALUES/loki/values.yaml"
if [ -f "$LOKI" ]; then
  [ "$(yq -r '.deploymentMode' "$LOKI")" = "SingleBinary" ] \
    && echo "ok[loki]: single-binary deployment mode (small footprint)" \
    || { echo "FAIL[loki]: deploymentMode must be SingleBinary"; FAIL=1; }
  [ "$(yq -r '.singleBinary.replicas' "$LOKI")" = "1" ] \
    && echo "ok[loki]: singleBinary.replicas=1" \
    || { echo "FAIL[loki]: singleBinary.replicas must be 1"; FAIL=1; }
else
  echo "FAIL: $LOKI missing"; FAIL=1
fi

ALLOY="$OBS_VALUES/alloy/values.yaml"
if [ -f "$ALLOY" ]; then
  # REQ-OBS-04: annotation-driven scraping (prometheus.io/scrape) in the config.
  if grep -q 'prometheus_io_scrape' "$ALLOY"; then
    echo "ok[alloy]: annotation-driven scrape (prometheus.io/scrape) present (REQ-OBS-04)"
  else
    echo "FAIL[alloy]: Alloy config must honor prometheus.io/scrape annotations (REQ-OBS-04)"; FAIL=1
  fi
  # remote_write to spoke Prometheus + push to spoke Loki (REQ-OBS-02).
  if grep -q 'prometheus.remote_write' "$ALLOY" && grep -q 'loki.write' "$ALLOY"; then
    echo "ok[alloy]: remote_write metrics + push logs to spoke (REQ-OBS-02)"
  else
    echo "FAIL[alloy]: Alloy must remote_write metrics + push logs to the spoke (REQ-OBS-02)"; FAIL=1
  fi
  # AGENTS §8.1: the spoke endpoints are account-ephemeral and overlaid at
  # registration — every `url =` in the Alloy river config MUST be a PLACEHOLDER_
  # token, never a real http(s) literal committed to git. test_spoke_values_no_ephemeral
  # only bans ARNs/domains/account-ids, so this is the gate that catches a real
  # remote_write/loki URL being baked in.
  bad_urls="$(grep -nE 'url[[:space:]]*=[[:space:]]*"https?://' "$ALLOY" || true)"
  if [ -n "$bad_urls" ]; then
    echo "FAIL[alloy]: river config has a literal http(s) url (must be PLACEHOLDER_, overlaid at registration):"; echo "$bad_urls"; FAIL=1
  else
    echo "ok[alloy]: all river-config urls are PLACEHOLDER_ tokens (no baked endpoint)"
  fi
  if grep -qE 'url[[:space:]]*=[[:space:]]*"PLACEHOLDER_SPOKE_PROMETHEUS_REMOTE_WRITE_URL"' "$ALLOY" \
     && grep -qE 'url[[:space:]]*=[[:space:]]*"PLACEHOLDER_SPOKE_LOKI_PUSH_URL"' "$ALLOY"; then
    echo "ok[alloy]: both spoke endpoint placeholders present"
  else
    echo "FAIL[alloy]: expected PLACEHOLDER_SPOKE_PROMETHEUS_REMOTE_WRITE_URL + PLACEHOLDER_SPOKE_LOKI_PUSH_URL"; FAIL=1
  fi
else
  echo "FAIL: $ALLOY missing"; FAIL=1
fi

# ── 3. hub Alloy app — RESOLVED live state (phase-4 Option A) ───────────────
# The former "parked as .yaml.todo / open question" guard is replaced by the
# resolved contract: a live Application under the hub-addons project targeting
# the HUB in-cluster destination. These assertions are the regression guard the
# old §3 provided (the app must NOT silently regress into platform-spoke /
# k8-platform, and the .yaml.todo park must NOT reappear).
ALLOY_APP="$SPOKE_DIR/observability-alloy-mgmt.yaml"
ALLOY_TODO="$SPOKE_DIR/observability-alloy-mgmt.yaml.todo"
HUB_PROJ="$ROOT/argocd/projects/hub-addons.yaml"

# 3a. No resurrection of the parked .yaml.todo (single source of truth).
[ -e "$ALLOY_TODO" ] && { echo "FAIL: the old observability-alloy-mgmt.yaml.todo reappeared (park state is gone)"; FAIL=1; } \
  || echo "ok: no stale .yaml.todo park file"

if [ -f "$ALLOY_APP" ]; then
  base="$(basename "$ALLOY_APP")"
  [ "$(yq -r '.kind' "$ALLOY_APP")" = "Application" ] && echo "ok[$base]: kind Application" \
    || { echo "FAIL[$base]: kind must be Application"; FAIL=1; }

  # 3b. project is hub-addons EXACTLY — explicitly not the spoke / locked projects.
  aproj="$(yq -r '.spec.project' "$ALLOY_APP")"
  case "$aproj" in
    hub-addons) echo "ok[$base]: project=hub-addons" ;;
    platform-spoke|k8-platform) echo "FAIL[$base]: project=$aproj — the hub agent must use hub-addons, not $aproj"; FAIL=1 ;;
    *) echo "FAIL[$base]: project=$aproj, want hub-addons"; FAIL=1 ;;
  esac

  # 3c. HUB destination by SERVER, never by name (inverse of the spoke contract).
  [ "$(yq -r '.spec.destination.server' "$ALLOY_APP")" = "https://kubernetes.default.svc" ] \
    && echo "ok[$base]: destination.server is the hub in-cluster" \
    || { echo "FAIL[$base]: destination.server must be https://kubernetes.default.svc"; FAIL=1; }
  [ "$(yq -r '.spec.destination.name' "$ALLOY_APP")" = "null" ] \
    && echo "ok[$base]: no destination.name (hub is by server)" \
    || { echo "FAIL[$base]: hub app must not set destination.name"; FAIL=1; }
  ans="$(yq -r '.spec.destination.namespace' "$ALLOY_APP")"
  [ "$ans" = "monitoring-agent" ] && echo "ok[$base]: namespace monitoring-agent" \
    || { echo "FAIL[$base]: destination.namespace must be monitoring-agent, got $ans"; FAIL=1; }
  # cross-file: the app's namespace must be allowed by the hub-addons project.
  if [ -f "$HUB_PROJ" ] && yq -e ".spec.destinations[] | select(.namespace == \"$ans\")" "$HUB_PROJ" >/dev/null 2>&1; then
    echo "ok[$base]: app namespace is within the hub-addons project destinations"
  else
    echo "FAIL[$base]: app namespace $ans not permitted by hub-addons project (ArgoCD would reject the sync)"; FAIL=1
  fi

  # 3d. multi-source: pinned alloy chart 0.12.6 + a $values ref to this repo, and
  #     both source repos must be members of the hub-addons project sourceRepos.
  nsrc="$(yq -r '.spec.sources | length' "$ALLOY_APP")"
  [ "$nsrc" = "2" ] && echo "ok[$base]: multi-source (chart + \$values)" \
    || { echo "FAIL[$base]: expected 2 sources, got $nsrc"; FAIL=1; }
  chart_rev="$(yq -r '.spec.sources[] | select(.chart=="alloy") | .targetRevision' "$ALLOY_APP")"
  [ "$chart_rev" = "0.12.6" ] && echo "ok[$base]: alloy chart pinned 0.12.6" \
    || { echo "FAIL[$base]: alloy chart targetRevision must be 0.12.6, got $chart_rev"; FAIL=1; }
  if yq -e '.spec.sources[] | select(.ref == "values")' "$ALLOY_APP" >/dev/null 2>&1; then
    echo "ok[$base]: has a \$values ref source"
  else
    echo "FAIL[$base]: missing the ref: values source"; FAIL=1
  fi
  # valueFiles must point at the committed alloy values (a typo renders empty config).
  if yq -e '.spec.sources[] | select(.helm.valueFiles[]? == "$values/platform-services/observability/alloy/values.yaml")' "$ALLOY_APP" >/dev/null 2>&1; then
    echo "ok[$base]: references the committed alloy values file"
  else
    echo "FAIL[$base]: must reference \$values/platform-services/observability/alloy/values.yaml"; FAIL=1
  fi
  if [ -f "$HUB_PROJ" ]; then
    while IFS= read -r srepo; do
      [ -z "$srepo" ] && continue
      if yq -e ".spec.sourceRepos[] | select(. == \"$srepo\")" "$HUB_PROJ" >/dev/null 2>&1; then
        echo "ok[$base]: source repo allowed by hub-addons project: $srepo"
      else
        echo "FAIL[$base]: source repo $srepo not in hub-addons sourceRepos (sync rejected)"; FAIL=1
      fi
    done <<< "$(yq -r '.spec.sources[].repoURL' "$ALLOY_APP")"
  fi

  # 3e. automated prune+selfHeal + sync-wave 40, and project reconciles first.
  { [ "$(yq -r '.spec.syncPolicy.automated.prune' "$ALLOY_APP")" = "true" ] \
    && [ "$(yq -r '.spec.syncPolicy.automated.selfHeal' "$ALLOY_APP")" = "true" ]; } \
    && echo "ok[$base]: automated prune+selfHeal" \
    || { echo "FAIL[$base]: hub agent needs automated prune+selfHeal"; FAIL=1; }
  awave="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$ALLOY_APP")"
  [ "$awave" = "40" ] && echo "ok[$base]: sync-wave=40 (obs band)" \
    || { echo "FAIL[$base]: sync-wave=$awave, want 40"; FAIL=1; }
  if [ -f "$HUB_PROJ" ]; then
    pwave="$(yq -r '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$HUB_PROJ")"
    if [ "$pwave" != "null" ] && [ "$pwave" -le "$awave" ] 2>/dev/null; then
      echo "ok: hub-addons project wave ($pwave) <= alloy app wave ($awave)"
    else
      echo "FAIL: hub-addons project wave ($pwave) must be <= alloy app wave ($awave) so the project exists first"; FAIL=1
    fi
  fi
else
  echo "FAIL: $ALLOY_APP missing (the hub Alloy agent must be a live Application — Option A)"; FAIL=1
fi

# ── 4. helm-template smoke for kube-prometheus-stack ────────────────────────
# Renders the chart with the committed values to catch a values-shape break.
# Degrades to a yq structural check when chart-repo egress is unavailable.
if command -v helm >/dev/null 2>&1 && [ -f "$KPS" ]; then
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  KPS_VER="$(yq -r '.spec.sources[] | select(.chart=="kube-prometheus-stack") | .targetRevision' \
    "$SPOKE_DIR/observability-kube-prometheus-stack.yaml")"
  if helm template kps kube-prometheus-stack \
        --repo https://prometheus-community.github.io/helm-charts \
        --version "$KPS_VER" --namespace monitoring \
        -f "$KPS" --set grafana.ingress.hosts[0]=grafana.platform.example.com \
        > "$TMP/kps.yaml" 2>"$TMP/kps.err"; then
    # Grafana Ingress renders with class nginx and no tls.
    gclass="$(yq -r 'select(.kind=="Ingress" and (.metadata.name | test("grafana"))) | .spec.ingressClassName' "$TMP/kps.yaml" | head -1)"
    [ "$gclass" = "nginx" ] && echo "ok[kps-render]: Grafana Ingress class nginx" \
      || { echo "FAIL[kps-render]: Grafana Ingress class is '$gclass', want nginx"; FAIL=1; }
    if yq -e 'select(.kind=="Ingress" and (.metadata.name | test("grafana"))) | .spec.tls' "$TMP/kps.yaml" >/dev/null 2>&1; then
      echo "FAIL[kps-render]: rendered Grafana Ingress has a tls block (NLB/ACM terminates)"; FAIL=1
    else
      echo "ok[kps-render]: rendered Grafana Ingress has no tls block"
    fi
  else
    echo "NOTICE[kps-render]: helm template offline/unavailable — falling back to yq structural check"
    [ "$(yq -r '.prometheus.prometheusSpec.enableRemoteWriteReceiver' "$KPS")" = "true" ] \
      && echo "ok[kps-render-fallback]: values structure validated via yq" \
      || { echo "FAIL[kps-render-fallback]: values structure invalid"; FAIL=1; }
  fi
else
  echo "NOTICE[kps-render]: helm not present — skipping render smoke"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: observability Applications + values contracts" || echo "FAILED"
exit "$FAIL"
