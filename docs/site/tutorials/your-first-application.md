---
status: stable
---

# Your first application on the platform

The golden path, end to end: take a tiny web application from nothing
to a public `https://` URL on the platform, and know how to prove it's
healthy. Along the way you'll meet the three ideas everything else here
builds on — **Git is the only write path**, **the platform injects the
only cluster facts you need**, and **DNS + TLS are already handled**.

You will build exactly what the platform's own demo app is: a tiny
HTTP responder, deployed by committing two things to Git. Expect the
whole exercise to be mostly waiting on two pull requests.

## What you need

- Pull-request access to the platform repository (your platform
  operator sets this up — the [onboarding guide](../how-to/onboard-a-tenant.md)
  is the honest description of that step).
- `kubectl` read access to the management cluster, and to the platform
  services cluster if you want to poke at runtime state.
- The platform's domain, `<domain>` below — ask your operator, or read
  it off any existing platform URL.

## Step 1 — a chart for a tiny app

In the platform repository, create `platform-services/hi/` with four
files.

`Chart.yaml`:

```yaml
apiVersion: v2
name: hi
version: 0.1.0
```

`values.yaml` — note the two placeholder lines; they are the platform's
convention for "filled in per cluster at deploy time":

```yaml
subdomain: platform
domain: PLACEHOLDER_DOMAIN

message: "hi from my first platform app"
```

`templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hi
spec:
  replicas: 2
  selector:
    matchLabels: {app: hi}
  template:
    metadata:
      labels: {app: hi}
    spec:
      containers:
        - name: hi
          image: hashicorp/http-echo:1.0.0
          args: ["-text={{ .Values.message }}"]
          ports: [{containerPort: 5678}]
```

`templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hi
spec:
  selector: {app: hi}
  ports: [{port: 80, targetPort: 5678}]
```

`templates/ingress.yaml` — the whole "expose publicly with TLS" story
is these few lines; notice there is no `tls:` block and no DNS
annotation, because certificates and DNS records are platform
machinery:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hi
spec:
  ingressClassName: nginx
  rules:
    - host: "hi.{{ .Values.subdomain }}.{{ .Values.domain }}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: hi, port: {number: 80}}
```

## Step 2 — tell the platform to run it

Create `argocd/apps/spoke/hi.yaml`. This is the platform's deployment
unit: it targets every registered spoke cluster and injects the real
`domain`/`subdomain` into your values:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hi
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
      name: '{{index .metadata.labels "k8-platform.io/short-name"}}-hi'
      annotations:
        argocd.argoproj.io/sync-wave: "30"
    spec:
      project: platform-spoke
      source:
        repoURL: https://github.com/lago-morph/k8-platform.git
        targetRevision: main
        path: platform-services/hi
        helm:
          valuesObject:
            domain: '{{index .metadata.annotations "k8-platform.io/domain"}}'
            subdomain: '{{index .metadata.annotations "k8-platform.io/subdomain"}}'
      destination:
        name: '{{.name}}'
        namespace: hi
      syncPolicy:
        automated: {prune: true, selfHeal: true}
        syncOptions: [CreateNamespace=true, ServerSideApply=true]
        retry:
          limit: 5
          backoff: {duration: 10s, factor: 2, maxDuration: 5m}
```

Open the PR with both changes; get it merged.

## Step 3 — watch the platform do the rest

You issued no deploy command, and you won't. Within a few minutes of
the merge, on the management cluster:

```bash
kubectl get application platform-hi -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}'
```

Watch it move to `Synced/Healthy`. Your namespace `hi` was created for
you; the pods run on the platform services cluster:

```bash
kubectl -n hi get pods    # against the platform services cluster
```

## Step 4 — visit your URL

```bash
curl -sSf https://hi.platform.<domain>
# → hi from my first platform app
```

A real DNS record and a valid public certificate, and you asked for
neither: the Ingress host line produced the record, and the cluster's
wildcard certificate covers the name. (First-time DNS can lag a minute
or two — if `curl` fails, `dig +short hi.platform.<domain>` first.)

## Step 5 — change it, then undo the change

Edit the message in `values.yaml`, merge, and watch the same loop
roll it out. Then:

```bash
git revert HEAD   # via a PR, like everything
```

— and the platform converges back. That symmetry is the operating
model: there is no rollback command because there is no deploy
command.

## Where to go next

- Give it a secret: [Provision a platform secret](../how-to/provision-a-platform-secret.md)
- Give it a database: [Provision a database](../how-to/provision-a-database.md)
- Understand what you just used: [Platform topology](../explanation/platform-topology.md)
- Everything you can read when things misbehave:
  [Health and status surfaces](../reference/health-surfaces.md)
