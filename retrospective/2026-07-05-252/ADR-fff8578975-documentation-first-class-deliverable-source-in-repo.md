# ADR: Documentation is a first-class deliverable with source in the platform repository

- **ID**: ADR-fff8578975
- **Status**: Draft (owner-ratified in-session 2026-07-05; not yet adopted to docs/decisions/)
- **Date**: 2026-07-05
- **Source retrospective**: ../2026-07-05-252.md
- **PRs covered**: #246 (the plan); #247/#249 (the concurrent docs-track session's first implementation waves)

## Context

The docs-blind scenario corpus (companion decision ADR-f77cbc34e0) makes
the published documentation the platform's *product contract*: scenarios
are authored from it alone, and a scenario that cannot be written is a
documentation bug. That gives documentation a falsifiable quality bar for
the first time, and forces two topology decisions: where the docs source
lives, and how docs for not-yet-shipped features are kept honest. The
owner floated a third repository (`k8s-platform-documentation`) for the
published site and asked for trade-off analysis; the deciding argument
was rot mechanics — the scenario corpus detects documentation rot *after*
it ships, while PR-coupling prevents it *before*, and only same-repo
source gets both layers.

## Decision

Author user-facing documentation as diataxis-structured source in this
repository published to a GitHub Pages site, with stability markers
gating what the scenario corpus may build on.

Concretely: source under `docs/site/` (tutorials / how-to / reference /
explanation), published via a Pages workflow; every page describes public
surfaces only and carries a status marker — `stable` (clean-build-verified
behavior; scenarios may mature to executable against it), `contract`
(agreed-but-unshipped; the docs double as the feature's spec — phase-5
identity pages are written this way *before* implementation), `draft`
(may change without notice). A page flips `contract → stable` only with
clean-build evidence, the repo's ordinary "done" bar. The initial scope
requirement is exactly "sufficient for scenario authoring"; the docs
quality metric is the corpus's blocked-on-docs count. Plan of record:
`planning/scenario-corpus/documentation-plan.md`.

## Alternatives considered

- **Separate `k8s-platform-documentation` repository.** Rejected for
  now: it adds a sync seam where drift lives, and the consumption
  boundary the scenario corpus needs is the published *site*, which
  same-repo source provides equally well. Kept as a named extraction
  path if repo visibility or publish cadence ever diverge.
- **Docs generated after implementation stabilizes.** Rejected — writing
  the user-facing page first is spec-first for the public surface (the
  same logic as red-first tests); the `contract` marker makes the
  before-implementation state honest instead of aspirational.
- **No stability markers.** Rejected — without them, docs written ahead
  of implementation would be indistinguishable from shipped behavior,
  and the scenario corpus would file false documentation bugs against
  pages that were never claims about the present.

## Consequences

- Easier: docs changes ride implementation PRs (rot resistance);
  phase-5's identity pages become its reviewable spec before the
  Composition work starts; the blog series' explanation quadrant has a
  stable home to reference.
- Harder / accepted: the Pages workflow file must route through the
  jentic bridge (the push credential's workflow-scope gap); docs review
  load lands on platform PRs; the "public surfaces only" rule needs
  reviewer vigilance until a lint exists (deliberately deferred —
  audit-before-enforce).
- Deferred by decision: PR-coupling enforcement (docs-diff-required
  lint), versioned docs per release, the separate docs repository.

## References

- [`../2026-07-05-252.md`](../2026-07-05-252.md) — the source retrospective (Phase 3).
- `planning/scenario-corpus/documentation-plan.md` — the plan of record (PR #246).
- [`./ADR-f77cbc34e0-scenario-corpus-docs-blind-separate-repo.md`](./ADR-f77cbc34e0-scenario-corpus-docs-blind-separate-repo.md) — the companion decision that makes docs the product contract.
- PRs #247/#249 — first implementation waves (docs-track session).
