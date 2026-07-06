---
status: stable
---

# Health and status surfaces

Everything a tenant may read to answer "is my application healthy, and
where is it?" — the exact observables scenario oracles should assert
against. The task-oriented walkthrough is in the
[health how-to](../how-to/check-health-and-find-url.md).

Reading these surfaces requires kubeconfigs for the management and
spoke clusters, and **no documented way to obtain them exists** — a
registered platform defect (see the first named gap in
[Onboard a tenant](../how-to/onboard-a-tenant.md)), fixed for real by
the identity phase. For what the *whole platform* should look like
when healthy, see
[What a finished platform contains](finished-platform.md).

## 1. The Argo CD Application (delivery health)

Every deployed workload is an Argo CD `Application` object on the
management cluster (namespace `argocd`), named
`<cluster-short-name>-<app>` (e.g. `platform-hello`). Its two status
fields are the delivery truth:

```bash
kubectl get application <name> -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}'
```

| Field | Healthy value | Meaning |
|---|---|---|
| `status.sync.status` | `Synced` | The cluster matches what is committed in Git |
| `status.health.status` | `Healthy` | The workload's resources report ready (Deployments available, etc.) |

`OutOfSync` means Git and cluster differ (a rollout in progress, or a
change not yet reconciled); `Degraded` means resources are failing.
Sync error messages (including project-boundary denials) appear under
`status.conditions` and `status.operationState.message`.

The Argo CD web UI serves the same data at
`https://argocd.management.<domain>`. Today it is operator-access only
(admin credentials); tenant SSO logins arrive with the identity phase.

## 2. Kubernetes objects in your namespace (runtime health)

On the cluster your application runs on, standard kubectl against your
own namespace:

```bash
kubectl -n <your-namespace> get pods
kubectl -n <your-namespace> rollout status deploy/<name>
kubectl -n <your-namespace> get events --sort-by=.lastTimestamp | tail
kubectl -n <your-namespace> get ingress
```

The Ingress object is also where your application's URL lives — the
rule host is the published hostname (see
[Hostnames, DNS, and TLS](hostnames-dns-tls.md)).

## 3. The public endpoint (user-perceived health)

```bash
curl -sSf https://<host-from-your-ingress>
```

HTTP 200 over verified TLS is the platform's own definition of a
working exposure — its clean-build gate asserts exactly this against
the built-in demo application.

## 4. Composite resource conditions (infrastructure health)

Self-service infrastructure (platform secrets, databases) reports
standard conditions on the composite resource:

```bash
kubectl get xplatformsecret,xdatabase -n <your-namespace>
kubectl wait --for=condition=Ready xdatabase/<name> -n <ns> --timeout=600s
```

`Synced` (the platform accepted and is acting on it), `Ready` (the
backing resources exist and converged), `Responsive` (the composition
pipeline is running). Kind-specific status fields are on each kind's
reference page.

## Not yet: logs and metrics

A metrics/logging stack (Prometheus, Grafana, Loki) is deployed as
platform components, but the **tenant-facing** logs-and-metrics story
is blocked on a known storage gap and is deliberately undocumented
until it works. When it lands, it gets its own pages; until then,
`kubectl logs` in your namespace is the honest answer.
