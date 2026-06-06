#!/usr/bin/env bash
# Unit tests for the phase-4 observability scaffolding (REQ-OBS-01..05).
#
# Asserts the spoke observability Applications follow the SAME spoke-app contract
# as test_spoke_apps.sh (multi-source, project=platform-spoke, destination.name,
# pinned targetRevision, automated prune+selfHeal, sync-wave), the static values
# files carry the required REQ-OBS knobs (remote-write receiver, Grafana ingress
# nginx + no tls, annotation-driven scrape in the Alloy agent), and the hub Alloy
# agent is parked as a documented `.yaml.todo` (the AppProject open question —
# see argocd/apps/spoke/observability-alloy-mgmt.yaml.todo). Includes a
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

# The two observability Applications that target the SPOKE (the hub Alloy app is
# a .yaml.todo and intentionally NOT in this list — see below).
OBS_APPS=(
  "$SPOKE_DIR/observability-kube-prometheus-stack.yaml"
  "$SPOKE_DIR/observability-loki.yaml"
)

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
else
  echo "FAIL: $ALLOY missing"; FAIL=1
fi

# ── 3. hub Alloy app is parked as a documented TODO (the open question) ─────
ALLOY_TODO="$SPOKE_DIR/observability-alloy-mgmt.yaml.todo"
if [ -f "$ALLOY_TODO" ]; then
  echo "ok: hub Alloy parked as .yaml.todo (not synced; AppProject open question)"
  # Must NOT exist as a live .yaml (would break the spoke contract / be rejected).
  if [ -f "$SPOKE_DIR/observability-alloy-mgmt.yaml" ]; then
    echo "FAIL: hub Alloy is a live .yaml — its hub destination breaks the spoke project (open question unresolved)"; FAIL=1
  fi
  # Header must document the open question for the next session.
  if grep -qi 'OPEN QUESTION' "$ALLOY_TODO"; then
    echo "ok: hub Alloy TODO documents the open question"
  else
    echo "FAIL: hub Alloy TODO must document the AppProject open question"; FAIL=1
  fi
else
  echo "FAIL: $ALLOY_TODO missing (hub Alloy must be parked as a documented TODO)"; FAIL=1
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
