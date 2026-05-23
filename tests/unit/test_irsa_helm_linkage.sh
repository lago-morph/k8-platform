#!/usr/bin/env bash
# Linkage check: every irsa_* module declared in terraform/management/irsa.tf
# must be referenced by something in helm.tf (or elsewhere in the module).
# Catches the "IRSA role exists but no helm_release consumes it" bug class
# (bug #4 from the 2026-05-23 phase-1 bring-up — ExternalDNS install was
# missing for hours while the IAM role had been created the whole time).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"

ROOT="$HERE/../.."
IRSA_TF="$ROOT/terraform/management/irsa.tf"
HELM_TF="$ROOT/terraform/management/helm.tf"

[ -f "$IRSA_TF" ] || { echo "missing $IRSA_TF"; exit 2; }
[ -f "$HELM_TF" ] || { echo "missing $HELM_TF"; exit 2; }

# Extract module names: 'module "irsa_xxx"' → irsa_xxx
mapfile -t IRSA_MODS < <(grep -oE 'module "irsa_[a-zA-Z0-9_]+"' "$IRSA_TF" \
                        | sed -E 's/module "(.*)"/\1/' \
                        | sort -u)

if [ "${#IRSA_MODS[@]}" -eq 0 ]; then
  fail "no irsa_* modules found in irsa.tf" \
       "this test is meaningless without IRSA roles to check"
  summary
fi

echo "── irsa-helm-linkage: ${#IRSA_MODS[@]} IRSA role(s) declared ─────"

# For each module, check that helm.tf references its iam_role_arn output.
for mod in "${IRSA_MODS[@]}"; do
  expected_ref="module.${mod}.iam_role_arn"
  if grep -qF "$expected_ref" "$HELM_TF"; then
    pass "$mod is referenced by helm.tf"
  else
    fail "$mod is not referenced by helm.tf" \
         "expected substring: $expected_ref"
  fi
done

# Inverse: every IRSA-arn reference in helm.tf must point at a real module.
echo "── irsa-helm-linkage: helm.tf references resolve ─────────────────"
mapfile -t HELM_IRSA_REFS < <(grep -oE 'module\.irsa_[a-zA-Z0-9_]+\.iam_role_arn' "$HELM_TF" \
                              | sed -E 's/module\.(irsa_[a-zA-Z0-9_]+)\.iam_role_arn/\1/' \
                              | sort -u)

for ref in "${HELM_IRSA_REFS[@]}"; do
  if grep -qE "module \"$ref\"" "$IRSA_TF"; then
    pass "helm.tf references $ref → resolves in irsa.tf"
  else
    fail "helm.tf references $ref → no matching module in irsa.tf"
  fi
done

summary
