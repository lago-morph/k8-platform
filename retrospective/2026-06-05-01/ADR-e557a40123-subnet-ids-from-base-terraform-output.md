# ADR: Inject the platform cluster's subnet IDs from the base Terraform output

- **ID**: ADR-e557a40123
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-05
- **Source retrospective**: ../2026-06-05-01.md
- **PRs covered**: none (design decision; no PR opened this session)

## Context

The `XPlatformCluster` Composition needs the private subnet IDs of the
shared VPC to provision the platform EKS cluster and its node group.
`AGENTS.md` §8.1 forbids committing account-ephemeral identifiers (subnet
IDs rotate with the account) to git, so the IDs cannot be hardcoded in the
`clusters/platform/platform-cluster-claim.yaml` XR. The handoff's D1 item
recommended a "tag-based `subnetIdSelector`," but investigation this
session established that this is not implementable: Crossplane reference
selectors (`subnetIdSelector.matchLabels`) resolve against the Kubernetes
`metadata.labels` of Crossplane-managed `Subnet` resources, not against AWS
resource tags. Our private subnets are created by `terraform/base`, so they
are not Crossplane managed resources and carry no k8s labels for a selector
to match (confirmed via crossplane/provider-aws#976). The subnet IDs are,
however, already exposed: `terraform/base/outputs.tf` emits
`private_subnet_ids`, and `terraform/management` already consumes base
outputs via `data.terraform_remote_state.base`.

## Decision

`terraform/management` sources the platform EKS cluster's private subnet
IDs from `terraform/base`'s `private_subnet_ids` output (read via remote
state) at apply time, rather than committing the IDs to git, resolving them
with a Crossplane tag-selector, or rediscovering them at runtime via an AWS
tag lookup.

## Alternatives considered

- **Tag-based `subnetIdSelector` on the EKS Cluster/NodeGroup MRs** —
  rejected as technically infeasible: Crossplane selectors match k8s
  labels on Crossplane-managed resources, not AWS tags, and the subnets
  are Terraform-managed (no MRs, no k8s labels). Would require importing
  the subnets as Observe-mode MRs, which itself needs the IDs.
- **EnvironmentConfig populated by an `aws_subnets` tag lookup, consumed
  via `function-environment-configs`** — rejected as over-engineered for
  the need: adds a function install, a feature-flag concern, a
  render-harness change (the SPEC-S9 author-time gate has documented
  friction with `function-environment-configs`), and an XRD rewrite, all
  to rediscover a value an upstream module already exposes.
- **CI / sync-time templating of the XR** — rejected: couples cluster
  provisioning to a CI step and risks the substituted IDs landing in git.
- **Crossplane-managed subnets (move subnet creation out of
  terraform/base)** — rejected: largest blast radius; relocates
  networking the base module owns.

## Consequences

Easier: the IDs flow from the single source of truth (base state) at
apply time, satisfying §8.1 with no new Crossplane machinery, no feature
flags, and no changes to the render-golden harness. Harder / open: the
*delivery* mechanism from the management apply to the Crossplane EKS
Cluster MR is still to be specified — the leading candidate that fits the
repo's existing pattern (`terraform_data` + `local-exec kubectl apply`, no
kubernetes TF provider) is for `terraform/management` to write a small
`EnvironmentConfig` (or equivalent) populated with the `private_subnet_ids`
values and have the Composition read it; the exact shape is an
implementation detail to settle when the work is picked up. Trade-off
accepted: a soft coupling between the management apply and the platform
cluster's subnet wiring (the EKS Cluster MR's subnets are only correct
after a management apply has published the current account's IDs).

## References

- [`../2026-06-05-01.md`](../2026-06-05-01.md) — the source retrospective.
- `terraform/base/outputs.tf` — `private_subnet_ids` output (the source of truth).
- `terraform/management/main.tf` — `data.terraform_remote_state.base` (already reads base outputs).
- `crossplane/compositions/platform-cluster.yaml` — the consumer (currently patches `spec.vpc.subnetIds`).
- crossplane/provider-aws#976 — selectors match k8s labels, not AWS tags.
- PRs the decision was made in: none.
