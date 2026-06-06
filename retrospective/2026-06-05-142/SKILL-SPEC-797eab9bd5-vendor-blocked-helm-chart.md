# Spec: `vendor-blocked-helm-chart`

- **ID**: SKILL-SPEC-797eab9bd5
- **Source retrospective**: ../2026-06-05-142.md

## Intent

When a public Helm chart repository starts returning 403 (or otherwise blocking)
the CI runner while serving fine elsewhere, vendor the pinned, digest-verified
chart tarball into the repo and install it from the local path so the build is
hermetic and CDN-independent. Grounded in the 2026-06-05 auto-005 session, where
`charts.crossplane.io/stable/index.yaml` returned 403 to the GitHub runner on
two consecutive management applies (200 from the sandbox), blocking the whole
phase-1 build until the chart was vendored.

## Trigger

- A CI helm/Terraform step fails with `failed to fetch <repo>/index.yaml :
  403 Forbidden` / `not a valid chart repository or cannot be reached`, AND the
  same URL returns 200 from the sandbox (`curl -sS -o /dev/null -w '%{http_code}'`).
- Two+ deterministic failures (rules out a transient).
- Negative trigger: a genuine one-off transient (single failure, succeeds on
  retry) — just re-dispatch; do not vendor.

## Inputs

- The failing chart repo URL + chart name + pinned version (from the helm
  release / `versions.env` / `variables.tf`).
- Sandbox network egress (to download the `.tgz` and read `index.yaml`).
- The repo's helm-install call sites (Terraform `helm_release`, shell `helm
  install`).

## Outputs

- A committed chart tarball under a `vendor/` directory.
- Edited install call sites that install from the local path (no `repository`,
  no `version`).
- A `vendor/README.md` documenting provenance (sha256), the reason, and the
  revert path.
- An open-issues entry recording the CDN-vs-runner finding.

## Workflow

1. **Confirm it is a runner-specific block, not a transient or migration.**
   `curl -sS -o /dev/null -w '%{http_code}' <repo>/index.yaml` from the sandbox.
   200 here + 403 on the runner (≥2 runs) ⇒ proceed. If the index no longer
   lists the version, it is a migration — chase the new source instead.
2. **Download the exact pinned tarball** from the sandbox:
   `curl -fsSL <repo>/<chart>-<version>.tgz -o <vendor>/<chart>-<version>.tgz`.
3. **Verify integrity** against the upstream index digest:
   `yq '.entries.<chart>[] | select(.version=="<version>") | .digest' <(curl -sS <repo>/index.yaml)`
   and compare to `sha256sum` of the download. Abort if they differ.
4. **Repoint every install site** to the local path; drop `repository` and
   `version` (the path/filename encodes the version). Keep the version variable
   driving the filename so multiple call sites stay in lockstep.
5. **Add `vendor/README.md`** with the sha256, the reason (link the OI), the
   bump procedure, and the revert path.
6. **Validate locally** what you can (`terraform validate`; for a chart dir,
   `helm template`), then dispatch the heavy CI to confirm green.
7. **Log an open-issues entry** so the next session knows the CDN restricts the
   runner and the install is intentionally vendored.

## Concrete examples

**Example 1 — Crossplane (this session).** `helm_release.crossplane` 403'd on
runs 27021786260 & 27022894643. Sandbox `curl` → 200. Downloaded
`crossplane-2.3.0.tgz` (14642 bytes); `sha256` `2ceff920…cd7f` matched the index
`digest`. Edited `terraform/management/helm.tf` to
`chart = "${path.module}/vendor/crossplane-${var.crossplane_version}.tgz"` (no
`repository`/`version`), and `tests/chainsaw/run.sh` to install from the shared
`../../terraform/management/vendor/crossplane-${CROSSPLANE_CHART_VERSION}.tgz`.
Wrote `vendor/README.md`; `terraform validate` passed; the next management apply
got past the crossplane install.

**Example 2 — a service chart on a flaky public repo.** A `helm_release.foo`
step fails `fetch https://charts.example.com/index.yaml : 403`. Sandbox curl
returns 200 and the index lists `foo-1.4.2.tgz`. Vendor
`vendor/foo-1.4.2.tgz`, verify its digest, set `chart =
"${path.module}/vendor/foo-1.4.2.tgz"`, document, and re-run.

## Anti-patterns

- Vendoring on a **single** failure (likely transient) — retry first.
- Skipping the **digest check** — a vendored chart with no provenance is a
  supply-chain liability worse than the CDN fetch it replaces.
- Hand-editing the version string but forgetting to vendor the matching `.tgz`
  (or vendoring it for one call site but not the other) — keep a unit test that
  asserts the versions match.
- Committing the tarball without a `README.md` revert path — the next session
  finds an unexplained binary and a dropped `repository` line.

## Acceptance criteria

- The CI helm step installs from the local path and no longer contacts the CDN.
- The vendored tarball's sha256 equals the upstream index `digest` (recorded).
- All install call sites for that chart use the same pinned version.
- `vendor/README.md` documents provenance + bump + revert; an OI entry exists.
- `terraform validate` (and a local `helm template` if a dir) passes.

## Files this skill creates / modifies

- `<module>/vendor/<chart>-<version>.tgz` — the digest-verified chart.
- `<module>/vendor/README.md` — provenance, reason, bump + revert procedure.
- Helm install call sites (`helm.tf`, `tests/**/run.sh`) — repointed to local.
- `docs/open-issues.md` — the CDN-vs-runner finding.
