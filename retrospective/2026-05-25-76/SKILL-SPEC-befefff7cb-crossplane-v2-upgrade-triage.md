# Spec: `crossplane-v2-upgrade-triage`

- **ID**: SKILL-SPEC-befefff7cb
- **Source retrospective**: ../2026-05-25-76.md

## Intent

Systematically upgrade a Crossplane installation to a new major/minor version by first isolating beta-feature regressions, then schema-validation rejections, then RBAC gaps, using the kind+chainsaw harness as the fast iteration loop before touching the live EKS cluster. This skill exists because the 2.0.1 → 2.3.0 upgrade produced three cascading bugs in that exact order, each masking the next, and each class requires a different diagnosis tool.

## Trigger

**Direct triggers:**
- "Upgrade Crossplane to vX.Y"
- "Bump the Crossplane chart version"
- "Crossplane scenarios are failing after an upgrade"
- "Chainsaw times out after the Crossplane bump"

**Proactive triggers:**
- A new Crossplane stable release is available and the project is more than one minor version behind.
- Chainsaw scenarios that previously passed are now failing after a chart version bump.

**Negative triggers:**
- Provider-only version bumps (no Crossplane core chart change). Use the standard chainsaw dispatch + wait pattern instead.
- Crossplane configuration changes that don't involve a version bump.

## Inputs

- Current `crossplane_version` in `terraform/management/variables.tf`
- Target version (e.g. `2.3.0`)
- The Crossplane release notes and changelog for the target version
- Access to the Crossplane source `core.go` for the target version (for flag name verification)
- The kind+chainsaw harness (`tests/chainsaw/run.sh`, `tests/chainsaw/versions.env`)
- AWS credentials for the chainsaw harness (real AWS calls required for PlatformSecret scenarios)

## Outputs

- Updated `terraform/management/variables.tf` (`crossplane_version`, optionally provider versions)
- Updated `terraform/management/helm.tf` (beta-feature disable args)
- Updated `tests/chainsaw/versions.env` (`CROSSPLANE_CHART_VERSION`, optionally provider versions)
- Updated `tests/chainsaw/run.sh` (matching beta-feature disable args in `helm install crossplane`)
- Any Composition fixes (`crossplane/compositions/*.yaml`) for SSA schema rejections
- Any new RBAC manifests (`crossplane/rbac/`) for non-provider CRD access
- Green chainsaw run before PR is opened

## Workflow

1. **Read the release notes.** Fetch `https://docs.crossplane.io/latest/release-notes/` for the target version. Look for: (a) newly-default beta features, (b) strict-decoding / SSA changes, (c) RBAC enforcement changes.

2. **Bump the version in isolation first.** In `tests/chainsaw/versions.env`, bump `CROSSPLANE_CHART_VERSION` to the target. Do NOT change provider versions yet.

3. **Dispatch chainsaw and read the failure.** If chainsaw fails, classify the failure by error class:

   - **Crossplane pod crashloop / helm timeout**: a feature flag is wrong. Check `kubectl -n crossplane-system logs deploy/crossplane | grep -i unknown` for the bad flag. Verify flag names from source (see Step 4).
   - **`field not declared in schema` / SSA composition error**: a Composition has a field the provider's CRD schema no longer accepts. Find it in the XR's events, remove it.
   - **`is not allowed to [get list watch ...]` RBAC warning + composite never Ready**: Crossplane SA lacks RBAC on a CRD it tries to compose. Create a ClusterRole + ClusterRoleBinding grant.
   - **Provider `CreatedExternalResource` delayed >60s**: provider package version incompatibility with the new core. Bump provider to latest v1.x and re-run chainsaw.

4. **Verify beta flag names from source before writing them.** For each beta feature to disable, confirm the CLI flag name from the Crossplane source code for the target version:
   ```bash
   # Example: check the flag for SSA claims in Crossplane 2.3
   # Source: https://github.com/crossplane/crossplane/blob/v2.3.0/cmd/crossplane/core.go
   # Field: EnableSSAClaims → flag: --enable-ssa-claims
   ```
   Never guess from the struct field name. Unknown flags cause a pod crashloop and a 5-minute helm timeout per attempt.

5. **Apply beta-feature disables identically in both places.** Once you know the correct flag names, add `--enable-X=false` args to:
   - `terraform/management/helm.tf` `helm_release.crossplane` `set{}` blocks (`args[0]`, `args[1]`, …)
   - `tests/chainsaw/run.sh` `helm install crossplane` `--set 'args[N]=...'` flags

   The two must be identical. Drift silently invalidates chainsaw as a proxy for production.

6. **Fix SSA schema rejections.** If step 3 surfaces `field not declared in schema`, grep the affected Composition for the field name and remove it. The field was previously ignored by the lenient v1 reconciler; the new SSA path rejects it.

7. **Fix RBAC gaps.** If step 3 surfaces RBAC warnings for a non-provider CRD (e.g. `externalsecrets.external-secrets.io`), create `crossplane/rbac/NN-<name>.yaml` with a ClusterRole granting the standard set of verbs (get, list, watch, create, update, patch, delete) on the resource + status subresource, bound to `system:serviceaccount:crossplane-system:crossplane`. Wire the new file into the ArgoCD Application's include filter and into `tests/chainsaw/run.sh` (`kubectl apply -f ...` after Crossplane install).

8. **Confirm chainsaw green before touching the live cluster.** Only after all three chainsaw scenario classes pass (claim-creates-secret, claim-deletion-cleanup, claim-rotation) should you proceed to bump `terraform/management/variables.tf` and dispatch `management apply-and-verify`.

9. **Bump management and verify live cluster.** Update `terraform/management/variables.tf` with the same version changes, dispatch `terraform-test.yml` `phase=management action=apply-and-verify`, confirm ArgoCD sync, run a probe claim end-to-end.

## Concrete examples

### Example 1: 2.0.1 → 2.3.0 (this session)

**Input**: `CROSSPLANE_CHART_VERSION="2.0.1"`, target `2.3.0`.

**Step 2 result**: bumped `versions.env`, dispatched chainsaw.

**Step 3 failure 1** (commit `a0179e3`): `field not declared in schema: forceOverwriteReplica`. Removed `forceOverwriteReplica: true` from `crossplane/compositions/platform-secret.yaml`.

**Step 3 failure 2** (commit `d056cd7`): `crossplane-system:crossplane is not allowed to ... externalsecrets`. Created `crossplane/rbac/01-crossplane-externalsecrets.yaml`. Added `kubectl apply -f ../../crossplane/rbac/01-crossplane-externalsecrets.yaml` in `run.sh`. Added `rbac/*.yaml` to ArgoCD include filter.

**Step 3 failure 3** (commit `de6132c`): crashloop from `--enable-claim-ssa=false` (unknown flag). Verified correct name from `core.go`: `--enable-ssa-claims=false`.

**Step 3 failure 4** (Bug 3 — still open): provider v1.12.0 delays CreateSecret by 2+ minutes. Resolution: bump provider to latest v1.x (not done this session).

### Example 2: verifying flag names from source

```bash
# Wrong: --enable-claim-ssa=false  (struct field name is EnableClaimSSA — NOT the flag)
# Right: --enable-ssa-claims=false  (from core.go: flagName = "enable-ssa-claims")

# How to find it:
# 1. Go to https://github.com/crossplane/crossplane/blob/v2.3.0/cmd/crossplane/core.go
# 2. Search for EnableSSAClaims
# 3. Find: fs.BoolVar(&o.EnableSSAClaims, "enable-ssa-claims", ...)
# 4. Use: --enable-ssa-claims=false
```

## Anti-patterns

- **Guessing beta flag names from struct field names.** `EnableSSAClaims` → `--enable-ssa-claims`, NOT `--enable-claim-ssa`. Always verify from source. Wrong flag = crashloop + 5-minute helm timeout per attempt.
- **Fixing only helm.tf and not run.sh.** The two must be identical. Run.sh left at old flags makes chainsaw test a different Crossplane configuration than the live cluster.
- **Bumping provider versions at the same time as the core chart.** This conflates two change classes and makes it impossible to bisect which change caused a regression. Bump core first, validate chainsaw, then bump providers separately.
- **Opening the PR before chainsaw is green.** Per AGENTS.md §6.7, the heavy CI workflow must be green before the PR is opened. If the PR has ten red chainsaw runs in its history, every red run is noise that obscures the root cause.

## Acceptance criteria

- [ ] Chainsaw all three PlatformSecret scenarios pass (claim-creates-secret, claim-deletion-cleanup, claim-rotation)
- [ ] `terraform/management/helm.tf` and `tests/chainsaw/run.sh` have identical Crossplane feature-flag args
- [ ] `CROSSPLANE_CHART_VERSION` in `versions.env` matches `crossplane_version` in `variables.tf` (enforced by `test_chainsaw_crossplane_matches_management.sh`)
- [ ] `management apply-and-verify` completes with the new chart version
- [ ] A probe PlatformSecret claim reaches `Ready=True` within 180s on the live cluster

## Files this skill creates / modifies

- `terraform/management/variables.tf` — bumped `crossplane_version` (and optionally provider versions)
- `terraform/management/helm.tf` — added `args[N]` set blocks for beta-feature disables
- `tests/chainsaw/versions.env` — bumped `CROSSPLANE_CHART_VERSION`
- `tests/chainsaw/run.sh` — matching `--set args[N]` in `helm install crossplane`
- `crossplane/compositions/*.yaml` — SSA schema fixes (remove unknown fields)
- `crossplane/rbac/NN-<name>.yaml` — new RBAC grants for non-provider CRDs (if needed)
- `argocd/apps/crossplane-resources.yaml` — updated include filter (if new RBAC dir added)
