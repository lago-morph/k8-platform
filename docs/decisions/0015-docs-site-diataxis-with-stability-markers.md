# 0015 — Documentation as an in-repo diataxis site with enforced stability markers

- **ID**: ADR-c5d8ad7b96
- **Status**: Accepted (owner-directed adoption 2026-07-06)
- **Date**: 2026-07-06 (drafted in the docs-track retrospective; adopted by owner direction)
- **Source retrospective**: [`../../retrospective/2026-07-06-256.md`](../../retrospective/2026-07-06-256.md)
- **PRs covered**: #247, #249, #254, #256
- **Mechanical enforcement**: `docs/hooks/status_banner.py` (renders each
  page's `status:` marker and logs a warning when it is missing/invalid)
  + `mkdocs build --strict` in `.github/workflows/docs-site.yml` (promotes
  that warning and any broken internal link to a build failure) +
  `tests/unit/test_root_file_allowlist.sh` (keeps the mkdocs config out of
  the frozen repo root)

## Context

The platform gained a standing requirement (owner-set 2026-07-05) that
its documentation be sufficient for a separate scenario-corpus repo to
author scenarios **without implementation visibility** — the corpus
sees only the published site. That makes the docs a first-class,
externally-consumed deliverable, not an internal afterthought, and
raises two design questions the session had to answer: where the docs
live and how their trustworthiness is signaled. Docs written before the
features finish are useful (they act as the contract the implementation
must meet, the same spec-first logic the platform already uses for
tests), but only if a reader can tell shipped behavior from aspiration.

## Decision

User-facing documentation lives in `docs/site/` as a mkdocs + material
diataxis site, PR-coupled to the code and published to GitHub Pages, with
every page carrying a machine-enforced `status: stable|contract|draft`
marker.

Concretely: source under `docs/site/` split tutorials / how-to /
reference / explanation; config at `docs/mkdocs.yml` (not repo root,
which a lint freezes); a `docs/hooks/status_banner.py` mkdocs hook that
renders each page's marker as a banner and logs a warning when it is
missing or invalid; `mkdocs build --strict` (run locally and as the CI
gate) promoting that warning — and any broken internal link — to a build
failure; tool versions pinned in `versions.env`; publish on merge to
`main` via a workflow written through the jentic bridge (the git
credential lacks `workflow` scope). A page flips `contract → stable`
only on clean-build evidence — the same "done" bar as everything else in
the repo.

## Alternatives considered

- **A separate documentation repository.** Rejected for now: it
  decouples docs from the code they describe, breaking the PR-coupling
  that keeps them honest. Retained as a named extraction path if publish
  cadence or repo visibility ever diverge.
- **Markers as convention only (no enforcement).** Rejected: an
  unmarked or mislabeled page is exactly the silent lie the scenario
  corpus would build on. The `--strict` hook makes the convention
  impossible to forget — the session verified the gate red-then-green
  before trusting it.
- **Config at repo root (mkdocs default).** Rejected mid-session when
  `test_root_file_allowlist.sh` refused it; the root is deliberately
  frozen. Config moved under `docs/` with rebased paths rather than
  weakening the lint.

## Consequences

- **Easier:** the published site is the single external contract; the
  marker system lets docs lead implementation without misleading
  readers; broken links and unmarked pages cannot merge; a rebuild
  reproduces the site deterministically.
- **Harder / accepted:** workflow-file edits must route through jentic
  (extra step, documented); the non-default config location is a small
  surprise for contributors (mitigated by a header comment); every page
  carries the marker-maintenance obligation, enforced but non-zero.
- **New standing gate:** `mkdocs build --strict` becomes a required
  light check on docs PRs; the publish job is main-only.

## References

- [`../../retrospective/2026-07-06-256.md`](../../retrospective/2026-07-06-256.md) — the source retrospective (Phases 1–3).
- [`../../retrospective/2026-07-06-256/SKILL-SPEC-81defdbfbe-docs-blindness-l1-review.md`](../../retrospective/2026-07-06-256/SKILL-SPEC-81defdbfbe-docs-blindness-l1-review.md) — the method that validates sufficiency of docs built this way.
- `planning/scenario-corpus/documentation-plan.md` — the owner-set plan this implements.
- PRs: #247 (skeleton + gate), #249 (exemplar), #254 (now wave), #256 (readiness fixes + new pages).
