#!/usr/bin/env bash
# Decide WHICH live-evidence profile a change demands (FINAL-PLAN §4.3).
#
# "Coupled to the change": a component still under development — or ANY component
# whose config-SHA changed in the PR (crossplane/** or policies/** for that
# component) — requires `full` evidence; a verify-only record for it is
# insufficient ⇒ RED. A change to a component RE-ARMS `full`. Only a proven,
# unchanged component is satisfiable by verify-only evidence.
#
# This is also what makes config-only GitOps changes first-class (round-3 qa-guru
# R3-C2, the exact auto-012 shape): a Composition/IAM/tag edit ArgoCD will sync
# to the live hub with no apply-and-verify dispatch demands `full`.
#
# Tiers (2026-07-06, the rebase-force-push over-firing fix):
#   full        — crossplane/** or policies/** changed: ArgoCD syncs these to
#                 the live hub with no apply-and-verify dispatch.
#   verify-only — terraform/management/** or tests/live/** changed: the
#                 hub-apply surface, or the live checks themselves.
#   none        — nothing above changed. The workflow's push-path trigger can
#                 over-fire (a rebase force-push carries main's recent history
#                 through the ref update), so the CHANGE SET — not the
#                 trigger — decides; `none` means the gate is not applicable
#                 and green-skips. Gate-machinery edits (this script,
#                 live-evidence-gate.sh, the verifier workflow) are
#                 deliberately `none`: demanding live evidence for the gate's
#                 own decision logic is circular; tests/unit/
#                 test_live_evidence_gate.sh plus review own that correctness,
#                 and the git credential cannot push workflow files anyway.
#
# Usage:
#   required-profile-for-changes.sh <changed-files...>      # args, or
#   git diff --name-only BASE...HEAD | required-profile-for-changes.sh -
#
# Output: `full`, `verify-only`, or `none` on stdout.

set -euo pipefail

changed=""
if [ "${1:-}" = "-" ]; then
  changed="$(cat)"
else
  changed="$(printf '%s\n' "$@")"
fi

# Paths whose edit re-arms `full` (the live-config surface ArgoCD syncs).
if printf '%s\n' "$changed" | grep -Eq '^(crossplane/|policies/)'; then
  echo full
# Paths whose edit demands fresh verify-only evidence (the hub-apply surface
# and the live checks themselves).
elif printf '%s\n' "$changed" | grep -Eq '^(terraform/management/|tests/live/)'; then
  echo verify-only
else
  echo none
fi
