---
status: stable
---

# Database (XDatabase)

The platform's database abstraction: one namespaced composite resource
provisions a managed relational database and publishes a single
connection Secret in your namespace. You say "I need a postgres
database"; the platform picks and operates the backend (AWS RDS today —
the spec deliberately carries no RDS-specific fields, so the backend
can change without touching consumers).

## Kind

| | |
|---|---|
| `apiVersion` | `platform.k8-platform.io/v1alpha1` |
| `kind` | `XDatabase` |
| Scope | Namespaced (apply in the consuming workload's namespace) |
| Reconciled on | the management cluster |

## Spec fields

| Field | Type | Default | Constraints | Meaning |
|---|---|---|---|---|
| `databaseName` | string | — (**required**) | `^[a-z][a-z0-9_]{0,62}$` | Name of the initial database created inside the instance |
| `engine` | string | `postgres` | enum: `postgres` (only engine today) | Database engine |
| `version` | string | backend default | `^[0-9]+(\.[0-9]+)?$` | Engine major version (e.g. `"15"`) |
| `size` | string | `small` | enum: `small`, `medium` | Abstract t-shirt size; the backend maps it to concrete capacity (`small` → `db.t4g.micro`, `medium` → `db.t4g.small`) |
| `storageGB` | integer | `20` | 20–100 | Allocated storage in GB |
| `region` | string | `us-east-1` | `^[a-z]{2}-[a-z]+-[0-9]$` | Backend region |

## Status fields

| Field | Meaning |
|---|---|
| `status.conditions` | `Synced` / `Ready` / `Responsive`; `Ready: True` = instance available and connection Secret written |
| `status.endpoint` | Connection host — feeds a chart's `externalDatabase.host` |
| `status.port` | Connection port (5432 for postgres) |
| `status.secretRef.name` / `.namespace` | The connection Secret (see below) |
| `status.ready` | Boolean mirror of the Ready condition for quick consumption |
| `status.securityGroupId` | The dedicated database security group (informational) |

## The connection Secret

The platform writes one Kubernetes Secret in the XR's namespace,
**named the same as the XR**:

| Key | Content |
|---|---|
| `username` | Database master username |
| `password` | Generated master password |
| `endpoint`, `port`, `attribute.*` | Additional provider-written connection details |

The intended consumption pattern (used by the platform's own SSO
database): point your chart's `existingSecret` at the Secret name, read
`username`/`password` from it, and take host/port from the XR's
`status.endpoint` / `status.port`.

!!! warning "Known limit: no cross-cluster consumption contract"
    The connection Secret exists **only in the XR's namespace on the
    management cluster** — and tenant workloads run on spoke clusters.
    Unlike the platform secret's deterministic-name contract, XDatabase
    publishes no mechanism for a spoke workload to consume its
    connection Secret; the platform's own consumer bridges the gap with
    operator-built plumbing the abstraction does not provide. This is a
    registered platform gap. Until it closes, consuming a database from
    a spoke workload requires the platform operator.

## Timing

Expect the first `Ready: True` **5–10 minutes** after apply — managed
database instances are slow to create. Workloads that start before the
Secret exists should crash-loop-and-retry (standard chart behavior);
when delivered via GitOps, order the XDatabase in an earlier sync wave
than its consumer.

## Deletion

Deleting the `XDatabase` deprovisions the backing database instance and
removes the connection Secret. Treat it as destroying the data: there
is no documented backup/restore posture today (a known platform gap —
see the scenario catalog's expected findings).
