#!/usr/bin/env bash
# Unit tests for scripts/diag-component.sh.
#
# Bug class defended:
#   - $SELECTOR vs $SEL typo (the original main version of this script
#     referenced an undefined $SELECTOR — `set -u` would have caught it
#     at runtime, but the script is rarely run in CI, so it sat broken
#     on main)
#   - silent component-name additions to the usage banner without
#     adding the case branch (which would produce "unknown component"
#     when a user follows the docs)
#
# Pure static parsing — no kubectl required.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

SCRIPT=scripts/diag-component.sh

# ---- 1. Script exists + bash-parses without syntax errors ---------------
if [ ! -x "$SCRIPT" ]; then
  _fail "diag_script_executable" "$SCRIPT missing or not +x"
  assert_summary
fi
_pass "diag_script_executable"

if bash -n "$SCRIPT" 2>/tmp/diag-parse.err; then
  _pass "diag_script_bash_parse"
else
  _fail "diag_script_bash_parse" "$(cat /tmp/diag-parse.err)"
fi

# ---- 2. No reference to the historical $SELECTOR typo -------------------
#
# Defends contract: the only variable holding the label selector is
# $SEL. A `$SELECTOR` reference is the exact bug that broke the
# `pods` dump section on main for an unknown period.
if grep -qE '\$SELECTOR|\$\{SELECTOR' "$SCRIPT"; then
  _fail "diag_script_no_stale_SELECTOR_var" "found legacy \$SELECTOR reference — use \$SEL"
else
  _pass "diag_script_no_stale_SELECTOR_var"
fi

# ---- 3. Every component named in the usage banner has a case branch ----
#
# Defends contract: a developer who adds "platform-cluster" to the usage
# banner but forgets to add `platform-cluster) ...;;` would produce a
# script that prints `unknown component` for the documented usage.
banner=$(awk '/^Components:/,/^Extra args:/' < <(bash "$SCRIPT" -h 2>/dev/null))
components=$(printf '%s\n' "$banner" \
  | grep -oE '^  - [a-z][-a-z]+' | awk '{print $2}')

[ -n "$components" ] || _fail "diag_script_banner_lists_components" "usage banner is empty"

# Capture the case block once (here-string grep below avoids the
# pipefail+grep-q SIGPIPE flake — OI-2026-06-05-1).
_case_block="$(awk '/^case "\$COMPONENT" in/,/^esac/' "$SCRIPT")"
for c in $components; do
  if grep -qE "^[[:space:]]*${c}[)|]" <<<"$_case_block"; then
    _pass "diag_script_branch_present:$c"
  else
    _fail "diag_script_branch_present:$c" "usage banner lists '$c' but no case branch implements it"
  fi
done

# ---- 4. platform-secret branch uses kubectl, not legacy NS/SEL ----------
#
# Defends contract: platform-secret is a Crossplane Claim, not a
# helm-installed component. It does NOT have a single namespace/label.
# If it accidentally falls through to the default NS/SEL block, the
# output is nonsensical.
_platform_secret_block="$(awk '/platform-secret/,/^fi$/' "$SCRIPT")"
if grep -qE 'kubectl get (platformsecret|xplatformsecret|clustersecretstore|externalsecret)' <<<"$_platform_secret_block"; then
  _pass "diag_platform_secret_uses_xrd_apis"
else
  _fail "diag_platform_secret_uses_xrd_apis" "platform-secret branch must call kubectl on the XRD/ESO APIs"
fi

# ---- 5. -h / --help / no-args all exit 0 -------------------------------
for arg in "-h" "--help" ""; do
  if bash "$SCRIPT" $arg </dev/null >/dev/null 2>&1; then
    _pass "diag_script_help_${arg:-empty}_exits_zero"
  else
    _fail "diag_script_help_${arg:-empty}_exits_zero" "got rc=$? for arg='$arg'"
  fi
done

# ---- 6. Unknown component exits non-zero with a clear message ----------
if out=$(bash "$SCRIPT" no-such-component 2>&1); then
  _fail "diag_unknown_component_exits_nonzero" "expected nonzero exit, got 0; out: $out"
else
  case "$out" in
    *"unknown component"*) _pass "diag_unknown_component_message" ;;
    *) _fail "diag_unknown_component_message" "no 'unknown component' substring in: $out" ;;
  esac
fi

assert_summary
