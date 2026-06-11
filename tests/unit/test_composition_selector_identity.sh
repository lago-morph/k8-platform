#!/usr/bin/env bash
# ADR-0011 mechanical enforcement — composite-routed cross-resource
# references over provider reference selectors (OI-2026-06-10-1).
#
# Upjet reference SELECTORS resolve through the referenced MR's
# crossplane.io/external-name annotation. Identity-from-provider resources
# (ACM Certificate under provider v2.5.0) never get that annotation written
# back (the tf-aws#45303 identity bug class), so a selector pointing at one
# retries "referenced field was empty" FOREVER while the real cloud
# resource sits healthy — it held the first clean build's XR at
# Ready=False for 50+ minutes. Every static layer was green; only the live
# build caught it.
#
# THE RULE (ADR-0011): a `*Selector` in a Composition is allowed ONLY when
# the resource it targets gets an explicit crossplane.io/external-name
# patch in the same Composition (deterministic identity we control).
# Otherwise the value must be routed through the composite
# (ToCompositeFieldPath -> XR status -> FromCompositeFieldPath Required).
#
# Scope note: `*Ref`-by-name references are NOT covered — none exist in
# the tree today; extend this lint when one appears rather than guessing
# its semantics now.
set -uo pipefail
cd "$(dirname "$0")/../.."

# shellcheck disable=SC1091
. tests/lib/assert.sh

ROLE_LABEL="platform.k8-platform.io/role"

# check_composition <file> — emits "VIOLATION <key> <reason>" lines.
check_composition() {
  local f="$1"
  local PT='.spec.pipeline[] | select(.functionRef.name == "function-patch-and-transform") | .input'

  # every selector entry as "resourceName<TAB>selectorKey<TAB>targetRole"
  yq -r "${PT}.resources[] as \$r | \$r.base.spec.forProvider | to_entries[]
         | select(.key | test(\"Selector$\"))
         | [\$r.name, .key, (.value.matchLabels[\"$ROLE_LABEL\"] // \"\")] | @tsv" "$f" 2>/dev/null \
  | while IFS=$'\t' read -r rname skey trole; do
      [ -z "$skey" ] && continue
      if [ -z "$trole" ]; then
        echo "VIOLATION $f:$rname.$skey has no $ROLE_LABEL matchLabel — target unresolvable, fail closed (ADR-0011)"
        continue
      fi
      # the target resource (by role label) must patch its external-name
      local has_extname
      has_extname=$(yq -r "${PT}.resources[]
        | select(.base.metadata.labels[\"$ROLE_LABEL\"] == \"$trole\")
        | [.patches[]? | select(.toFieldPath == \"metadata.annotations[crossplane.io/external-name]\")] | length" "$f" 2>/dev/null)
      if [ -z "$has_extname" ]; then
        echo "VIOLATION $f:$rname.$skey targets role '$trole' but no resource carries that label (ADR-0011)"
      elif [ "$has_extname" -lt 1 ]; then
        echo "VIOLATION $f:$rname.$skey targets '$trole', which has NO explicit external-name patch — the selector resolves via an annotation the provider may never write (OI-2026-06-10-1); route the value through the composite (ADR-0011)"
      fi
    done
}

# ---- 0. selftest: a violating fixture must be flagged ----------------------
SELFTEST=$(mktemp --suffix=.yaml)
cat > "$SELFTEST" <<'YAML'
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
spec:
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        resources:
          - name: identity-from-provider
            base:
              kind: Certificate
              metadata:
                labels:
                  platform.k8-platform.io/role: fixture-cert
              spec:
                forProvider:
                  region: us-east-1
            patches: []
          - name: dependent
            base:
              kind: CertificateValidation
              spec:
                forProvider:
                  certificateArnSelector:
                    matchControllerRef: true
                    matchLabels:
                      platform.k8-platform.io/role: fixture-cert
YAML
if check_composition "$SELFTEST" | grep -q "VIOLATION"; then
  _pass "selftest: violating selector fixture is flagged"
else
  _fail "selftest: violating selector fixture is flagged" "the lint cannot detect its target class"
fi
rm -f "$SELFTEST"

# ---- 1. repo scan -----------------------------------------------------------
shopt -s nullglob
FOUND_ANY=0
for f in crossplane/compositions/*.yaml; do
  FOUND_ANY=1
  V=$(check_composition "$f")
  if [ -n "$V" ]; then
    _fail "selector_identity:$(basename "$f")" "$V"
  else
    _pass "selector_identity:$(basename "$f")"
  fi
done
shopt -u nullglob
[ "$FOUND_ANY" -eq 1 ] || _fail "compositions_discovered" "no files under crossplane/compositions/ — glob broken?"

# ---- 2. the known-safe selectors are still resolvable (regression anchor) --
# platform-cluster's three surviving selectors target MRs WITH explicit
# external-name patches; if someone deletes those patches the scan above
# flips red. This count pins the audited baseline (update deliberately).
SEL_COUNT=$(grep -c "Selector:$" crossplane/compositions/platform-cluster.yaml)
assert_eq "platform_cluster_selector_baseline" "3" "$SEL_COUNT"

assert_summary
