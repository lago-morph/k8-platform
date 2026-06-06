#!/usr/bin/env bash
# Regression guard (run 27071480486): a Kyverno ClusterPolicy that matches a
# Custom Resource kind MUST group-qualify it (Group/Version/Kind), never a bare
# "Kind". Kyverno's validate-policy admission webhook converts each matched kind
# to a GVR; a bare CRD kind has no group, yielding "unable to convert GVK to GVR
# ... failed to find resource (*/*/<Kind>/)" and the policy apply fails — which
# blocks the management bootstrap (kyverno_audit_policies applies policies/audit/).
#
# Built-in Kubernetes kinds (Pod, Service, Ingress, ClusterRoleBinding, ...) are
# always resolvable unqualified and are fine. This test only flags the CRD kinds
# this repo's policies might reference. Add new CRD kinds to CRD_KINDS as they
# appear.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool yq

AUDIT_DIR="$HERE/../../policies/audit"
[ -d "$AUDIT_DIR" ] || { echo "missing $AUDIT_DIR"; exit 2; }

# CRD kinds (non-built-in) that may appear in this repo's policies. A bare
# match on any of these is the bug this test catches.
CRD_KINDS="AppProject Application XDatabase XPlatformCluster XPlatformSecret Instance Provider Composition CompositeResourceDefinition"

FAIL=0
for pol in "$AUDIT_DIR"/*.yaml; do
  [ -e "$pol" ] || continue
  base="$(basename "$pol")"
  # Every matched kind across every rule's match.any[].resources.kinds[] and
  # match.all[].resources.kinds[].
  kinds="$(yq -r '.spec.rules[].match.any[]?.resources.kinds[]?, .spec.rules[].match.all[]?.resources.kinds[]?' "$pol" 2>/dev/null | sort -u)"
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    # Qualified kinds contain a "/" (Group/Version/Kind) — always OK.
    case "$k" in */*) continue;; esac
    # Bare kind: fail only if it's a known CRD kind.
    for crd in $CRD_KINDS; do
      if [ "$k" = "$crd" ]; then
        fail "kyverno_crd_kind_qualified:$base" \
             "matches bare CRD kind '$k' — Kyverno can't resolve GVR; use group-qualified form (e.g. argoproj.io/v1alpha1/$k)"
        FAIL=1
      fi
    done
  done <<EOF
$kinds
EOF
done

[ "$FAIL" -eq 0 ] && pass "all Kyverno policies group-qualify CRD kinds"
summary
