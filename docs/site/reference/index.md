---
status: stable
---

# Reference

Information-oriented descriptions of the platform's public surfaces:
the exact fields, names, defaults, and guarantees that tasks and
automation assert against. Reference pages describe; they do not
instruct (that is what the [How-to guides](../how-to/index.md) are
for).

## Planned

- **Platform secret (XPlatformSecret)** — spec fields and defaults,
  the deterministic secret-naming contract, and the shape of generated
  secret material
- **Database (XDatabase)** — spec fields and the connection-secret
  keys an application consumes
- **Tenant boundaries** — what a tenant may and may not create, and
  what the platform's guardrails deny
- **Hostnames, DNS, and TLS** — the naming conventions for platform
  and application endpoints
- **Health and status surfaces** — what a tenant may read to answer
  "is my application healthy?"

Anything not yet linked here is not yet written.
