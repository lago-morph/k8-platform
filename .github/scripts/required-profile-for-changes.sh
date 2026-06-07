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
# Usage:
#   required-profile-for-changes.sh <changed-files...>      # args, or
#   git diff --name-only BASE...HEAD | required-profile-for-changes.sh -
#
# Output: `full` or `verify-only` on stdout.

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
else
  echo verify-only
fi
