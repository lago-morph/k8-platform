---
status: stable
---

# Deploy an application via GitOps

Get a containerized application running on a platform cluster. There
is no deploy command and no console: you commit two things to Git — a
Helm chart and an Argo CD Application file — and the platform
reconciles the cluster to match. This is the same path the platform's
own built-in demo app uses, so every step below mirrors a committed,
working example (`platform-services/hello/` and
`argocd/apps/spoke/hello.yaml`).

## Before you start

- You can open pull requests against the platform repository, and the
  platform operator merges them (see
  [Onboard a tenant](onboard-a-tenant.md) for the honest state of
  tenant wiring).
- Your container image is pullable from the cluster (public registry,
  pinned tag).
- You know which cluster you're deploying to — its short name (e.g.
  `platform`) is your hostname subdomain and your Application-name
  prefix.

## 1. Add your chart

Create a Helm chart in the platform repository under
`platform-services/<your-app>/` with the usual shape:

```
platform-services/myapp/
  Chart.yaml
  values.yaml
  templates/deployment.yaml
  templates/service.yaml
  templates/ingress.yaml      # see the expose how-to
```

Two platform conventions in `values.yaml`:

```yaml
# Cluster facts — the ONLY platform values your chart receives.
# Committed values are placeholders; the platform overrides them
# per cluster at sync time. Never commit a real domain.
subdomain: platform
domain: PLACEHOLDER_DOMAIN

image:
  repository: hashicorp/http-echo   # your image
  tag: "1.0.0"                      # always a pinned tag
```

## 2. Add the Application file

Create `argocd/apps/spoke/<your-app>.yaml`. The platform pattern is an
ApplicationSet that targets every registered spoke cluster and injects
the cluster facts; copy it from the demo app and change the names and
path:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: myapp
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  syncPolicy:
    preserveResourcesOnDeletion: true
  generators:
    - clusters:
        selector:
          matchLabels:
            k8-platform.io/cluster-role: spoke
  template:
    metadata:
      name: '{{index .metadata.labels "k8-platform.io/short-name"}}-myapp'
      annotations:
        argocd.argoproj.io/sync-wave: "30"   # after ingress + DNS (wave 20)
    spec:
      project: platform-spoke
      source:
        repoURL: https://github.com/lago-morph/k8-platform.git
        targetRevision: main
        path: platform-services/myapp
        helm:
          valuesObject:
            domain: '{{index .metadata.annotations "k8-platform.io/domain"}}'
            subdomain: '{{index .metadata.annotations "k8-platform.io/subdomain"}}'
      destination:
        name: '{{.name}}'
        namespace: myapp
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
        retry:
          limit: 5
          backoff: {duration: 10s, factor: 2, maxDuration: 5m}
```

What the boundaries allow here is defined by the `platform-spoke`
project — see [Tenant boundaries](../reference/tenant-boundaries.md).
Your namespace is created for you (`CreateNamespace=true`). The
`repoURL` may be any repository on the project's exact allowlist —
deploying from your own repo instead of this one works once the
operator has allowlisted it (see
[Onboard a tenant](onboard-a-tenant.md)).

## 3. Commit and merge

Open the pull request; once merged to `main`, the platform's
app-of-apps picks the new Application up automatically — no further
action. Reconciliation is continuous: the sync starts within minutes
and retries with backoff if a dependency isn't ready yet.

## 4. Verify

Delivery health, from the management cluster:

```bash
kubectl get application platform-myapp -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}'
# expect: Synced/Healthy
```

Runtime health, on the target cluster:

```bash
kubectl -n myapp get pods
kubectl -n myapp rollout status deploy/myapp
```

See [Health and status surfaces](../reference/health-surfaces.md) for
everything these can tell you.

## What you can rely on

- **Git is the only write path.** Anything you change by hand on the
  cluster is reverted by self-heal within the reconcile interval.
- **Namespace and ordering are handled**: your namespace is created on
  sync, and the sync wave puts you after the ingress/DNS layer.
- **Deleting the Application file** (a commit) prunes the deployed
  resources.

!!! info "Reality check: one chart, every spoke"
    The pattern above deploys to **every** registered spoke cluster —
    today that is the platform services cluster; workload clusters
    join as the platform's fan-out phase lands. Per-cluster placement
    control is a later-phase feature; if you need it now, that is a
    finding worth filing.
