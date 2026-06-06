# ADR: Vendor the Crossplane Helm chart instead of fetching from charts.crossplane.io at apply time

- **ID**: ADR-ff523c98c8
- **Status**: Draft (not yet adopted to docs/decisions/)
- **Date**: 2026-06-05
- **Source retrospective**: ../2026-06-05-142.md
- **PRs covered**: #142

## Context

Building phase 1 (management) on a fresh AWS account, `helm_release.crossplane`
failed on two consecutive `apply-and-verify` runs (27021786260, 27022894643)
with:

```
could not download chart: looks like "https://charts.crossplane.io/stable" is
not a valid chart repository or cannot be reached: failed to fetch
https://charts.crossplane.io/stable/index.yaml : 403 Forbidden
```

The same URL returned **HTTP 200 from the sandbox** (and the index still listed
`crossplane-2.3.0.tgz`), and the 2026-05-29 build used the identical URL fine —
so the repo was up and the chart was not migrated/yanked. The CDN fronting
`charts.crossplane.io` is returning 403 to the GitHub-hosted runner egress
specifically. No OCI mirror exists (`oci://xpkg.crossplane.io/...` and
`oci://ghcr.io/crossplane/...` both 404). `tests/chainsaw/run.sh` installs
Crossplane from the same repo, so it was exposed to the same failure.

## Decision

Install Crossplane from a digest-verified chart tarball vendored in the repo
(`terraform/management/vendor/crossplane-<version>.tgz`), not from
`charts.crossplane.io` at apply time, because that CDN returns 403 to the
GitHub Actions runner. `helm.tf` and `tests/chainsaw/run.sh` both install from
the local path; `var.crossplane_version` drives the filename so the two stay
version-locked.

## Alternatives considered

- **Retry the fetch.** Rejected — two deterministic failures 4 min apart plus a
  200 from the sandbox rule out a transient; retrying burns ~16-min apply cycles.
- **Switch to an OCI chart reference.** Rejected — Crossplane does not publish
  the Helm chart via OCI under `xpkg.crossplane.io` or `ghcr.io` (both 404).
- **Mirror the chart to a private registry (S3/ECR/GHCR).** Rejected for now as
  heavier than vendoring a 15 KB tarball; revisit if many charts need vendoring.
- **Pin/whitelist the runner egress.** Not controllable from this repo (the
  block is on the upstream CDN side).

## Consequences

- **Easier:** the apply is hermetic and independent of an external CDN the team
  does not control; arguably more supply-chain-secure (the tarball sha256 is
  verified against the upstream index digest and committed).
- **Harder:** version bumps now require vendoring the matching `.tgz` (download +
  digest-verify + commit) rather than editing a version string; a unit test
  asserts the chainsaw and management versions match so the two vendored
  references can't drift silently.
- **Accepted trade-off:** a binary artifact lives in git. It is small (~15 KB),
  pinned, and digest-documented in `vendor/README.md` with a revert path for
  when/if the CDN restriction lifts.

## References

- [`../2026-06-05-142.md`](../2026-06-05-142.md) — the source retrospective.
- [`./AGENTS-MD-a820699f52-vendor-helm-chart-when-cdn-403s-runner.md`](./AGENTS-MD-a820699f52-vendor-helm-chart-when-cdn-403s-runner.md) — the companion agents-file rule.
- [`./SKILL-SPEC-797eab9bd5-vendor-blocked-helm-chart.md`](./SKILL-SPEC-797eab9bd5-vendor-blocked-helm-chart.md) — the procedure skill.
- `docs/open-issues.md` OI-2026-06-05-2; PR #142 commit `99cc974` (management) + `bc95384` (chainsaw).
