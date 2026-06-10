# ADR: Complete CREATE-path coverage for resource-scoped IAM narrowings

- **ID**: ADR-c7e9f8c3bc
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-09
- **Source retrospective**: ../2026-06-09-214.md
- **PRs covered**: #209, #211, #212, #213

## Context

auto-015 (PR #203) narrowed the Crossplane IRSA role's `iam:GetRole` action from
`Resource: "*"` to `Resource: arn:aws:iam::*:role/k8-platform-*`. The validation
approach was: apply the narrowed policy, drive the spoke-ACCESS create path (spoke
OIDC provider + external-dns role + inline policy), observe all MRs `Ready=True`,
and declare the narrowing validated. That was one create path out of at least two.

The second create path — EKS `CreateNodegroup` — was never exercised under the
narrowed policy. When Amazon EKS creates a node group it internally calls
`iam:GetRole` on the AWS-owned service-linked role
`AWSServiceRoleForAmazonEKSNodegroup` (IAM path `role/aws-service-role/eks-nodegroup.amazonaws.com/*`).
That path is completely outside the `role/k8-platform-*` resource scope, so the
narrowed policy denied it. On a fresh-account bring-up in auto-016 — where the
narrowed policy was in effect from the start — nodegroup creation failed closed.
The spoke came up with **zero nodes** and the entire app stack stalled.

auto-015 never caught this because its nodegroup pre-existed the narrowing: the
session validated the spoke-access path only (the path active at that moment),
and the nodegroup was already ACTIVE. The second path was invisible.

This pattern generalizes: any resource-scoped IAM narrowing that targets a
Crossplane provider role can silently exclude the AWS-internal service-linked-role
validation calls that EKS, RDS, ACM, and other services make at create time.
Those calls are not documented prominently; they only surface as a `CREATE` failure
under a live restricted policy on a fresh bring-up.

## Decision

Before marking a resource-scoped IAM narrowing validated, enumerate and test every
create path the controlled service exercises, including AWS service-linked-role
validation paths, on a fresh-account bring-up.

Concretely: for any action narrowed to a resource scope (e.g.
`iam:GetRole Resource: arn:aws:iam::*:role/<prefix>-*`), the validation checklist
must include:

1. List every AWS service call that the Crossplane provider makes at create time for
   each resource type under the Composition (e.g. `CreateNodegroup` → validates
   `AWSServiceRoleForAmazonEKS`, `AWSServiceRoleForAmazonEKSNodegroup`).
2. For each service that validates a service-linked role, explicitly add an IAM
   statement scoped to `arn:aws:iam::*:role/aws-service-role/<service-domain>/*`.
3. Exercise every create path on a fresh account where the narrowed policy applies
   from the start (not upgrade-in-place on a pre-existing cluster).
4. Record which create paths were exercised and which were not in `docs/open-issues.md`.
   A narrowing with unexercised create paths is not complete.

## Alternatives considered

- **Trust `iam:simulate-principal-policy` to find excluded paths** — rejected. As
  documented in AGENTS.md §6.39 (grounded in auto-015), the simulator returns
  `implicitDeny` for every action on a freshly-modified role, including unambiguously
  allowed ones; it cannot distinguish real denies from simulator lag. It is useful
  as a fast pre-flight hint only, not as proof.

- **Apply the narrowing only after all cluster resources exist** — rejected. This
  is how auto-015 avoided the bug, but it does not validate the narrowing on the
  create path — it only validates the ongoing-reconcile path. The narrowing
  provides no assurance for the next fresh-account bring-up, and it defers exactly
  the discovery this rule is trying to force.

- **Add a broad `role/aws-service-role/*` allow unconditionally** — considered but
  not chosen as the validation *strategy* (it is the correct IAM *fix*). Without
  enumeration and create-path testing, the broad allow may miss other unscoped
  service-internal paths, and the rule's purpose is rigorous coverage, not a
  blanket workaround.

## Consequences

Easier: a resource-scoped IAM narrowing that passes the checklist is genuinely
safe to merge, because all known create paths were exercised. The blast radius of
a false validation is eliminated.

Harder: validating a narrowing now requires at least two live create events (the
platform-specific path and the SLR path). This means the narrowing PR cannot be
un-drafted until a fresh-account bring-up completes successfully — the sentinel-gated
draft pattern (AGENTS.md §6.39, ADR-79a955b122) is the right holder.

Trade-off accepted: validation cost (one extra fresh-account bring-up with the
narrowed policy from the start) is higher, but the alternative is a fail-closed
regression that surfaces only on the next production bring-up. The auto-016
experience — a zero-node spoke, an unattended run interrupted by a diagnostic
sequence and a live patch — makes the cost asymmetry concrete.

## References

- [`../2026-06-09-214.md`](../2026-06-09-214.md) — the source retrospective.
- [`./AGENTS-MD-7286e40df4-enumerate-all-create-paths-iam-narrowing.md`](./AGENTS-MD-7286e40df4-enumerate-all-create-paths-iam-narrowing.md) — the agents-file rule derived from the same lesson.
- PRs the decision was made in: #213 (EKS SLR GetRole regression fix), #211 (RDS narrowing), #212 (EC2 narrowing).
- ADR-79a955b122 — sentinel-gated-draft validation pattern (retrospective 2026-06-08-207) — a complementary constraint: the *how-to-hold* while waiting for full create-path coverage.

<!--
PROMOTION NOTE:
When this draft is adopted into docs/adr/ via the `adr` skill, preserve
the `**ID**: ADR-c7e9f8c3bc` line verbatim. The NNNN number in the
docs/adr/ filename is a separate human-friendly sequence; the hash is
the durable identifier and must not drift.
-->
