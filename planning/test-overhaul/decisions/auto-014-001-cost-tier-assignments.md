# auto-014-001 — Cost-tier assignments for the live coverage registry

> Decision brief (autonomous-run protocol: two adversarial rounds, ≥3 real
> reviewers each). FINAL-PLAN §5 / §14.5 open owner choice.
> **Status: Round 1 — awaiting first adversarial wave.**

## Question

`tests/coverage/registry.yaml` assigns each composed-MR kind a `cost` tier —
`hermetic` (cheap create-and-verify, both full + verify-only paths),
`singleton-coupled` (cheap action but bound to a shared singleton — zone/spoke —
so after-the-fact on the hub, instantiate only in an isolated scope), or `slow`
(EKS ~20 min / RDS multi-min — after-the-fact only). The tier drives **what P4
may instantiate** and **what stays after-the-fact-only**. Are the current
assignments correct, or should any kind move tiers?

## Current assignments (as committed)

| Kind | cost | rationale |
|---|---|---|
| acm Certificate / CertificateValidation | slow | DNS-validated issuance is slow + bound to the one hosted zone |
| ec2 SecurityGroupRule | singleton-coupled | admits the shared SSM relay; created with the cluster |
| eks Cluster / NodeGroup | slow | ~20 min; never recreate |
| eks AccessEntry / AccessPolicyAssociation | singleton-coupled | coupled to the spoke cluster |
| iam Role / RolePolicy / RolePolicyAttachment | hermetic | per-run-id role is cheap + isolatable |
| iam OpenIDConnectProvider | singleton-coupled | one OIDC provider per spoke |
| rds Instance | slow | multi-minute |
| route53 Record | singleton-coupled | coupled to the singleton hosted zone |
| secretsmanager Secret | hermetic | per-run-id ASM secret is cheap + isolatable |
| external-secrets ExternalSecret | hermetic | cheap k8s object syncing from a hermetic ASM secret |

## Alternatives

1. **Keep all current tiers (my Round-1 call).** They match the FINAL-PLAN §5
   taxonomy and are corroborated by this run's live observations (AccessEntry/
   PolicyAssoc and route53 Record are demonstrably coupled to the spoke/zone
   singletons; IAM role + ASM secret are per-run-id isolatable).
2. **Promote acm Certificate to `singleton-coupled` (not `slow`).** ACM issuance
   for a *new* hermetic domain under the zone is minutes, not ~20; the "slow" is
   really the DNS-validation round-trip via the shared zone — which is the
   *singleton-coupled* signature, not raw duration.
3. **Demote `external-secrets ExternalSecret` to `singleton-coupled`.** ESO sync
   depends on the cluster-wide `ClusterSecretStore` singleton; a hermetic
   ExternalSecret still reads through that shared store.

## Round-1 decision (my best call)

**Keep the current tiers unchanged.** The tier is an operational contract
(may-P4-instantiate? isolatable?), not a duration measurement, and every current
assignment is corroborated by this run's live evidence. The acm "slow" vs
"singleton-coupled" question is cosmetic because the operational consequence
(after-the-fact only, never per-run instantiate) is identical either way, so the
safer `slow` is retained. ESO's dependency on the `ClusterSecretStore` is a
read-only precondition installed once at bring-up, not a per-run coupling — so a
per-run-id ExternalSecret reading a per-run-id ASM secret is genuinely hermetic.

## Reasoning

Drives P4's instantiate set (hermetic kinds only) vs after-the-fact-only for
slow/singleton kinds. Keeping the tiers preserves the FINAL-PLAN design and
avoids destabilizing P4's scope. The alternatives are re-labels with no change in
operational behavior (both acm options forbid per-run instantiation).

## Downstream impact

Drives P4's instantiate set (hermetic: iam Role/RolePolicy/RolePolicyAttachment,
secretsmanager Secret, external-secrets ExternalSecret) and keeps slow/singleton
kinds after-the-fact-only. No registry value changes under the Round-1 call.

## Round-1 if-user-overrides rewind point

The `cost:` values are unchanged by this decision, so there is nothing to revert
on the live infra. If a move is later adopted it is a one-line registry edit per
kind; revert that edit to undo.
