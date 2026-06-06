#!/usr/bin/env bash
# Gates the dual-ExternalDNS safety invariant (auto-008 S3): the hub and spoke
# instances share one Route53 zone, so their domainFilters MUST be disjoint and
# their txtOwnerIds MUST differ — otherwise the two controllers corrupt each
# other's TXT ownership registry (and a bad filter could delete
# argocd.management.<domain>). This is a correctness gate, not style.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

HELM_TF="$HERE/../../terraform/management/helm.tf"
SPOKE_VALUES="$HERE/../../platform-services/external-dns/values.yaml"
FAIL=0

[ -f "$HELM_TF" ] || { echo "FAIL: $HELM_TF missing"; exit 1; }
[ -f "$SPOKE_VALUES" ] || { echo "FAIL: $SPOKE_VALUES missing"; exit 1; }

# Hub: extract the domainFilters[0] value + txtOwnerId from helm.tf (the value is
# a terraform expression; we assert it is scoped to management.<domain>, not the
# bare var.domain whole-zone).
hub_filter_line="$(grep -A2 'name  = "domainFilters\[0\]"' "$HELM_TF" | grep 'value' | head -1)"
hub_owner_line="$(grep -A2 'name  = "txtOwnerId"' "$HELM_TF" | grep 'value' | head -1)"

if echo "$hub_filter_line" | grep -q 'management\.\${var.domain}'; then
  echo "ok: hub domainFilters scoped to management.<domain>"
else
  echo "FAIL: hub domainFilters[0] is not scoped to management.<domain> (found: $hub_filter_line)"
  echo "      a whole-zone (var.domain) hub filter would clobber spoke records"; FAIL=1
fi

if echo "$hub_owner_line" | grep -q '"k8-platform-mgmt"'; then
  echo "ok: hub txtOwnerId = k8-platform-mgmt"
else
  echo "FAIL: hub txtOwnerId changed unexpectedly (found: $hub_owner_line)"; FAIL=1
fi

# Spoke: domainFilters must be platform.<...>, txtOwnerId distinct, txtPrefix set.
spoke_filter="$(yq -r '.domainFilters[0]' "$SPOKE_VALUES")"
spoke_owner="$(yq -r '.txtOwnerId' "$SPOKE_VALUES")"
spoke_prefix="$(yq -r '.txtPrefix' "$SPOKE_VALUES")"

case "$spoke_filter" in
  platform.*) echo "ok: spoke domainFilters scoped to platform.<domain> ($spoke_filter)";;
  *) echo "FAIL: spoke domainFilters[0] must be platform.<...> (found: $spoke_filter)"; FAIL=1;;
esac

if [ "$spoke_owner" = "k8-platform-platform" ]; then
  echo "ok: spoke txtOwnerId = k8-platform-platform"
else
  echo "FAIL: spoke txtOwnerId must be k8-platform-platform (found: $spoke_owner)"; FAIL=1
fi

# Disjointness: hub subdomain (management) != spoke subdomain (platform).
if [ "$spoke_owner" = "k8-platform-mgmt" ]; then
  echo "FAIL: spoke and hub txtOwnerId are identical — TXT registry will collide"; FAIL=1
fi
if [ -z "$spoke_prefix" ] || [ "$spoke_prefix" = "null" ]; then
  echo "FAIL: spoke txtPrefix must be set (distinct TXT names from the hub)"; FAIL=1
else
  echo "ok: spoke txtPrefix set ($spoke_prefix)"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: hub/spoke ExternalDNS filters disjoint" || echo "FAILED"
exit "$FAIL"
