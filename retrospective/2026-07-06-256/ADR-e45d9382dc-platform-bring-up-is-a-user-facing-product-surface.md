# ADR: Platform bring-up is a user-facing product surface

- **ID**: ADR-e45d9382dc
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-07-06
- **Source retrospective**: ../2026-07-06-256.md
- **PRs covered**: #256

## Context

When the docs-blindness review judged scenario 1 ("rebuild the entire
platform from nothing on a fresh account") NOT WRITABLE, I initially
accepted that as correct-by-design: I had drawn the docs' "public
surfaces" line at the surfaces of an *already-running* platform, so
bring-up (Terraform, CI dispatch, account bootstrap) fell outside the
audience and needed no page. The owner rejected the framing: "the owner
of the platform is a user," and the surface that *creates* the platform
is product, not development scaffolding. The error was looking at the
system as its implementer — for whom bring-up is CI/agent tooling —
rather than as a user who wants to stand the platform up and do real
work. The repo's own README already opens with a `terraform apply`
Getting Started, and the documentation plan already names
"owner-as-operator" in its audience; the session had silently narrowed
both. The consequence the owner named is the sharp one: if the only way
to instantiate the platform is to ask an AI partner, then
rebuild-from-nothing is a property of the development environment, not
of the product.

## Decision

The platform owner is a user and bring-up is a documented product
operation, so the public-surface documentation audience includes the
owner-as-operator and the rebuild-from-nothing procedure is a
first-class docs page — authored from committed sources, not excluded as
scaffolding.

The page (`docs/site/how-to/build-the-platform-from-nothing.md`) is
marked `contract` until a human executes it as written on a fresh
account, because to date bring-up has only ever run through the CI/agent
apparatus; that human-path clean-build run is the evidence that flips it
`stable` and closes OI-2026-07-06-4. Where the human path diverges from
what the machinery does (auto-derived state backend and credentials),
the page states the divergence honestly rather than hiding it. Its
companion is a `reference/finished-platform.md` inventory so "the build
is done" is verifiable against an expected state rather than a vacuous
"everything is green."

## Alternatives considered

- **Keep bring-up out of scope (the implementer's line).** Rejected on
  the owner ruling: it confuses development scaffolding with the product
  and leaves the platform's most fundamental owner operation
  undocumented.
- **Document bring-up only as the CI dispatch flow.** Rejected: that
  documents the scaffolding, not the product; a human owner cannot run
  it, and it hard-codes the dependency on the agent apparatus the ruling
  is trying to remove.
- **Mark the page `stable` immediately from committed sources.**
  Rejected: no human has executed the path end-to-end, so `stable`
  (clean-build-verified) would be a false claim; `contract` is the
  honest marker, with a defined flip condition.

## Consequences

- **Easier:** the platform's rebuild-from-nothing claim becomes a
  product property a user can exercise, not an agent capability; scenario
  1 re-enters the corpus as writable-in-principle with a page to build
  on; the finished-platform inventory repairs scenario 2's "verify a
  build blind" oracle.
- **Harder / accepted:** writing the page exposed how much of bring-up
  is currently CI-shaped rather than owner-shaped (OI-2026-07-06-4); each
  such gap is now a tracked finding rather than an invisible assumption.
  The `contract` marker carries an obligation to actually run the human
  path and flip it.
- **General principle recorded:** document from the standpoint of
  someone using the system to achieve real work, not from the standpoint
  of the implementer; the scaffolding erected to *develop* a capability
  is not the shape of the capability itself.

## References

- [`../2026-07-06-256.md`](../2026-07-06-256.md) — the source retrospective (Phases 4–5).
- `docs/site/how-to/build-the-platform-from-nothing.md` — the page this ADR justifies.
- `docs/site/reference/finished-platform.md` — the companion inventory.
- `docs/open-issues.md` → OI-2026-07-06-4 — the "no human-executable bring-up verified" gap and its close condition.
- PR #256.
