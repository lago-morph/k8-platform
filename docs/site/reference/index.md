---
status: stable
---

# Reference

Information-oriented descriptions of the platform's public surfaces:
the exact fields, names, defaults, and guarantees that tasks and
automation assert against. Reference pages describe; they do not
instruct (that is what the [How-to guides](../how-to/index.md) are
for).

## Pages

- [Platform secret (XPlatformSecret)](xplatformsecret.md) — spec
  fields and defaults, the deterministic secret-naming contract, and
  the shape of generated secret material
- [Database (XDatabase)](xdatabase.md) — spec fields and the
  connection-secret keys an application consumes
- [Tenant boundaries](tenant-boundaries.md) — what a tenant may and
  may not deploy, and what a denial looks like
- [Hostnames, DNS, and TLS](hostnames-dns-tls.md) — the naming and
  certificate conventions for platform and application endpoints
- [Health and status surfaces](health-surfaces.md) — what a tenant may
  read to answer "is my application healthy?"
- [Identity mapping](identity-mapping.md) — how a directory account
  becomes a Kubernetes identity: claims, the `kc:` prefix, the
  group → access matrix, and revocation bounds
- [What a finished platform contains](finished-platform.md) — the
  expected-state inventory that makes "everything is green" meaningful

Anything not linked here is not yet written.
