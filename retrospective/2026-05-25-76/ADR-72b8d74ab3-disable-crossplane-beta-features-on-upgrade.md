# ADR: Disable all newly-default Crossplane beta features on version upgrades

- **ID**: ADR-72b8d74ab3
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-76.md
- **PRs covered**: #74

## Context

Crossplane 2.3.0 turned on three beta features by default that were opt-in in 2.0.x:
`EnableBetaRealtimeCompositions`, `EnableBetaClaimSSA`, and
`EnableBetaCustomToManagedResourceConversion`. When the project upgraded from 2.0.1 to 2.3.0
without explicitly disabling these features, all three caused observable regressions against
the project's Composition pipeline:

- `EnableBetaRealtimeCompositions`: aggressive re-render loop (~30 function invocations per
  minute per claim) starved the composite reconciler so MR creation took 100+ seconds, well
  past the ESO refresh-interval window.
- `EnableBetaClaimSSA`: SSA path enforced strict schema validation on rendered MRs and failed
  with "field not declared in schema" for fields permitted by v2.0's permissive reconciler.
- `EnableBetaCustomToManagedResourceConversion`: unused; caused no observable regression but
  introduced unnecessary risk.

These regressions were non-obvious from the release notes alone: they manifested as timeouts
and ESO failures, not as explicit error messages about beta features. The root cause was
discovered only after chainsaw run 26385090086 and related diagnose runs.

## Decision

When upgrading Crossplane to a new minor or major version, explicitly disable every beta
feature that the new version turns on by default, applying the same `--enable-X=false` flags
in both `terraform/management/helm.tf` and `tests/chainsaw/run.sh`, until each feature has
been individually validated against the project's Composition pipeline in a dedicated
upgrade iteration.

## Alternatives considered

- **Accept newly-default beta features and fix regressions.** Rejected: beta features are
  by definition not yet stable. Accepting them on upgrade conflates "Crossplane upgrade is
  green" with "these beta features work for our pipeline" — two separate questions. If a beta
  feature causes a regression, it becomes impossible to distinguish from a core regression
  without additional bisect work.

- **Maintain an explicit allowlist of enabled features.** Rejected as over-engineering for
  the current scale. The simpler rule — disable all newly-default betas — achieves the same
  safety property with less ongoing maintenance.

- **Pin to a Crossplane version that doesn't turn on betas.** Rejected: falling behind
  Crossplane's stable release track accumulates technical debt and defers the eventual upgrade
  pain. The upgrade must happen; the goal is to make it predictable.

## Consequences

**Easier:**
- Crossplane upgrades are predictable: the upgrade step and the beta-feature adoption step
  are separated. If the upgrade fails, the root cause is in the core; if a beta feature later
  fails, the root cause is in that feature.
- The chainsaw harness remains a valid proxy for production on every upgrade, because the
  feature flags are identical between kind and EKS.

**Harder:**
- Beta features that Upbound intends as the default path (e.g. SSA claims, realtime
  compositions) must be explicitly re-enabled in a follow-up iteration after validation.
  This adds one extra PR per beta feature adopted.

**Trade-off accepted:**
- We accept slower adoption of beta features in exchange for stable, bisectable upgrades.

## References

- [`../2026-05-25-76.md`](../2026-05-25-76.md) — source retrospective.
- [`./SKILL-SPEC-befefff7cb-crossplane-v2-upgrade-triage.md`](./SKILL-SPEC-befefff7cb-crossplane-v2-upgrade-triage.md) — related upgrade triage skill.
- PRs: #74 (the upgrade; contains the three beta-disable commits).

<!--
PROMOTION NOTE:
When this draft is adopted into docs/adr/ via the `adr` skill, preserve
the `**ID**: ADR-72b8d74ab3` line verbatim.
-->
