#!/usr/bin/env bash
# auto-015-001 (OI-2026-06-08-1) MERGE GATE — machine-enforced "held" PR.
#
# The IAM Resource:"*" narrowing in terraform/management/irsa.tf mutates the LIVE
# Crossplane provider role. Per the decision brief (Round-2, merge-gate-discipline
# reviewer), prose "held" is unenforceable in a bottom-up merge stack, so this is a
# FAILING required check until a session COMMITS the sentinel below — having
# OBSERVED the spoke reconcile green under the narrowed policy (the
# iam-oidc-provider live check flips SKIP->PASS + the spoke external-dns Role is
# created). The sentinel commit lands ATOMICALLY with the docs/open-issues.md
# RESOLVED flip and the ai/handoff.md run-ID record. Until then: RED, do not merge.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

SENTINEL="planning/test-overhaul/decisions/.auto-015-iam-gate-passed"

echo "── auto-015 IAM-tightening merge gate ───────────────────────"
if [ -f "$SENTINEL" ]; then
  echo "  ✓ gate CLEARED — spoke validation observed:"
  sed 's/^/      /' "$SENTINEL"
  echo "── gate PASSED ──"
  exit 0
fi
echo "  ✗ HELD — spoke validation of the narrowed IAM policy is NOT yet confirmed."
echo "    The narrowed Crossplane role permits IAM role/OIDC create only on"
echo "    k8-platform-* / oidc-provider/*. It must be proven on the spoke CREATE"
echo "    path (XSpokeAccess: spoke OIDC provider + external-dns Role reconcile"
echo "    green) before merge. To clear: commit '$SENTINEL' carrying the validating"
echo "    run-ID, in the same commit that flips OI-2026-06-08-1 to RESOLVED and"
echo "    records the observation in ai/handoff.md. DO NOT MERGE until this is green."
echo "── gate HELD (RED by design) ──"
exit 1
