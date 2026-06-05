#!/usr/bin/env bash
# Gates AGENTS §8.1 / REQ-NF-03: no account-ephemeral values (real ACM/IAM ARNs,
# real account ids, the realhandsonlabs domain) may be committed in the spoke
# add-on values or Applications. Those are overlaid at registration time
# (auto-008 §5). Placeholders (PLACEHOLDER_*) and the stub account 000000000000
# are allowed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
FAIL=0

scan() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  # Real 12-digit AWS account id (anything other than the stub 000000000000).
  if grep -rEn 'arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:' "$dir" \
       | grep -vE ':000000000000:' | grep -v 'PLACEHOLDER'; then
    echo "FAIL: real AWS ARN with a non-stub account id committed under $dir"; FAIL=1
  fi
  # The real lab domain must never be committed (it's per-account ephemeral).
  if grep -rEn 'realhandsonlabs\.net' "$dir"; then
    echo "FAIL: real lab domain (realhandsonlabs.net) committed under $dir"; FAIL=1
  fi
  # A bare 12-digit number that looks like an account id (not the stub).
  if grep -rEn '[^0-9]([1-9][0-9]{11})[^0-9]' "$dir" \
       | grep -vE '000000000000' | grep -viE 'placeholder|version|port|timeout'; then
    echo "WARN: a 12-digit number under $dir — verify it is not an account id"
  fi
}

scan "$ROOT/platform-services"
scan "$ROOT/argocd/apps/spoke"

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: no ephemeral account values committed in spoke values/apps"
else
  echo "FAILED — move the ephemeral value to registration-time overlay (auto-008 §5)"
fi
exit "$FAIL"
