# ADR: Crossplane upgrade strategy: fix beta regressions before provider bumps

- **ID**: ADR-88c309e275
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-76.md
- **PRs covered**: #74

## Context

A Crossplane major/minor upgrade involves two independently-versioned components: the core
chart (e.g. 2.0.1 → 2.3.0) and the provider packages (e.g. provider-family-aws v1.12.0 →
vX.Y). Each component class introduces a distinct regression class:

- **Core chart upgrade**: newly-default beta features, strict SSA schema validation,
  changed RBAC enforcement, flag renames.
- **Provider package bump**: CRD schema changes, reconciler behavior changes,
  provider-to-core protocol changes (e.g. provider's internal queue behavior under
  the new composite reconciler model).

During the 2.0.1 → 2.3.0 upgrade (PR #74), provider-family-aws was kept at v1.12.0 while
the core was upgraded. This was intentional: it isolated the core regression classes (Bugs 1,
2, the flag name bug) and made them diagnosable independently. Bug 3 (provider v1.12.0 slow
under 2.3.0 core) was then identified as a residual provider-class regression, cleanly
separable from the core-class regressions already fixed.

Had both the core chart and the provider been bumped simultaneously, a single chainsaw
failure would have had two possible causes and would have required an additional bisect step.

## Decision

When upgrading Crossplane, address regression classes in strict order: (1) disable
newly-default beta features and fix any SSA schema or RBAC regressions with the provider
at its current version; (2) only after chainsaw is green on the new core with the current
provider, bump the provider packages in a separate commit (or separate PR) and re-run
chainsaw to confirm provider compatibility.

## Alternatives considered

- **Bump core and providers simultaneously.** Rejected: a single chainsaw failure has two
  independent causes (core regression or provider regression) and requires a bisect step to
  isolate. The two-step approach costs one extra chainsaw dispatch but eliminates the bisect.

- **Bump providers first, then core.** Rejected: provider packages are versioned against
  the Crossplane core protocol. Bumping providers to a version that expects Crossplane 2.3
  behavior while running 2.0.1 core may introduce a different set of regressions, obscuring
  the core-upgrade signal.

## Consequences

**Easier:**
- Each chainsaw failure has a single probable cause (either core behavior changed, or provider
  behavior changed — not both).
- The upgrade can be stopped and rolled back at a clean boundary (after core is green,
  before providers are bumped).

**Harder:**
- The provider bump becomes a second PR (or second commit batch), adding one round of
  chainsaw dispatch + wait to the total upgrade time.

**Trade-off accepted:**
- We accept one extra chainsaw run (≈10 min) in exchange for clean failure attribution and
  a rollback boundary between the two change classes.

## References

- [`../2026-05-25-76.md`](../2026-05-25-76.md) — source retrospective.
- [`./SKILL-SPEC-befefff7cb-crossplane-v2-upgrade-triage.md`](./SKILL-SPEC-befefff7cb-crossplane-v2-upgrade-triage.md) — upgrade triage skill (step 2: bump version in isolation first).
- [`./ADR-72b8d74ab3-disable-crossplane-beta-features-on-upgrade.md`](./ADR-72b8d74ab3-disable-crossplane-beta-features-on-upgrade.md) — related decision on beta features.
- PRs: #74 (core upgrade with provider held at v1.12.0).

<!--
PROMOTION NOTE:
When this draft is adopted into docs/adr/ via the `adr` skill, preserve
the `**ID**: ADR-88c309e275` line verbatim.
-->
