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

---

## Round 2 (revised) — incorporating Round-1 adversarial findings

> Round 1 superseded. Three real reviewers (infra-cost-skeptic, isolation-purist,
> P4-implementer-pragmatist) independently returned CHANGE-TO-X and converged on
> the SAME two re-tiers, grounded in the actual Compositions.

**Revised decision: move two kinds off `hermetic`, keep the rest, add a P4 note.**

1. **`iam.aws.m.upbound.io/RolePolicyAttachment` → `singleton-coupled`.** The
   attachment targets a SHARED AWS-managed policy (`AmazonEKSClusterPolicy`,
   `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
   `AmazonEC2ContainerRegistryReadOnly`). The tier must be correct *by
   construction*, not by trusting P4 fixtures to use unique role names: a per-run
   instantiate that reuses a deterministic role external-name (`k8-platform-
   cluster-<name>`) would mutate a live cluster role's policy set. Structurally
   singleton-coupled regardless of the role-name side.

2. **`external-secrets.io/ExternalSecret` → `singleton-coupled`.** ESO does not
   merely read the `ClusterSecretStore` once; it *continuously reconciles* every
   live ExternalSecret through that one cluster-wide store (one object, one ESO
   controller, one IRSA identity, one AWS-API quota) on `refreshInterval`. Per-run
   instances contend on shared reconciliation bandwidth and can saturate the
   shared AWS Secrets Manager quota, degrading every ExternalSecret in the
   cluster. The ASM `secretsmanager Secret` stays `hermetic` (the Composition keys
   it `k8-platform/<XR-uid>` — genuinely unique, no shared-store expectation).

3. **Keep `iam Role`, `iam RolePolicy`, `secretsmanager Secret` hermetic**, AND
   add a P4 build note: RolePolicy and RolePolicyAttachment carry a hard
   foreign-key (`spec.forProvider.role`) on the Role's external-name, so **P4 must
   instantiate the enclosing XR/Composition as the atomic unit, not individual
   MRs** (a bare RolePolicy/Attachment MR stays unsynced — no parent Role).

4. **acm Certificate/CertificateValidation stay `slow`** — reviewers confirmed
   slow-vs-singleton is cosmetic (both forbid per-run instantiation; DNS-validated
   issuance has no bounded SLA), so the safer `slow` is retained.

**Applied:** `tests/coverage/registry.yaml` re-tiered for the two kinds with the
rationale inline. **Rewind:** revert the registry hunk to restore both to
`hermetic`.

### Round-2 final refinement (post second wave)

Second-wave reviewer (harness-architect) caught an inconsistency: keeping
`iam RolePolicy` `hermetic` while requiring "instantiate the enclosing XR as the
atomic unit" is contradictory — `hermetic` implies per-kind instantiability, but
RolePolicy carries the SAME mandatory `spec.forProvider.role` foreign-key as
RolePolicyAttachment and is never a Crossplane object-graph root (verified: both
`platform-cluster.yaml` and `xspokeaccess.yaml` only ever create RolePolicy/
Attachment alongside their Role; no standalone XRD). A P4 implementer trusting the
`hermetic` label would create a bare RolePolicy MR and watch it hang unsynced.

**Applied:** `iam.aws.m.upbound.io/RolePolicy` → `singleton-coupled` too. Final
hermetic set = {`iam Role`, `secretsmanager Secret`} (both valid standalone
roots). `iam RolePolicy` + `RolePolicyAttachment` + `external-secrets
ExternalSecret` → `singleton-coupled`. The two ACCEPTs in the second wave verified
the RolePolicyAttachment + ExternalSecret re-tiers against the Compositions
(shared `arn:aws:iam::aws:policy/*` attachments; `ClusterSecretStore aws-secrets-
manager` + `refreshInterval: 1h`). **Final: ACCEPTED.**
