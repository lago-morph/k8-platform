# ADR: Hash inline manifest bodies into `terraform_data.triggers_replace`

- **ID**: ADR-f3feb391df
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-70.md
- **PRs covered**: #66, #67, #68

## Context

The repo uses `terraform_data` resources with `local-exec` provisioners as the bridge between Terraform-managed infrastructure (EKS clusters, IRSA roles) and Crossplane / ArgoCD bootstrap manifests that must be `kubectl apply`'d into the cluster. The pattern is documented in `terraform/management/helm.tf`: each provisioner contains an inline YAML manifest interpolated with Terraform values (IRSA ARNs, chart versions), wrapped in a shell heredoc.

The original convention listed only the templated *input values* in `triggers_replace` — IAM role ARN, chart version, package URL. This works as long as input-value changes are the only way the rendered manifest can change. **It silently breaks the moment a developer edits the manifest body itself** (adding a field, changing a name, fixing typo): the inputs are unchanged, so Terraform sees no diff and the next `apply` reports `Apply complete! Resources: 0 added, 0 changed, 0 destroyed`. The intended cluster change never happens.

This bug class consumed three back-to-back PRs (#66 → #67 → #68) during the late-2026-05-24 session before the rule was formalized.

Evidence:
- PR #66 added `metadata.name: upbound-provider-family-aws` to the `DeploymentRuntimeConfig` manifest. Apply silently no-op'd. Verified by terraform-test run [26354235231](https://github.com/lago-morph/k8-platform/actions/runs/26354235231) (`Apply complete! Resources: 0 added`).
- PR #67 extracted the manifest into `local.crossplane_aws_provider_manifest` and added `sha256(local.crossplane_aws_provider_manifest)` to `triggers_replace`. Apply replaced the resource correctly ([run 26354934978](https://github.com/lago-morph/k8-platform/actions/runs/26354934978)).
- PR #68 added a `kubectl delete deploy` step to the local-exec command *outside* the hashed manifest local. That step was again invisible to triggers; needed an explicit `"provisioner-command-v2"` sentinel.

The pre-existing convention in the same file (`terraform_data.argocd_bootstrap`, helm.tf:360–363) already uses `filesha1("${path.module}/../../argocd/bootstrap.yaml")` to cover its file-backed manifest body. The bug was that the inline-manifest resources hadn't adopted the same idiom.

## Decision

All `terraform_data` resources with `local-exec` provisioners that template inline manifests or command bodies MUST include a `sha256(local.<body>)` (or `filesha1(...)` for file-backed sources) in their `triggers_replace` list — listing only templated input values is insufficient and produces silent no-op applies.

Implementation conventions:

1. **Extract the inline manifest** into a named `local.<resource_name>_manifest`. Place the `locals { ... }` block immediately above the `terraform_data` resource.
2. **Hash the local** with `sha256(local.<resource_name>_manifest)` and add it to `triggers_replace`.
3. **For command-body changes outside the local** (loops, conditionals, additional `kubectl` calls), add a `"<resource>-command-v<N>"` sentinel string to `triggers_replace`. Bump `N` whenever the command body changes. Document the bump with a code comment.
4. **Audit the existing `terraform_data` resources** (`crossplane_aws_provider`, `crossplane_function_patch_and_transform`, `crossplane_provider_aws_secretsmanager`, `kyverno_audit_policies`) against the rule on next touch.

## Alternatives considered

**(a) Use the `kubernetes` Terraform provider instead.** Rejected because the provider requires a live EKS API server at plan time, which we don't have during the initial phase-0 → phase-1 bootstrap. The whole reason for the `terraform_data` + `local-exec` pattern is to defer kubectl until apply time without dragging the K8s provider into the dependency graph.

**(b) Drive the bootstrap manifests through ArgoCD only.** This works for everything *after* the `argocd_bootstrap` one-shot fires, but the bootstrap itself (and the Crossplane provider / function packages installed via `terraform_data`) must run from Terraform — there's no ArgoCD yet to run them. The `terraform_data` pattern stays; the rule fixes how it's used.

**(c) Use the `terraform-provider-helm` `helm_release` with `set { name = ..., value = ... }` for the Crossplane provider package.** Rejected because `helm_release` is designed for Helm charts, and the Crossplane Provider / DeploymentRuntimeConfig manifests are not packaged as a chart. Wrapping them in a one-off chart adds maintenance burden for no benefit.

**(d) Audit by external tooling (e.g., a linter that flags `terraform_data` + `local-exec` without `sha256(local)` in triggers).** Worth doing eventually but doesn't supersede the convention itself. Captured as a pending follow-up (linter under `tests/unit/test_terraform_data_triggers.sh`).

## Consequences

**Easier:**

- Manifest edits are now visible to Terraform. A small body-only change (adding a label, fixing a typo) triggers a replace at the next `apply`.
- The convention generalizes — the same `sha256(local.x)` pattern works for any `terraform_data` resource regardless of whether the body is YAML, JSON, or shell.
- New `terraform_data` resources follow a clear template; reviewers can spot violations by reading `triggers_replace` in isolation.

**Harder:**

- Every body edit forces a destroy-and-recreate of the `terraform_data` resource, which means the `local-exec` re-runs in full. For the Crossplane provider case this is fine (idempotent `kubectl apply`). For resources where re-running is expensive or non-idempotent, the convention needs case-by-case adjustment (rare).
- The sentinel-bump idiom for command-body changes is fragile — depends on the author remembering to bump it. Documented via code comments at the sentinel.

**Accepted trade-off:**

- A correct destroy-and-recreate cycle is preferable to a silent no-op apply. The session lost ~3 PRs to the silent-no-op failure mode; the destroy-and-recreate cost is negligible by comparison.

## References

- [`../2026-05-25-70.md`](../2026-05-25-70.md) — source retrospective.
- [`./SKILL-SPEC-9914e10966-terraform-data-hash-all-deps.md`](./SKILL-SPEC-9914e10966-terraform-data-hash-all-deps.md) — the skill that operationalizes this ADR.
- [`./AGENTS-MD-15a88ad1de-hash-every-dependency-into-terraform-data-triggers-replace.md`](./AGENTS-MD-15a88ad1de-hash-every-dependency-into-terraform-data-triggers-replace.md) — agents-file rule for the same convention.
- PRs: #66 (introduced the silent-no-op bug), #67 (added `sha256(local.x)`), #68 (added command-body sentinel).
- `terraform/management/helm.tf:360–363` — pre-existing `filesha1(...)` precedent.
