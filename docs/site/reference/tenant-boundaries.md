---
status: stable
---

# Tenant boundaries

What a tenant's GitOps-delivered workload may and may not do, as
enforced by the platform's Argo CD projects. Everything a tenant
deploys is admitted through a **project**, and the project — not
trust — is the boundary.

## The two projects

| Project | Governs | Destination | Sources allowed |
|---|---|---|---|
| `k8-platform` | The platform's own control-plane resources (composite definitions, secret stores, policies) | The **management cluster only** | This repository only |
| `platform-spoke` | Everything deployed to spoke clusters: platform add-ons and tenant workloads | Spoke clusters only, by name (`platform-spoke`, `*-spoke`) — **never** the management cluster | An exact, enumerated list (see below) |

## Source repositories (platform-spoke)

Applications may only draw from **exactly pinned** repository URLs — no
wildcards, mechanically enforced. The current list: this repository
plus the upstream chart repositories of adopted platform components
(ingress-nginx, external-dns, prometheus-community, grafana, bitnami,
external-secrets).

Deploying from any other repository is **denied at admission**. Getting
a repository added is a platform change: a reviewed pull request
against the project definition, made by the platform operator.

## Resource kinds (platform-spoke)

**Namespaced resources** from these API groups are allowed in any
namespace on a spoke: core (`""`), `apps`, `networking.k8s.io`,
`rbac.authorization.k8s.io`, `policy`, `autoscaling`, `batch`,
`external-secrets.io`, `monitoring.coreos.com`.

**Cluster-scoped resources** are limited to an enumerated whitelist:
`Namespace`, `CustomResourceDefinition`, `ClusterRole`,
`ClusterRoleBinding`, `ValidatingWebhookConfiguration`,
`MutatingWebhookConfiguration`, `PriorityClass`, `IngressClass`,
`ClusterSecretStore`. Anything else cluster-scoped is denied — for
example a `StorageClass` (cluster-scoped, not on the list) is refused
at admission.

## What a denial looks like

Argo CD refuses the sync and the Application reports a message of the
form:

```
resource <group>:<Kind> is not permitted in project platform-spoke
```

The Application shows `SyncFailed`/degraded status; nothing partial is
applied for the offending resource. Denials are therefore observable
from the Application status alone. A disallowed **source repository**
is refused the same way — a project-permission error in the
Application status naming the offending repo (the exact message string
is not yet pinned here; the first adversary scenario run should
capture and contribute it).

## Backstops behind the project boundary

- A policy engine on each spoke watches for `cluster-admin`
  ClusterRoleBindings — **in audit mode**: it reports violations, it
  does not block them. Since `ClusterRoleBinding` itself is an
  admitted kind (charts legitimately ship them), a privilege-escalating
  binding is admitted first and only visible in audit reports after
  the fact. Treat this vector as review-guarded, not
  machine-enforced.
- The management cluster is unreachable as a destination for
  spoke-project applications by construction, so a tenant manifest can
  never address the control plane.

## Known limits of today's boundary

Stated plainly, because scenario authors will probe them:

- Namespaced-kind whitelisting is **per API group, not per namespace**:
  the project model does not fence tenant A's namespace from tenant B's
  manifests within the same project. Per-tenant projects are the
  natural hardening step and would be a platform change.
- **Secrets are not tenant-scoped either.** Platform secret names are
  deterministic (`k8-platform/<namespace>/<name>`) and the secret
  store is cluster-wide, so one tenant can commit an ExternalSecret
  that names another tenant's secret; nothing denies it today. This is
  a registered platform gap, and probing it is expected to *succeed* —
  file the finding accordingly.
- Kubernetes RBAC for humans (`kubectl` as a tenant) is not part of
  this boundary — human access lands with the platform's identity
  phase (see the identity pages when they publish as `contract`).
