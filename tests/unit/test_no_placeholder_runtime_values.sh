#!/usr/bin/env bash
# Lint: no unjustified TODO_/PLACEHOLDER_ values in runtime-consumed manifests.
#
# Red-first origin (retro 2026-06-12-236 Proposal 2 / PR #233): the keycloak
# realm ConfigMap shipped the deferred Cognito wiring as TODO_COGNITO_* values.
# Keycloak validates IdP URLs at IMPORT time and crash-loops on a malformed
# one ("no protocol: TODO_COGNITO_AUTH_URL") — a placeholder that fails closed
# at boot, caught only on a live cluster. The rule this enforces:
#
#   * A TODO_ token as a runtime VALUE is always a defect — deferred wiring is
#     an ABSENT block, never a placeholder string.
#   * A PLACEHOLDER_ token as a runtime VALUE must be a known inert-by-override
#     token (the cluster-facts / ApplicationSet-valuesObject overrides below);
#     any new one fails until it is added here WITH a reason, forcing the
#     "is this actually overridden before anything reads it?" question.
#
# Scans only string LEAF VALUES (via yq) — comments and keys are invisible, so
# the realm header that documents the failure mode does not trip the lint.
#
# Scope: every tracked YAML under the runtime-consumed trees. Helm values
# files count: their ApplicationSet valuesObject overrides are what make the
# allowlisted placeholders inert, and a NON-overridden placeholder there
# reaches the rendered workload exactly like the #233 realm value did.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

ROOT="$HERE/../.."
cd "$ROOT"

# Inert-by-override PLACEHOLDER_ tokens (verified 2026-06-13 against the tree).
# Each is replaced before any workload reads it:
#   PLACEHOLDER_DOMAIN / PLACEHOLDER_REGION — cluster-facts, set by the
#     ApplicationSet valuesObject from the registration Secret annotations.
#   PLACEHOLDER_DB_HOST — overridden by the keycloak extraEnvVarsSecret
#     (envFrom last-wins; proven by test_keycloak_db_env_precedence.sh).
#   PLACEHOLDER_OVERRIDDEN_BY_APPLICATION — the literal "I am overridden"
#     sentinel for external-dns/ingress txt-owner-id and friends.
ALLOWED_PLACEHOLDERS="PLACEHOLDER_DOMAIN PLACEHOLDER_REGION PLACEHOLDER_DB_HOST PLACEHOLDER_OVERRIDDEN_BY_APPLICATION"

is_allowed() {
  local tok="$1" a
  for a in $ALLOWED_PLACEHOLDERS; do [ "$tok" = "$a" ] && return 0; done
  return 1
}

# Tree scope — runtime-consumed manifests + chart values. Allow override for
# the unit test's fixture dir via $1.
if [ "$#" -ge 1 ]; then
  FILES=$(cd "$1" && git ls-files '*.yaml' '*.yml' 2>/dev/null | sed "s|^|$1/|"; find "$1" -name '*.yaml' -o -name '*.yml' 2>/dev/null)
  FILES=$(printf '%s\n' $FILES | sort -u)
else
  FILES=$(git ls-files \
    'platform-services/**/*.yaml' 'platform-services/**/*.yml' \
    'clusters/**/*.yaml' 'clusters/**/*.yml' \
    'argocd/**/*.yaml' 'argocd/**/*.yml')
fi

[ -n "$FILES" ] || { fail "files_discovered" "no YAML under the runtime trees"; summary; }

VIOLATIONS=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  # All target files must parse — a non-parseable runtime manifest is its own
  # defect; fail loudly rather than skip into a blind spot.
  if ! yq 'true' "$f" >/dev/null 2>&1; then
    fail "yaml_parses ($f)" "yq could not parse $f (runtime manifest must be valid YAML)"
    VIOLATIONS=$((VIOLATIONS + 1))
    continue
  fi
  # String leaf values only. `..` walks values (not keys); comments are gone.
  while IFS= read -r val; do
    [ -z "$val" ] && continue
    for tok in $(printf '%s\n' "$val" | grep -oE '(TODO_|PLACEHOLDER_)[A-Z0-9_]+' | sort -u); do
      case "$tok" in
        TODO_*)
          fail "no_todo_value ($f: $tok)" "deferred wiring is an absent block, never a placeholder string"
          VIOLATIONS=$((VIOLATIONS + 1)) ;;
        PLACEHOLDER_*)
          if ! is_allowed "$tok"; then
            fail "placeholder_allowlisted ($f: $tok)" "not an inert-by-override placeholder — add it to ALLOWED_PLACEHOLDERS with a reason, or remove it"
            VIOLATIONS=$((VIOLATIONS + 1))
          fi ;;
      esac
    done
  done < <(yq -r '.. | select(tag == "!!str")' "$f" 2>/dev/null)
done < <(printf '%s\n' "$FILES")

[ "$VIOLATIONS" -eq 0 ] && pass "no unjustified TODO_/PLACEHOLDER_ values in runtime manifests"

summary
