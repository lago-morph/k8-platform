# ADR: EKS clusters provisioned for hub-spoke GitOps default to API_AND_CONFIG_MAP authentication mode

- **ID**: ADR-069c89119e
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-07
- **Source retrospective**: ../2026-06-07-165.md
- **PRs covered**: #165

## Context

The platform-cluster Crossplane Composition provisions spoke EKS clusters that the
hub ArgoCD must register and sync to. The chosen hub→spoke trust mechanism is **EKS
Access Entries** (the XSpokeAccess Composition maps the `${cluster}-argocd` IAM role
to `AmazonEKSClusterAdminPolicy` via an AccessEntry + AccessPolicyAssociation, and
the ArgoCD cluster Secret authenticates with that role — REQ-NF-03, no static
tokens). Access Entries require the cluster's `accessConfig.authenticationMode` to be
`API` or `API_AND_CONFIG_MAP`. The EKS **default is `CONFIG_MAP`**, under which the
EKS API rejects `CreateAccessEntry`/`ListAccessEntries` with
`InvalidRequestException`. In auto-012 the Composition never set `accessConfig`, so
the spoke came up `CONFIG_MAP` and the entire spoke-registration path was blocked
with a late, non-obvious error.

## Decision

Set `accessConfig.authenticationMode: API_AND_CONFIG_MAP` on every
platform-provisioned EKS cluster's Cluster MR so EKS AccessEntries (the hub→spoke
ArgoCD trust mechanism) can be created.

## Alternatives considered

- **`API` (entries-only).** Drops the aws-auth ConfigMap path entirely. Rejected as
  the default: it is stricter and one-way, and removing the ConfigMap path can strand
  node bootstrap / existing tooling that still relies on aws-auth. `API_AND_CONFIG_MAP`
  is a strict superset that keeps both paths working and is the AWS-recommended
  migration target.
- **Leave `CONFIG_MAP` and grant hub access via the aws-auth ConfigMap.** Rejected:
  requires writing the hub role into each spoke's aws-auth ConfigMap (cross-cluster
  write at registration), is exactly the static/imperative coupling Access Entries
  exist to remove, and conflicts with the no-static-token requirement.

## Consequences

- The hub→spoke Access Entry mechanism works at cluster create with no post-hoc
  cluster update. Easier: spoke registration, IRSA-less cross-cluster auth.
- The CONFIG_MAP→API_AND_CONFIG_MAP upgrade is one-way (cannot revert to CONFIG_MAP),
  accepted as harmless (it is a superset).
- A regression test asserts the Composition's Cluster MR sets API or
  API_AND_CONFIG_MAP, so the default can't silently regress.

## References

- [`../2026-06-07-165.md`](../2026-06-07-165.md) — the source retrospective.
- PR #165 commit `11ed48f` (fix + render fixture + unit test).
- crossplane/compositions/platform-cluster.yaml (eks-cluster MR `accessConfig`).
