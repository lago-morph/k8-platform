#!/usr/bin/env bash
# Every ArgoCD-synced ExternalSecret manifest must pin the three ESO-CRD-
# defaulted enums EXPLICITLY on each source ref:
#
#   data[].remoteRef / dataFrom[].extract:
#     conversionStrategy: Default
#     decodingStrategy:   None
#     metadataPolicy:     None
#
# The bug class (post-#255 merge, 2026-07-06): ESO's CRD defaults these
# fields into the live object INSIDE an array; ArgoCD's array diff cannot
# ignore live-only additions, so a manifest that omits them leaves its
# Application PERMANENTLY OutOfSync while selfHeal re-applies a no-op
# forever — masking real drift behind an eternal yellow. The first
# post-merge sync of keycloak-cognito-idp-externalsecret.yaml reproduced
# it live (spoke-keycloak OutOfSync on exactly that one resource). The
# sibling manifests (keycloak-admin, keycloak-db) already pinned the
# fields; the class is "a NEW ExternalSecret misses the house pattern",
# so this lint scans every path an ArgoCD app syncs (L8: every path where
# the class can occur — platform-services/ + argocd/), not just the file
# that bit. Crossplane-composed ExternalSecrets (crossplane/compositions)
# are exempt: crossplane owns them, ArgoCD never diffs them. Test
# fixtures (tests/) assert on composed live objects and are also exempt.
#
# dataFrom[].find is unhandled today (no usage in the repo); the lint
# fails CLOSED on it so a new form can't silently escape the class.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq
require_tool python3

ROOT="$HERE/../.."

# scan_file <file> — one line per violation on stdout; empty = clean.
scan_file() {
  yq eval-all -o=json -I0 '.' "$1" 2>/dev/null | python3 -c '
import json, sys

PINS = {"conversionStrategy": "Default",
        "decodingStrategy": "None",
        "metadataPolicy": "None"}

def unpinned(ref):
    return [f"{k}={ref.get(k)!r} (want {v!r})"
            for k, v in PINS.items() if ref.get(k) != v]

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        doc = json.loads(line)
    except json.JSONDecodeError:
        continue
    if not isinstance(doc, dict) or doc.get("kind") != "ExternalSecret":
        continue
    name = (doc.get("metadata") or {}).get("name", "unnamed")
    spec = doc.get("spec") or {}
    for i, d in enumerate(spec.get("data") or []):
        ref = d.get("remoteRef") or {}
        bad = unpinned(ref)
        if bad:
            k = ref.get("key")
            print(f"{name}: data[{i}].remoteRef key={k}: " + "; ".join(bad))
    for i, d in enumerate(spec.get("dataFrom") or []):
        if "find" in d:
            print(f"{name}: dataFrom[{i}].find is not covered by this lint — extend the enum checks before using find")
        ext = d.get("extract")
        if ext is not None:
            bad = unpinned(ext)
            if bad:
                k = ext.get("key")
                print(f"{name}: dataFrom[{i}].extract key={k}: " + "; ".join(bad))
'
}

# ---- selftest: the scanner must catch the bad shape ----------------------
SELFTEST_DIR="$(mktemp -d)"
trap 'rm -rf "$SELFTEST_DIR"' EXIT

cat > "$SELFTEST_DIR/bad.yaml" <<'YAML'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: selftest-bad
spec:
  dataFrom:
    - extract:
        key: some/asm/name
YAML

cat > "$SELFTEST_DIR/good.yaml" <<'YAML'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: selftest-good
spec:
  data:
    - secretKey: x
      remoteRef:
        key: some/asm/name
        property: x
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
  dataFrom:
    - extract:
        key: some/asm/name
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
YAML

[ -n "$(scan_file "$SELFTEST_DIR/bad.yaml")" ] \
  && pass "selftest: unpinned extract is caught" \
  || fail "selftest bad fixture" "scanner missed the unpinned dataFrom.extract"

[ -z "$(scan_file "$SELFTEST_DIR/good.yaml")" ] \
  && pass "selftest: fully-pinned manifest is clean" \
  || fail "selftest good fixture" "scanner flagged a fully-pinned manifest: $(scan_file "$SELFTEST_DIR/good.yaml")"

# ---- repo scan -----------------------------------------------------------
scanned=0
while IFS= read -r f; do
  grep -q "kind: ExternalSecret" "$f" || continue
  scanned=$((scanned + 1))
  out="$(scan_file "$f")"
  if [ -n "$out" ]; then
    fail "ExternalSecret enums pinned: ${f#"$ROOT"/}" "$out"
  else
    pass "ExternalSecret enums pinned: ${f#"$ROOT"/}"
  fi
done < <(find "$ROOT/platform-services" "$ROOT/argocd" -name '*.yaml' -type f | sort)

[ "$scanned" -gt 0 ] \
  && pass "repo scan visited $scanned ExternalSecret manifest(s)" \
  || fail "repo scan coverage" "no ExternalSecret manifests found under platform-services/ or argocd/ — scan roots wrong?"

summary
