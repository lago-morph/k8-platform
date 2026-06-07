# Spec: `verify-upbound-package-tag-published`

- **ID**: SKILL-SPEC-870382aef7
- **Source retrospective**: ../2026-06-07-162.md

## Intent

Crossplane provider/function packages are pinned by tag in terraform (e.g.
`xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.16.0`). Nothing in the
local toolchain validates that reference — `crossplane render` and kubeconform only
check composition/MR schemas, and `terraform plan` only checks HCL. A wrong or
non-existent tag therefore passes every gate and fails only at live install with
`cannot unpack package: ... MANIFEST_UNKNOWN ... 404`, after a full (~20-min)
management apply. This skill verifies, in seconds, that a pinned package tag both
exists in the registry and is compatible with the cluster's Crossplane major
version, before the change is committed/merged.

## Trigger

Activate when: pinning or bumping any `xpkg.upbound.io/...` provider or function
version in terraform or a Provider/Function manifest; a subagent authored a
package version you didn't independently confirm; or an install fails with
`MANIFEST_UNKNOWN` / `cannot resolve ... to digest` / `incompatible Crossplane
version`. Negative trigger: the tag is already pinned + proven installed live.

## Inputs

- The package repository path and candidate tag (e.g. `crossplane-contrib/provider-kubernetes`, `v1.2.1`).
- The cluster's Crossplane version (here 2.3.0, from `tests/chainsaw/versions.env`).

## Outputs

- A go/no-go: the tag is published AND v2-compatible (or the corrected tag to pin).
- No cluster mutation.

## Workflow

1. **List published tags.** Fetch the marketplace listing
   `https://marketplace.upbound.io/providers/<org>/<pkg>` (WebFetch) or HEAD the
   registry manifest `https://xpkg.upbound.io/v2/<org>/<pkg>/manifests/<tag>` — a
   200 means published, 404 means not. The marketplace also shows publish dates.
2. **Check Crossplane-version compatibility.** Read the release notes / `whats-new`
   for the tag: Crossplane v2 introduced a hard package-model break, so old `v0.x`
   provider tags are v1-only. Prefer the release line that explicitly states v2
   support (for provider-kubernetes that is the `v1.x` line).
3. **Pick the latest published, v2-compatible stable tag** unless a newer one is
   needed; record why in the variable's description.
4. **(Optional live confirm)** after install, a kube-diagnose dump of the
   ProviderRevision `Installed=True/Healthy=True` closes the loop.

## Concrete examples

1. **The bug.** `provider-kubernetes:v0.16.0` → marketplace shows only
   v0.18.0/v1.0.0/v1.1.0/v1.2.0/v1.2.1; v0.16.0 absent → 404 at install. Fix: pin
   `v1.2.1` (latest stable; v1.x = first Crossplane-v2 line).
2. **Counter-check that passes.** `function-environment-configs:v0.3.0` and
   `function-patch-and-transform:v0.10.6` (already in versions.env) resolve fine —
   a HEAD on their manifests returns 200, confirming the registry path idiom.

## Anti-patterns

- Trusting a subagent-authored or model-recalled version tag without a registry check.
- Assuming render/kubeconform/terraform-plan validate the package reference — they don't.
- Pinning the newest GitHub release without confirming it's published to `xpkg.upbound.io` (GitHub tags and registry tags can differ).

## Acceptance criteria

- Distinguishes a published tag (200) from an unpublished one (404) before commit.
- Flags a pre-v2 tag when the cluster is Crossplane v2.
- Emits the corrected tag to pin with a one-line rationale.

## Files this skill creates / modifies

- None directly; it informs a `*_version` default in `terraform/management/variables.tf`
  (or the equivalent pinned-version source).
