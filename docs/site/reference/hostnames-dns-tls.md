---
status: stable
---

# Hostnames, DNS, and TLS

The naming and certificate conventions behind every platform endpoint.
Nothing on this page requires a ticket: DNS records and TLS come
automatically from the conventions described here.

## The hostname scheme

The platform owns one DNS zone, written throughout these docs as
`<domain>` (it is an input to each deployment, never a fixed value).
Every cluster is assigned a **subdomain** of it, and every exposed
service gets a name one label deeper:

```
<service>.<subdomain>.<domain>
```

| Cluster | Subdomain | Example hostnames |
|---|---|---|
| Management (hub) | `management` | `argocd.management.<domain>` |
| Platform services | `platform` | `hello.platform.<domain>`, `grafana.platform.<domain>` |
| Workload clusters | one per cluster (e.g. `workload1`) | `<app>.workload1.<domain>` |

Applications learn their `<subdomain>` and `<domain>` from the
platform at deploy time (they are the only cluster facts a workload
receives), so application manifests stay cloud-agnostic and never
carry a literal domain.

## DNS records

Each spoke cluster runs ExternalDNS **scoped to its own subdomain**:
it watches the cluster's Ingress objects and creates Route53 records
for their rule hosts. Consequences you can rely on:

- Declaring an Ingress with `host: myapp.<subdomain>.<domain>` is
  sufficient — the record appears without any annotation.
- A cluster can only create records under its own subdomain; clusters
  cannot collide with (or take over) each other's names. Record
  ownership is tracked per cluster.

## TLS

- Every cluster is provisioned with a **DNS-validated wildcard ACM
  certificate** for `*.<subdomain>.<domain>`, created as part of
  cluster provisioning itself — a cluster never exists without its
  certificate.
- TLS **terminates at the cluster's ingress load balancer** using that
  certificate. Traffic behind it is plain HTTP to your service.
- Therefore an Ingress manifest carries **no `tls:` block** and the
  platform runs no in-cluster certificate machinery (no cert-manager,
  no ACME challenges, nothing to renew by hand).

The certificate is a single-level wildcard: it covers
`myapp.<subdomain>.<domain>` but not a two-label name like
`a.b.<subdomain>.<domain>`. Keep exposed hostnames one label deep.

## What this means for a scenario oracle

For an application exposed at `https://myapp.platform.<domain>`:

```bash
dig +short myapp.platform.<domain>        # resolves (Route53 record exists)
curl -sSf https://myapp.platform.<domain> # 200 over verified TLS
```

A failing certificate verification or NXDOMAIN is a platform defect,
not an expected state, once the application's Ingress is synced and
healthy.
