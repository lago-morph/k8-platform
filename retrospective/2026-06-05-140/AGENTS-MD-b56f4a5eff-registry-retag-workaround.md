# agent instruction

**Bypass a blocked image registry by retagging from an alternate registry.** When a local tool fails to pull a required image because one registry is blocked or returns 5xx (e.g. ghcr.io 503), check whether the same image is published on an alternate registry (e.g. docker.io), pull it there, and `docker tag` it to the blocked reference so the local daemon finds it cached. Verify per AGENTS 6.12 before declaring the tool unusable.

*Grounded in: 2026-06-05 phase-3 — `crossplane render` failed pulling `xpkg.crossplane.io/crossplane/crossplane:stable` (ghcr 503); pulled `crossplane/crossplane:stable` from docker.io and retagged.*

# justification

`crossplane render` — the author-time SPEC-S9 gate — was dead in the sandbox because the core image's registry (ghcr.io) returned a hard 503, while the function images (xpkg.upbound.io) pulled fine. Without the retag workaround the entire local validation loop is unavailable and every Composition change must round-trip through CI (minutes per iteration). The workaround is two commands (`docker pull` from docker.io + `docker tag` to the blocked ref) and unblocked the whole session's local iteration; the asymmetry between a two-command fix and "no local render at all" is large.
