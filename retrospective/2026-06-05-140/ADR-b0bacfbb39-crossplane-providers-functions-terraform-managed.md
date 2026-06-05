# ADR: Crossplane providers and functions are Terraform-managed on the management cluster

- **ID**: ADR-b0bacfbb39
- **Status**: Draft (not yet adopted to docs/decisions/)
- **Date**: 2026-06-05
- **Source retrospective**: ../2026-06-05-140.md
- **PRs covered**: #140

## Context

Phase 3 needed four additional Crossplane provider packages (eks, iam, acm,
route53) and a second function (`function-environment-configs`) on the
management cluster, plus an IRSA policy extension and a `cluster-network`
EnvironmentConfig sourced from the base Terraform output. When the user
challenged the plan ("aren't we using gitops here?"), it forced an explicit
articulation of a boundary the repo had only followed implicitly: which
Crossplane machinery is GitOps-managed and which is Terraform-managed.

The existing pattern (PR history through phase 2) already installs
`provider-family-aws`, `provider-aws-secretsmanager`, and
`function-patch-and-transform` via `terraform/management` using the
`terraform_data` + `local-exec kubectl apply` idiom — because the family
provider's `DeploymentRuntimeConfig` pins its ServiceAccount name to match
an IRSA role ARN that is itself a Terraform output, and IRSA (IAM) can only
be created by Terraform. The XRDs, Compositions, and XRs, by contrast, are
GitOps-managed (the `crossplane-resources` ArgoCD Application syncs
`crossplane/`). Phase 3's new providers/function followed the established
Terraform side for consistency rather than being split into GitOps.

## Decision

The management cluster's Crossplane **bootstrap layer** — provider packages,
functions, IRSA policies/roles, and the `cluster-network` EnvironmentConfig
(whose data comes from base Terraform outputs) — is installed and owned by
`terraform/management`; the **platform layer** — XRDs, Compositions, and the
per-cluster XR instances — is GitOps-managed via ArgoCD from `crossplane/`
and `clusters/`.

## Alternatives considered

- **Move the new service providers + function into GitOps** (declare them as
  `pkg.crossplane.io` manifests under `crossplane/`, synced by ArgoCD).
  Rejected: inconsistent with the existing family/secretsmanager/PT installs,
  and the family provider's install is already coupled to a Terraform IRSA
  output + SA-name pin; splitting providers across two control planes
  invites ordering and drift bugs for no gain.
- **Move everything (including IRSA) to Crossplane/GitOps.** Rejected: IRSA
  is IAM, which the management cluster is provisioned by Terraform to own
  (DESIGN §Iteration 1, "Terraform is the break-glass layer"); and the
  EnvironmentConfig's data is a base Terraform output, so Terraform is its
  natural source.

## Consequences

- Easier: a single, consistent home for the bootstrap layer; IRSA and the
  values it depends on stay where AWS-IAM Terraform already lives; the
  EnvironmentConfig is populated directly from base remote state.
- Harder / accepted: bringing a new provider or function online requires a
  `terraform/management apply` (a CI `terraform-test.yml` dispatch), not just
  a git merge — so the bootstrap layer changes are gated on a Terraform run
  the agent dispatches, while platform-layer changes converge purely via
  ArgoCD. This two-speed model must be explained whenever someone expects
  "everything is GitOps."

## References

- [`../2026-06-05-140.md`](../2026-06-05-140.md) — the source retrospective.
- `terraform/management/crossplane-phase3.tf`, `terraform/management/helm.tf`, `terraform/management/irsa.tf` — the bootstrap layer.
- `argocd/apps/crossplane-resources.yaml` — the GitOps platform layer.
- `docs/decisions/0003-acm-via-crossplane-for-cluster-tls.md` — the sibling TLS decision.
- PRs the decision was made in: #140.
