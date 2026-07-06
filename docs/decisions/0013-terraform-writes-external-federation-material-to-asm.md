# 0013 — Terraform writes externally-generated federation material to ASM under the platform prefix

- **ID**: ADR-9766770001
- **Status**: Accepted (owner-directed adoption 2026-07-06)
- **Date**: 2026-07-06 (drafted and adopted with the phase-5 identity land, PR #255)
- **Source retrospective**: [`../../retrospective/2026-07-06-255.md`](../../retrospective/2026-07-06-255.md)
- **PRs covered**: #255
- **Mechanical enforcement**: `tests/unit/test_keycloak_cognito_idp_contract.sh`
  (the four-file broker delivery contract — pins that the terraform-written ASM
  document key set matches the spoke ExternalSecret's `dataFrom` extract and the
  ApplicationSet's non-optional secretKeyRef env, so a drift in the terraform
  writer breaks the unit gate before it breaks a live boot)

## Context

Phase-5 needed the Cognito app client's id and secret inside the Keycloak
realm import. That material is **Cognito-generated** (terraform's
`aws_cognito_user_pool_client` with `generate_secret = true` reads it; no
one chooses it). The platform's existing secret abstraction — the
XPlatformSecret chain under ADR-0012 — is generate-once BY DESIGN: a
Password generator feeds a SecretVersion writer. It structurally cannot
carry a value that originates outside the platform, and the pre-ADR-0012
note in docs/operations.md ("deliver the client secret via the
keycloak-oidc-clients XPlatformSecret") was written when the chain was an
empty shell whose values arrived out of band — a state the SUBSTRATE
definition of done has since banned. Session PR #255 had to draw a real
boundary: who writes externally-sourced secrets into ASM, and under what
name?

## Decision

Externally-generated secret material consumed by platform workloads is
written to ASM by the component that owns its source of truth (terraform
for the Cognito app client), under the platform's deterministic
`k8-platform/<scope>/<name>` naming (here `k8-platform/base/cognito`),
tagged with that component's ownership (`ManagedBy=terraform`, never
`PlatformAbstraction=PlatformSecret`), and consumed by committed
ExternalSecrets exactly like platform-generated material. The
XPlatformSecret chain carries ONLY platform-generated material.

## Alternatives considered

- **Route it through the keycloak-oidc-clients XPlatformSecret** (the
  stale ops-doc plan): rejected — the ADR-0012 chain generates its own
  random value; a second writer into the same container would fight the
  SecretVersion MR's drift detection (AWSCURRENT flapping between two
  owners), and terraform cannot be that writer anyway (base applies
  before the container exists; terraform has no retry-until-exists).
- **Cluster-facts annotations (ADR-0010) for the non-secret URLs +
  ASM only for the secret**: rejected — splits one mutually-consistent
  document (all values derive from the same user pool) across two
  transports, and bloats the spoke registration Secret's contract with
  base-layer facts that are not cluster facts.
- **Extend XPlatformSecret with an "external material" mode**: rejected
  — reintroduces the banned out-of-band-write shape ADR-0012 exists to
  kill, one spec field away.

## Consequences

- Easier: zero IAM changes (the ESO/crossplane read scope was already
  `k8-platform/*`); the consumer side is the same live-proven
  ES-pull pattern as keycloak-admin; the document's eight keys stay
  mutually consistent because one `jsonencode` writes them all.
- Harder / accepted: there are now TWO writers of `k8-platform/*` ASM
  names (terraform and the Composition) distinguished only by tags and
  naming discipline — the live-verify `secretsmanager-secret-live` check
  selects on the `PlatformAbstraction=PlatformSecret` tag pair
  specifically so terraform-owned containers stay out of its assertions.
  A future name collision between a terraform-owned scope ("base") and a
  Kubernetes namespace of the same name is possible; the convention
  reserves `k8-platform/base/*` for terraform.
- The realm's fail-closed env delivery (ADR-0014) depends on this
  document existing before the keycloak pods can start — a fresh-build
  ordering satisfied trivially (base applies first) but a POST-MERGE
  rollout onto an already-live cluster requires a base re-apply before
  the StatefulSet can roll (observed and handled the same session:
  the post-merge base dispatch immediately after #255 merged).

## References

- [`../../retrospective/2026-07-06-255.md`](../../retrospective/2026-07-06-255.md) — the source retrospective (Phase 3).
- [`./0014-realm-config-via-import-time-env-substitution.md`](./0014-realm-config-via-import-time-env-substitution.md) — the consuming mechanism.
- [`./0012-secretversion-writes-mr-owned-asm-values.md`](./0012-secretversion-writes-mr-owned-asm-values.md) — the generate-once boundary this ADR complements.
- `terraform/base/cognito.tf`, `platform-services/keycloak/spoke/keycloak-cognito-idp-externalsecret.yaml`, `tests/unit/test_keycloak_cognito_idp_contract.sh` — the implementation + its contract pin (PR #255).
