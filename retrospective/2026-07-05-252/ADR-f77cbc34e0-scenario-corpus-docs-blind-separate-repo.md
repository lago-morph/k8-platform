# ADR: Scenario corpus is docs-blind and lives in a separate repository

- **ID**: ADR-f77cbc34e0
- **Status**: Draft (owner-ratified in-session 2026-07-05; not yet adopted to docs/decisions/)
- **Date**: 2026-07-05
- **Source retrospective**: ../2026-07-05-252.md
- **PRs covered**: #246 (the charter package)

## Context

The platform needed product-level acceptance testing: scenarios exercising
it the way its real users would (owners maintaining the core, tenants
deploying applications, an author writing the blog series, adversaries
probing boundaries), maturing from one-line bullets to deterministic
gating tests. The owner's stated purpose is to surface the *difference*
between the abstract architecture and the product as actually usable —
defects in requirements, not just implementation. An early same-repo
design (a `scenarios/` directory with a co-modification lint) was
discussed and discarded when the owner added the decisive constraint:
scenarios must be developed **from the published documentation alone**.
An informational boundary cannot be enforced by a lint inside the same
checkout — an agent reads whatever files it can see — so physical
separation became load-bearing rather than stylistic.

## Decision

Author platform acceptance scenarios in a separate `k8s-platform-scenarios`
repository whose only permitted inputs are the published documentation
site and the corpus charter, never the platform repository's source.

Consequently every scenario tests four artifacts at once, and findings
must name which one failed: the documentation (scenario cannot be
written, or documented steps don't match reality), the implementation
(documented steps produce the wrong outcome), the requirements (works as
documented but the architecture intended otherwise), or the scenario's
own assumption. A scenario blocked on missing documentation is filed as
a documentation bug, never worked around by reading source. The founding
charter (written to be that repository's first commit) lives at
`planning/scenario-corpus/charter.md` with the seed backlog
(`scenario-brainstorm.md`, 39 scenarios in five capability-ranked waves)
beside it.

## Alternatives considered

- **Same repository, `scenarios/` directory + mechanical fence** (a lint
  failing any PR touching both `scenarios/**` and implementation paths).
  Rejected once docs-blindness became the contract: the fence stops
  co-modification but cannot stop a scenario-authoring agent from
  *reading* implementation source, which silently destroys the corpus's
  diagnostic value. Was the recommended option before that constraint.
- **Scenarios that read implementation with a discipline rule.**
  Rejected — "don't look" rules without mechanical or physical
  enforcement are exactly the class this repo's LESSONS process retired.
- **No separate corpus; rely on the existing oracle/live-check layers.**
  Rejected — those verify the platform assembled itself, not that its
  documented product surface is usable by its roles; requirements-level
  defects (e.g. "rotation is out of scope" colliding with "an owner
  rotates a secret") are invisible to them.

## Consequences

- Easier: the blindness boundary is trivially auditable (the scenario
  repo's sessions simply never get the platform repo); the
  blocked-on-docs count becomes a real documentation quality metric;
  scenario authoring parallelizes freely against platform work.
- Harder / accepted: the harness (bounded-poll libs, relay access
  patterns) cannot be imported from the platform repo and must be
  re-established behind the public surface; version pinning between
  scenario-set and platform is by explicit reference, not a shared SHA
  — accepted because the corpus targets the *published product*, not
  HEAD.
- The author role gets one carve-out: blog demos may *show* concepts
  from published docs/posts, but every demo step still *executes*
  through public surfaces.

## References

- [`../2026-07-05-252.md`](../2026-07-05-252.md) — the source retrospective (Phase 3).
- `planning/scenario-corpus/charter.md` — the founding charter (PR #246, merge `fb4be06`).
- `planning/scenario-corpus/scenario-brainstorm.md` — the seed backlog.
- [`./ADR-fff8578975-documentation-first-class-deliverable-source-in-repo.md`](./ADR-fff8578975-documentation-first-class-deliverable-source-in-repo.md) — the companion decision this one depends on.
