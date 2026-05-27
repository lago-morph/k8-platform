# ADR: Adopt Crossplane v2 provider line (v2.x Upbound packages)

- **ID**: ADR-7f3a9c1d24
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-26
- **Source retrospective**: ../2026-05-26-100.md
- **PRs covered**: #98 (initial bump, used wrong tag), #99 (the migration plan), #100 (v2.5.4 → v2.5.0 correction)

## Context

The repository runs Crossplane Helm chart `2.3.0` (Crossplane v2.3, GA on the v2 line). Until this session, the Upbound provider packages (`provider-family-aws`, `provider-aws-secretsmanager`) were pinned to `v1.12.0` — which is the v1.x line of Upbound providers, authored for and intended for Crossplane v1.

The mismatch produced an exact, reproducible symptom every time a `PlatformSecret` claim hit a chainsaw scenario or a live cluster: the Crossplane composite controller successfully created the AWS Secrets Manager `Secret` MR (`CreatedExternalResource` event fires; the secret physically exists in AWS — ESO successfully reads it), but the Crossplane provider's `Observe` call could not find that secret on subsequent reconciles (`PendingExternalResource: Waiting for external resource existence to be confirmed`). The MR never became `Ready`; the XR never became `Ready`; the claim stayed `Ready=False` indefinitely.

The chainsaw failure log (fetched via `ext-github`'s `download_job_logs` once the agent stopped speculating and followed the failure-log-first rule) revealed the asymmetry directly: ESO uses the same AWS credentials, the same region, the same secret name `k8-platform/<XR-uid>` — and ESO succeeds while the Crossplane provider fails. This isolates the root cause to the Crossplane provider, not AWS, not credentials, not region, not Secrets Manager state. The matching upstream bug (`crossplane-contrib/provider-upjet-aws#1565`) confirms: the v1.x Upbound provider line has a known external-name annotation handling issue that surfaces on Crossplane v2 control planes.

The repo's existing pattern — one cluster-wide `default` ProviderConfig shared by every Composition; static AWS credentials via Secret + ProviderConfig.spec.credentials.source=Secret pattern — is preserved in v2 via `ClusterProviderConfig` (cluster-scoped) and the same Secret-source mechanism. Migration cost is bounded: 29 files reference v1 API groups, both XRDs migrate from `claimNames`-style v1 CompositeResourceDefinition to namespaced `apiextensions.crossplane.io/v2` XRDs, both Compositions strip `deletionPolicy` and add `managementPolicies` + `providerConfigRef.kind: ClusterProviderConfig`.

## Decision

Adopt the Upbound Crossplane provider v2.x line — `provider-family-aws v2.5.0` and `provider-aws-secretsmanager v2.5.0` — and migrate all manifests, fixtures, schemas, and tests to the v2 namespaced model.

## Alternatives considered

1. **Stay on v1.12.0 and downgrade the Crossplane chart to v1.x.** Rejected. Crossplane v2 namespaced MRs, the `Pipeline` Composition mode, and `function-patch-and-transform` are all v2 features the repo already depends on. Downgrading the chart would force a full re-architecture of the Compositions, which is strictly more work than migrating the providers.
2. **Switch off Upbound providers to `crossplane-contrib/provider-aws` (the community line).** Rejected. The community line is in maintenance mode and lags v2 feature support. Upbound's v2.x packages are the actively-maintained successors and the upstream `crossplane-contrib/provider-upjet-aws` repo (which Upbound builds from) is the canonical source.
3. **Continue with `_smoke`-only chainsaw filter as a permanent workaround.** Rejected. The `_smoke` scenario doesn't validate any Composition — it just proves the chainsaw harness boots. The platform-secret and platform-cluster Compositions are the project's primary value-delivery surface; their reconciliation has to actually work.
4. **Wait for a hypothetical v3 release.** Rejected. Crossplane v3 is not announced; v2 is the stable supported line. Waiting indefinitely on a non-existent release defers value indefinitely.

## Consequences

**Easier:**
- All platform-secret scenarios pass chainsaw with real AWS once the migration plan executes (per the plan's Definition of Done §11).
- The `Verify chainsaw ran green on this commit` PR check stops being permanently bootstrap-blocked.
- The repo aligns with the upstream Upbound + Crossplane release cadence; future v2.x.y bumps are routine version bumps, not breaking re-architectures.
- Namespaced XRs simplify the claim/XR/MR lifecycle for the consumers (one resource per namespace, not the v1 cluster-scoped XR + namespaced claim split).

**Harder:**
- The migration is large in surface (29 files referencing v1 API groups) and risky in blast radius (both XRDs are BLAST — removing `claimNames` deletes the `PlatformSecret`/`PlatformCluster` CRDs cluster-wide, orphaning every live claim during the cutover window).
- Existing IRSA SA-name pin (`crossplane-system:upbound-provider-family-aws`) survives only if v2 honors the `DeploymentRuntimeConfig.serviceAccountTemplate.metadata.name` override; verified per Upbound docs but flagged as upstream "strongly discouraged." A future v2.6.x could deprecate the override.
- All schema-dependent tooling (kubeconform schema store with 53 JSON Schema files, render fixtures, golden files, integration test grep patterns) must regenerate against the v2 CRDs.

**Trade-offs knowingly accepted:**
- Wave 2 cutover (XRD migration + Composition migration + #91 rebase + SEG-3 test updates) must merge as a single stacked PR. There is no clean rollback: once v2 providers are installed, the v1 manifests are admission-rejected; `git revert` of the cutover stack does not restore service.
- The migration plan defers 5 open questions for the executor (drain-vs-import for live workloads, `wait-for-claim.sh` call-site ownership, Function v1beta1 served-status verification, Helm `--set args[]` audit, CRD URL path layout stability). These cannot be resolved at planning time.

## References

- [`../2026-05-26-100.md`](../2026-05-26-100.md) — the source retrospective.
- [`./SKILL-SPEC-d72f4a8b1c-multi-subagent-migration-plan.md`](./SKILL-SPEC-d72f4a8b1c-multi-subagent-migration-plan.md) — the planning pipeline used to author the migration.
- [`./SKILL-SPEC-1b3c9d7e02-marketplace-version-verify.md`](./SKILL-SPEC-1b3c9d7e02-marketplace-version-verify.md) — the version-verification skill that should have prevented PR #98's `v2.5.4` mispin.
- `ai/crossplane-v1-v2-un-fuckify/40-final-plan.md` (now on `main` post-PR #99) — the master execution plan with merge sequence, wave decomposition, and Definition of Done.
- [crossplane-contrib/provider-upjet-aws#1565](https://github.com/crossplane-contrib/provider-upjet-aws/issues/1565) — the upstream issue documenting the v1-line external-name bug.
- [Crossplane v2 upgrade guide](https://docs.crossplane.io/latest/guides/upgrade-to-crossplane-v2/)
- [Upbound v1→v2 migration guide](https://docs.upbound.io/getstarted/upgrade-to-upbound/migrate-configurations-v2/)
- PRs the decision was made in: #98, #99, #100.
