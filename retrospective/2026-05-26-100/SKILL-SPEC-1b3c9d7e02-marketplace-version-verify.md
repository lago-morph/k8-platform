# Spec: `marketplace-version-verify`

- **ID**: SKILL-SPEC-1b3c9d7e02
- **Source retrospective**: ../2026-05-26-100.md

## Intent

Software package marketplaces (Upbound Marketplace, Helm Hub, OCI registries, package indexes) sometimes list versions that don't actually exist on the upstream source. The marketplace may have indexing lag, may surface beta or planned releases, or may simply be wrong. When the agent pins such a version, the next CI run or apply that fetches the package 404s, and the diagnosis trail is long because the agent's "but the marketplace said it exists" assumption is hard to question without direct verification. In session 2026-05-26, PR #98 pinned `provider-aws-secretsmanager v2.5.4` based on the Upbound Marketplace listing; an adversarial reviewer ran `WebFetch` on the upstream GitHub tag URL and found no such tag exists (latest is `v2.5.0`). Without that catch, the next `terraform apply` and the next `chainsaw.yml` dispatch would have failed at the package-fetch step. This skill makes verification mechanical and cheap.

## Trigger

Direct triggers:
- "Verify this version exists upstream"
- "Check the package tag before pinning"

Proactive triggers (mandatory):
- About to write a version pin in `*.tfvars`, `*.env`, `*.yaml`, `Chart.yaml`, `Cargo.toml`, `package.json`, `go.mod`, or any other manifest that pins a package version.
- About to dispatch a workflow that fetches a package at a pinned tag.

Negative triggers:
- The version pin is being copy-pasted from a known-good source within the same repository (e.g., from `versions.env` into a script that consumes the same value). The source has presumably already been verified.

## Inputs

- A package identity: the registry (e.g., Upbound Marketplace, ghcr.io, OCI repo), the package name, and the candidate version tag.
- An upstream source-of-truth URL for the package. For most Crossplane/Kubernetes packages: the GitHub releases page of the source repo. For Helm charts: the `helm show chart` output or the chart's index.yaml. For OCI images: the registry's manifest endpoint.

## Outputs

- A pass/fail signal: does the candidate version tag exist on the upstream source?
- If pass: the canonical URL of the verified tag, recorded inline in the commit message or PR body that introduces the pin.
- If fail: the actual nearest tags (one version higher, one lower) so the user can pick the right one.

## Workflow

1. **Identify the upstream source-of-truth URL.** For example:
   - Crossplane provider package `xpkg.upbound.io/upbound/provider-aws-secretsmanager:vX.Y.Z` → check `https://github.com/crossplane-contrib/provider-upjet-aws/tree/vX.Y.Z`.
   - Helm chart pinned to `version: X.Y.Z` in a `Chart.yaml` → check `https://artifacthub.io/api/v1/packages/helm/<repo>/<chart>` or run `helm show chart <repo>/<chart> --version X.Y.Z`.
   - OCI image `registry.example.com/foo:X.Y.Z` → check `registry.example.com/v2/foo/manifests/X.Y.Z` returns 200.

2. **Fetch the URL.** Use `WebFetch` (or `curl -fsSL -I` if running locally). Look for a 200 response. A 404 means the tag doesn't exist; a 200 confirms it does.

3. **If 200**: record the verification inline. The commit message or PR body that introduces the pin should include the verified URL.

4. **If 404**: fetch the list of available tags and recommend the nearest higher and lower versions. For GitHub-sourced packages, `https://github.com/<owner>/<repo>/tags` lists them; for Helm charts, `helm search repo --versions <chart>` does the equivalent.

5. **Do not pin until verified.** A pin that hasn't passed verification is a latent bug; the cost of preventing it is one network call.

## Concrete examples

### Example 1: PR #98 should have run this before pinning (session 2026-05-26)

```
Candidate pin: provider-aws-secretsmanager v2.5.4
Upbound Marketplace listing: present (https://marketplace.upbound.io/providers/upbound/provider-aws-secretsmanager → "Latest: v2.5.4")
Verification URL: https://github.com/crossplane-contrib/provider-upjet-aws/tree/v2.5.4
Result: 404
Available tags via https://github.com/crossplane-contrib/provider-upjet-aws/tags: v2.5.0 (latest), v2.4.0, v2.3.0, ...
Recommendation: pin to v2.5.0 instead.
```

The check fits on one screen. The fix would have been: change the candidate from v2.5.4 to v2.5.0 BEFORE opening PR #98. Net cost saved: PR #100 entirely, plus the chainsaw-verify back-and-forth on the rebased branch.

### Example 2: Verifying a Helm chart pin

```
Candidate pin: external-secrets version 0.10.4
Upstream: helm repo at https://charts.external-secrets.io
Verification: `helm show chart external-secrets/external-secrets --version 0.10.4`
Expected: prints the Chart.yaml; if 0.10.4 doesn't exist, returns "no chart version found"
Result on 2026-05-26: 0.10.4 exists. Pin is verified.
```

## Anti-patterns

- **Trusting only the marketplace UI.** Marketplaces can be ahead of the upstream source (planned releases not yet tagged), behind (indexing lag), or wrong (manual data entry errors). The upstream source is the only authoritative endpoint.
- **Skipping verification because "we just bumped this last week."** Even within a single sprint, version-tag landscape can change. A re-verify is one network call.
- **Verifying only the *latest* tag and assuming intermediate tags exist.** If the registry shows `v1.0, v1.1, v1.3`, do NOT assume `v1.2` exists. Always verify the specific tag you're pinning to.
- **Burying the verification in commit-message-only.** Also include the verified URL in the PR body so reviewers can see the evidence without `git log`.
- **Verifying via marketplace search.** A marketplace's "exact match" search may still surface synthetic or planned releases. The upstream source URL is the only place that 404 means doesn't-exist.

## Acceptance criteria

1. Every version-pin commit / PR carries an inline citation of the upstream URL that returned 200 for the pinned tag.
2. The verification step is performed BEFORE the pin is written to disk, not after.
3. If the verification fails, the PR is amended (not just commented on); the bad pin never lands.

## Files this skill creates / modifies

- No new files. The skill modifies the agent's behavior at version-pin time and adds a one-line verification citation to commit messages / PR bodies.
