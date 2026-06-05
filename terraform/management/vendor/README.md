# Vendored Helm charts

Charts committed here are installed by `helm.tf` from the **local path**, not
fetched from a remote repository at apply time.

## `crossplane-2.3.0.tgz`

**Why vendored:** `https://charts.crossplane.io/stable/index.yaml` returns
**403 Forbidden** to the GitHub Actions runner network (verified
deterministically across two `management apply-and-verify` runs on
2026-06-05: runs 27021786260 and 27022894643, both failing only on
`helm_release.crossplane`). The same URL returns **200** from other networks,
so the repo is up — the CDN is restricting the runner's egress. See
`docs/open-issues.md` OI-2026-06-05-2.

**Provenance / integrity:** downloaded from
`https://charts.crossplane.io/stable/crossplane-2.3.0.tgz` and verified
byte-for-byte against the upstream `index.yaml` digest:

```
sha256  2ceff920de33e849704935219669ab976722c06f77c4ec3b6692b24f2ae6cd7f
```

**Bumping the version:** set `var.crossplane_version`, download the matching
`crossplane-<version>.tgz` from the stable repo, verify its sha256 against the
index `digest`, drop it here, and update this README. `helm.tf` references
`vendor/crossplane-${var.crossplane_version}.tgz`.

**Revert path:** if the CDN restriction lifts, restore the
`repository`/`chart`/`version` form in `helm.tf` and delete this tarball.
