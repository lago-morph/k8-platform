# ADR: Phase 2 resources are GitOps-managed; Terraform's role ends at terraform_data.argocd_bootstrap

- **ID**: ADR-8e997ffcfd
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-24
- **Source retrospective**: ../2026-05-24-62.md
- **PRs covered**: #52

## Context

PR #52 originated in a failed `phase=management apply-and-verify` run where Terraform tried to apply `policies/audit/09-platform-secret-namespace-allowed.yaml` BEFORE ArgoCD installed the PlatformSecret XRD CRD. Kyverno's admission webhook rejected the policy with `unable to convert GVK to GVR for kinds PlatformSecret`. The clean fix moved policy 09 to `crossplane/policies/` with `argocd.argoproj.io/sync-wave: "1"` so it lands after the XRDs (wave 0). This established the boundary: anything that depends on a GitOps-installed CRD CANNOT be in Terraform-applied paths.

## Decision

Phase 2's XRDs, Compositions, ClusterPolicies tied to platform.k8-platform.io kinds, and ClusterSecretStore are owned by ArgoCD-synced paths (`crossplane/`, `clusters/management/`), and Terraform's only touch on them is the one-shot `terraform_data.argocd_bootstrap` in `terraform/management/helm.tf` that kubectl-applies `argocd/bootstrap.yaml` once at the end of phase-1 apply.

## Alternatives considered

- **Keep policy 09 in `policies/audit/` and add an explicit ordering hack in Terraform** — rejected because it couples Terraform to GitOps sync ordering. Brittle.
- **Eliminate `terraform_data.kyverno_audit_policies` entirely and move all 8 audit policies to ArgoCD** — rejected as scope creep for this session; the other 7 policies don't depend on XRDs. Future work, separate ADR.

## Consequences

**Easier:** authoring future ClusterPolicies that reference platform abstractions (just drop in `crossplane/policies/`); reasoning about the GitOps boundary; teardown/rebuild of phase 2 (no Terraform-state coupling). **Harder:** none observed yet; future Terraform-resource-with-a-CRD-dependency would need the same relocation pattern. **Trade-off accepted:** phase-2 resources now require ArgoCD healthy before they reach the cluster; if ArgoCD is broken, phase 2 is broken — but that's already true for everything else under `argocd/`.

## References

- [`../2026-05-24-62.md`](../2026-05-24-62.md) — the source retrospective.
- [`./SKILL-SPEC-10ebf2a133-manual-dispatch-as-kubectl-bridge.md`](./SKILL-SPEC-10ebf2a133-manual-dispatch-as-kubectl-bridge.md) — related skill spec.
- [`./SKILL-SPEC-738ec4c6b3-kyverno-argocd-drift-defense.md`](./SKILL-SPEC-738ec4c6b3-kyverno-argocd-drift-defense.md) — related skill spec.
- PRs the decision was made in: #52.
