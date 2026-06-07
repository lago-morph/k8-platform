# 0005 — ESO for lightweight secrets; XPlatformSecret for AWS-resource-grade secrets; no retrofit

- **ID**: ADR-34a3f6810d
- **Status**: Accepted
- **Date**: 2026-06-07
- **Source retrospective**: [`../../retrospective/2026-06-07-165.md`](../../retrospective/2026-06-07-165.md)
- **PRs covered**: #165 (the decision was reached reviewing the auto-012 follow-ups OI-2026-06-07-1 / -2 / -5)

## Context

Phase-3/5 (auto-012) surfaced three places that need a secret/config moved into or
between clusters:

- **OI-2026-06-07-1** — the `platform-spoke` ArgoCD cluster Secret (endpoint + CA +
  awsAuthConfig) needs a durable, GitOps form. The blocker was that ArgoCD's
  cluster-secret `config` requires `caData` embedded inside a JSON string, which
  Crossplane `provider-kubernetes` references cannot assemble.
- **OI-2026-06-07-5** — the `keycloak-db` RDS connection Secret is produced on the
  HUB (Crossplane runs there) but Keycloak runs on the SPOKE; the secret must cross
  clusters.
- The repo already has **`XPlatformSecret`** (XRD `xplatformsecrets.platform.k8-platform.io`
  + `crossplane/compositions/platform-secret.yaml`), a Crossplane composite that per
  claim renders (1) an AWS Secrets Manager `Secret` MR **and** (2) an ESO
  `ExternalSecret` that materialises it into a k8s Secret. It is working and in use.

The ESO documentation confirms `ExternalSecret` (reads provider → k8s) and
**`PushSecret`** (reads a k8s Secret or a `generatorRef` → **creates/updates** a
provider entry, with `updatePolicy`/`deletionPolicy` and on-push `template`)
together cover both directions, and `ExternalSecret.spec.target.template` can build
arbitrary string fields — including the caData-in-JSON `config` that blocked
provider-kubernetes. So plain ESO (PushSecret + ExternalSecret, optionally
`generatorRef` for generated secrets) covers "move/generate a value into Secrets
Manager and sync it to consumers" entirely, with no Crossplane secret abstraction in
the path.

`XPlatformSecret` manages the SM entry **as a full AWS resource** (KMS key, replica,
resource policy, tags) via the `secretsmanager` MR — capabilities ESO's SM target
does not expose.

## Decision

Use **ESO (`PushSecret` + `ExternalSecret`, optionally `generatorRef`) as the default
for routine secret movement and generation in every cluster**; **reserve the
`XPlatformSecret` Crossplane XRD for secrets that need AWS-resource-grade management**
(KMS key, cross-region replication, resource policy, tags); and **do not retrofit
already-working `XPlatformSecret` usages** — the rule is forward-looking only.

A corollary, recorded here because it is the enabling prerequisite: **ESO is a
baseline component in every cluster** (hub and all spokes), each with an
IRSA-backed `ClusterSecretStore` for AWS Secrets Manager. ESO install + per-cluster
configuration is owned by the cluster abstraction (the `XPlatformCluster` XRD /
its provisioning path), alongside the per-cluster ConfigMap of cluster facts
(OI-2026-06-07-2). See `ai/handoff.md` for the implementation task list.

## Alternatives considered

- **Use `XPlatformSecret` for everything (including OI-1/OI-5).** Rejected: it pulls
  in the Crossplane provider-aws `secretsmanager` MR, the composite reconciler, and
  the crossplane→ESO RBAC grant for cases that only need a value moved. Heavier than
  warranted; ESO alone suffices for value movement and even generation.
- **provider-kubernetes `Object` for the ArgoCD cluster Secret (OI-1).** Rejected:
  it cannot assemble the caData-in-JSON `config` (references copy a value to a field
  path, no string templating). ESO `target.template` solves exactly this.
- **Retrofit existing XPlatformSecret usages to plain ESO now.** Rejected
  explicitly: they work; churn for no behavioural gain risks regressions. The
  philosophy applies going forward only.

## Consequences

- Lighter secret plumbing for the common case (no Crossplane composite, no
  provider-aws Secret MR, no extra RBAC) and the caData-in-JSON blocker disappears.
- A hard new requirement: **every cluster must ship ESO + an IRSA `ClusterSecretStore`**
  (currently hub-only). This is now part of cluster provisioning.
- Two parallel secret mechanisms coexist (ESO direct + XPlatformSecret). Accepted:
  the boundary is crisp (AWS-resource-grade management → XPlatformSecret; otherwise
  → ESO), and not retrofitting avoids a migration.
- Generated secrets (e.g. a Keycloak admin password) can be ESO-native via
  `PushSecret` + `generatorRef`, so XPlatformSecret is not needed merely to *create*
  a secret in SM.

## References

- [`../../retrospective/2026-06-07-165.md`](../../retrospective/2026-06-07-165.md) — auto-012 retrospective.
- [`./open-issues.md`](./open-issues.md) — OI-2026-06-07-1 / -2 / -5.
- `crossplane/compositions/platform-secret.yaml`, `crossplane/xrds/platform-secret.yaml` — the XPlatformSecret abstraction.
- ESO PushSecret guide: https://external-secrets.io/latest/guides/pushsecrets/
- `ai/handoff.md` — the new-session implementation task list (run after the fresh AWS account is up).
