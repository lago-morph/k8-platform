#!/usr/bin/env bash
# derived-arn-inventory.sh — STUB (auto-014-002 deferral anchor; OI-2026-06-08-1).
#
# Purpose (when implemented): emit, from the committed v2 Compositions, the set of
# AWS resource ARNs the Crossplane provider role actually creates/touches, keyed by
# service, so the FINAL-PLAN §3.3/§14.3 `Resource:"*"` tightening can be authored
# against a REAL derived inventory (not guesswork) and validated against a clean
# bring-up before narrowing the live provider policy in terraform/management/irsa.tf.
#
# This stub exists so the deferral of the IAM/RDS `Resource:"*"` tightening is a
# concrete, locatable next-step (per AGENTS.md §6.18 + the auto-014-002 brief), not
# an open-ended "later". Decision brief:
#   planning/test-overhaul/decisions/auto-014-002-resource-star-tightening.md
#
# KNOWN-DERIVABLE ARN patterns (from reading crossplane/compositions/*.yaml this run):
#   - IAM roles:        arn:aws:iam::<acct>:role/k8-platform-*
#                         (k8-platform-cluster-<name>, k8-platform-nodegroup-<name>,
#                          k8-platform-<clusterName>-external-dns)
#   - IAM OIDC:         arn:aws:iam::<acct>:oidc-provider/*   (issuer host known only
#                          post cluster-create; the *-scope is still far tighter than "*")
# KNOWN-NON-DERIVABLE (leave at "*", documented):
#   - RDS instances:    auto-named (terraform-<rand>); rds:Describe* is not
#                          resource-scopeable by API shape.
#   - EKS clusters:     ARNs carry a random suffix.
#   - ACM certificates: opaque cert ARNs post-issuance.
#
# IMPLEMENTATION TODO (next session, gated on a teardown-rebuild validation window):
#   1. Parse crossplane/compositions/*.yaml for forProvider name templates per kind.
#   2. Emit a service -> ARN-glob map (the proposed tightened Resource lists).
#   3. Diff against the current irsa.tf Resource:"*" statements; print the safe
#      narrowings (IAM role-prefix, OIDC) vs the must-stay-"*" ones.
#   4. Pair each narrowing with a deny-test fixture asserting the now-forbidden ARN.
set -euo pipefail

echo "derived-arn-inventory.sh is a STUB (OI-2026-06-08-1 / auto-014-002)."
echo "Not yet implemented: see the header + the decision brief for the plan."
echo "The Crossplane provider policy still uses Resource:\"*\" on EKS/EC2/IAM/RDS/ACM"
echo "by deliberate, reviewed deferral (could not validate a tightening without a"
echo "clean bring-up from the sandbox; see AGENTS.md 6.35)."
exit 0
