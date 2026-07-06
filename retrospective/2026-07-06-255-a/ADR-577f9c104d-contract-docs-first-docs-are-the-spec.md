# ADR: Contract-docs-first: user-facing docs are the spec for public-surface features

- **ID**: ADR-577f9c104d
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-07-06
- **Source retrospective**: ../2026-07-06-255-a.md
- **PRs covered**: #255

## Context

Phase-5 identity (the Cognito→Keycloak→kubectl federation chain) was the
first feature built after the documentation site went live with its
status-banner gate (`status: stable|contract|draft` front matter enforced
by `mkdocs build --strict`, PR #247). PR #255's first commit (`2fd9d3a`)
was not code — it was the three user-facing pages (the kubectl-via-group
how-to, the UI SSO how-to, the identity-mapping reference), written as
`status: contract` and merged before any realm, Composition, or terraform
change existed. The pages named the exact observable contract the feature
had to meet: which Cognito group grants which Kubernetes verb, the
`kc:`-prefixed username/groups claims, the login flow a user walks.

The implementation then had a fixed target: the realm mappers, the
`IdentityProviderConfig` claims, and the `cognito-federation-live.sh`
oracle were all written to make the documented behavior true, and the
docs flip `contract → stable` only when clean-build evidence (rows 10/11
of SUBSTRATE-READINESS) records that the documented behavior happened on
a real build. This inverted the usual failure mode — docs written last,
describing what got built, drifting from day one — and it worked on its
first use: the contract test (`test_keycloak_cognito_idp_contract.sh`)
pins the docs' claims across the four delivery files, and the docs
needed zero rewrites after implementation.

## Decision

A feature that adds or changes a public platform surface is specified by
writing its user-facing documentation pages first, published with
`status: contract`, and those pages flip to `stable` only when the
recorded clean-build evidence lands.

Expanded: "public platform surface" means anything a platform user
touches — a login flow, a kubectl permission, an XR field, a URL. The
contract pages merge ahead of the implementation (they are reviewable
spec, and the docs site's banner marks them as commitments, not
descriptions). The implementation PR references the pages as its
acceptance criteria; the oracle that records the evidence asserts the
documented behavior, not the implementation's internals. The
`contract → stable` flip rides the same commit that records the run ID.

## Alternatives considered

- **Spec documents under `ai/specs/` (the pre-docs-site pattern).**
  Rejected for public surfaces: an internal spec and a user-facing doc
  covering the same surface inevitably diverge, and only one of them is
  published. The docs-site charter (`planning/scenario-corpus/`) already
  established docs-blindness as the quality metric — a separate spec
  produces a second source of truth the scenario authors never see.
- **Docs written after implementation, in the same PR.** The default
  before #255. Rejected because post-hoc docs describe what was built
  rather than constraining it — the #233-class realm defects happened in
  exactly that mode: behavior nobody had written down before building.
- **No status distinction (publish everything as stable).** Rejected:
  the banner is what makes docs-first honest. Without `contract`, a
  pre-implementation page is indistinguishable from a false claim about
  the live platform; with it, publishing ahead of evidence is safe.

## Consequences

- Easier: implementation PRs have a fixed, reviewable target; oracles
  have a behavioral definition to assert; the evidence flip
  (`contract → stable`) is mechanical and rides the run-ID commit, so
  "documented" and "proven" converge on the same event.
- Easier: the owner reviews the user experience before paying for the
  implementation.
- Harder: public-surface work now takes two ordered merges (docs, then
  implementation) and the sequencing matters; a contract page whose
  feature is later cut must be retracted, not left dangling.
- Accepted trade-off: `contract` pages describe behavior that does not
  exist yet on the live platform. The banner carries that honestly, but
  a reader who ignores banners can be misled between the two merges.

## References

- [`../2026-07-06-255-a.md`](../2026-07-06-255-a.md) — the source retrospective (addendum).
- [`../2026-07-06-255.md`](../2026-07-06-255.md) — the #255 session's retro (the pattern's first use, recorded first-person).
- `docs/site/how-to/` phase-5 pages + `docs/hooks/status_banner.py` — the
  mechanism (PR #247) and the first contract-mode use (PR #255, `2fd9d3a`).
- `tests/unit/test_keycloak_cognito_idp_contract.sh` — the contract
  pinned as a test across the four delivery files.
- Prior related draft: `../2026-07-05-252/ADR-fff8578975-documentation-first-class-deliverable-source-in-repo.md`
  (docs as first-class deliverable; this ADR adds the ordering + status
  contract for public surfaces).
- PRs the decision was made in: #255 (first use; #247 built the gate).
