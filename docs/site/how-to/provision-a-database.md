---
status: stable
---

# Provision a database and connect an application to it

Your application needs a relational database. You declare one
Kubernetes object — an `XDatabase` composite resource — and the
platform provisions a managed Postgres instance and writes a
connection Secret into your namespace. No cloud console, no
credentials handling: the platform's own SSO component gets its
database exactly this way, and this page mirrors that committed,
build-verified example.

## Before you start

- A namespace on the **management cluster** (where composite resources
  are reconciled) and a Git path synced there — the same wiring as for
  [platform secrets](provision-a-platform-secret.md).
- Your workload can read Kubernetes Secrets in its own namespace.

## 1. Declare the database

```yaml
apiVersion: platform.k8-platform.io/v1alpha1
kind: XDatabase
metadata:
  name: myapp-db
  namespace: <your-namespace>
spec:
  databaseName: myapp        # required — the initial database inside the instance
  engine: postgres           # default; the only engine today
  size: small                # default; small|medium t-shirt sizing
  storageGB: 20              # default; 20-100
```

Full field constraints and defaults:
[Database (XDatabase) reference](../reference/xdatabase.md).

When delivering via GitOps next to the consuming workload, put the
XDatabase in an **earlier sync wave** than the consumer — database
creation takes minutes, and ordering lets provisioning overlap the
rest of the rollout:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "34"   # consumer runs in a later wave
```

## 2. Wait for it (this one is slow)

```bash
kubectl wait --for=condition=Ready \
  xdatabase/myapp-db -n <your-namespace> --timeout=900s
```

Expect **5–10 minutes**: managed database instances are genuinely slow
to create. A workload that starts early and crash-loops until the
Secret appears is normal and fine.

## 3. Read the connection details

A Secret named after the XR now exists in your namespace:

```bash
kubectl get secret myapp-db -n <your-namespace> \
  -o jsonpath='{.data.username}' | base64 -d
kubectl get xdatabase myapp-db -n <your-namespace> \
  -o jsonpath='{.status.endpoint}:{.status.port}'
```

Keys `username` and `password` carry the credentials; host and port
come from the XR's status.

## 4. Point your application at it

For a chart that follows the common `externalDatabase` convention:

```yaml
externalDatabase:
  existingSecret: myapp-db
  existingSecretUserKey: username
  existingSecretPasswordKey: password
  host: <status.endpoint>      # from the XR status
  port: 5432
  database: myapp
```

For a plain Deployment, mount the two keys as env vars with
`secretKeyRef` and pass host/port/database as config.

!!! warning "Known limit: your workload probably isn't where the Secret is"
    The connection Secret materializes in the XR's namespace **on the
    management cluster**, and tenant workloads run on spoke clusters.
    There is no self-service bridge yet (a registered platform gap —
    the [reference page](../reference/xdatabase.md) states it): today,
    connecting a spoke workload to an XDatabase requires the platform
    operator to plumb the credentials across, as the platform does for
    its own SSO database. Step 4 above works as written only for a
    workload colocated with the XR.

## Removing it

```bash
kubectl delete xdatabase myapp-db -n <your-namespace>
```

!!! warning "Deletion destroys the data"
    Deprovisioning removes the database instance and the connection
    Secret. There is no documented backup/restore posture today — treat
    delete as irreversible data loss.
