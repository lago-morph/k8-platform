#!/usr/bin/env bash
# Renders the in-repo hello chart and asserts the phase-3 contracts (REQ-PLAT-06):
# the Ingress host is hello.<subdomain>.<domain> with the domain overlaid (not a
# committed literal), the image is pinned (no :latest, bug #6 class), and the pod
# runs non-root. Catches the "templated host renders wrong / unpinned image"
# class before any spoke sync.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool helm
require_tool yq

CHART="$HERE/../../platform-services/hello"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAIL=0

# Overlay domain the way the ArgoCD Application does at sync time.
helm template hello "$CHART" \
  --set subdomain=platform --set domain=example.com > "$TMP/out.yaml" 2>"$TMP/err" || {
    echo "FAIL: helm template errored:"; cat "$TMP/err"; exit 1; }

host="$(yq -r 'select(.kind=="Ingress") | .spec.rules[0].host' "$TMP/out.yaml")"
if [ "$host" = "hello.platform.example.com" ]; then
  echo "ok: Ingress host renders hello.<subdomain>.<domain> ($host)"
else
  echo "FAIL: Ingress host wrong (got '$host', want hello.platform.example.com)"; FAIL=1
fi

img="$(yq -r 'select(.kind=="Deployment") | .spec.template.spec.containers[0].image' "$TMP/out.yaml")"
case "$img" in
  *:latest|*:"") echo "FAIL: hello image must be pinned, not :latest (got $img)"; FAIL=1;;
  *:*) echo "ok: hello image pinned ($img)";;
  *) echo "FAIL: hello image has no tag ($img)"; FAIL=1;;
esac

nonroot="$(yq -r 'select(.kind=="Deployment") | .spec.template.spec.containers[0].securityContext.runAsNonRoot' "$TMP/out.yaml")"
if [ "$nonroot" = "true" ]; then
  echo "ok: hello runs non-root"
else
  echo "FAIL: hello must set runAsNonRoot: true (got $nonroot)"; FAIL=1
fi

# No Ingress tls: block — TLS terminates at the NLB via ACM (docs/0003).
if yq -e 'select(.kind=="Ingress") | .spec.tls' "$TMP/out.yaml" >/dev/null 2>&1; then
  echo "FAIL: hello Ingress must NOT carry a tls: block (NLB terminates via ACM)"; FAIL=1
else
  echo "ok: no Ingress tls block (NLB/ACM termination)"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: hello chart render contracts" || echo "FAILED"
exit "$FAIL"
