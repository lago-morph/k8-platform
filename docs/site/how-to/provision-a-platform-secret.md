---
status: stable
---

# Provision a platform secret and consume it

Your application needs a generated credential — a password, a token, an
API key seed — that must never appear in Git. You declare **one
Kubernetes object**; the platform generates the material, stores it in
AWS Secrets Manager, and delivers it into your namespace as a native
Kubernetes `Secret` your workload mounts like any other. The same
secret can be consumed from other clusters in the platform through its
deterministic name, without copying the value anywhere.

## Before you start

- You have a namespace on the **management cluster** (where platform
  secrets are reconciled) and a Git path that an Argo CD Application
  syncs there — or direct `kubectl` access to that cluster for
  experimentation.
- The platform secret kind is served:

  ```bash
  kubectl api-resources | grep xplatformsecret
  ```

## 1. Declare the secret

Create a manifest for an `XPlatformSecret` composite resource in your
namespace. Everything in `spec` is optional:

```yaml
apiVersion: platform.k8-platform.io/v1alpha1
kind: XPlatformSecret
metadata:
  name: my-app-credentials
  namespace: <your-namespace>
spec:
  # All fields optional; the defaults are shown.
  refreshInterval: 1h        # how often the K8s Secret re-syncs from AWS
  region: us-east-1          # where the backing AWS secret lives
  description: ""            # free text; surfaces in the AWS console
```

Commit it to the Git path your Argo CD Application syncs (the platform
way — this is how the platform provisions its own secrets), or apply
it directly while experimenting:

```bash
kubectl apply -f my-app-credentials.yaml
```

Do **not** put a secret value anywhere in the manifest. There is no
field for one: the platform generates the material server-side, and
the manifest stays committable forever.

## 2. Wait for it to become ready

```bash
kubectl wait --for=condition=Ready \
  xplatformsecret/my-app-credentials -n <your-namespace> --timeout=600s
```

Provisioning usually completes within a minute; the platform's own
test bound allows up to ten minutes for the occasional slow first
reconcile of the AWS provider, which is why the timeout above is
generous.

## 3. Read what was delivered

A Kubernetes `Secret` named after your composite resource now exists
in your namespace, carrying a single key, `value` — a generated
32-character string of letters and digits:

```bash
kubectl get secret my-app-credentials -n <your-namespace> \
  -o jsonpath='{.data.value}' | base64 -d
```

The ARN of the backing AWS Secrets Manager entry is published on the
composite resource's status:

```bash
kubectl get xplatformsecret my-app-credentials -n <your-namespace> \
  -o jsonpath='{.status.asmSecretArn}'
```

You will also see two helper objects the platform created alongside —
`my-app-credentials-material` (an ExternalSecret) and
`my-app-credentials-gen` (a Password generator) — plus the
`my-app-credentials` ExternalSecret that feeds your Secret. They are
platform machinery: leave them alone, and never edit the delivered
Secret by hand (the platform owns and re-syncs it).

## 4. Mount it in your workload

Consume it exactly like any Kubernetes Secret:

```yaml
env:
  - name: APP_PASSWORD
    valueFrom:
      secretKeyRef:
        name: my-app-credentials
        key: value
```

## Consume the same secret from another cluster

The backing AWS secret has a **deterministic name**:

```
k8-platform/<namespace>/<name>
```

for the namespace and name of your `XPlatformSecret`. That name is the
cross-cluster contract: any platform cluster (each ships the
`aws-secrets-manager` ClusterSecretStore) can commit an
`ExternalSecret` that references it — no value ever passes through
Git or a human:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-credentials
  namespace: <consumer-namespace>       # on the consuming cluster
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: my-app-credentials            # the K8s Secret to materialize
    creationPolicy: Owner
  data:
    - secretKey: value
      remoteRef:
        key: k8-platform/<namespace>/<name>   # the deterministic name
        property: value
```

If the consuming application expects a differently named key, add a
`spec.target.template` that remaps it (the platform itself does this
where a chart dictates key names). For a consumer that must survive
the source disappearing — a bootstrap credential a running workload
still depends on — set `spec.target.deletionPolicy: Retain`.

## What you can rely on

- **Naming.** Kubernetes `Secret` = the `XPlatformSecret` name, in its
  namespace, key `value`. AWS name = `k8-platform/<namespace>/<name>`.
- **Generate-once material.** The platform generates the value at
  provision time and never rotates it behind your back. Rotation is
  deliberately out of the current design's scope.
- **Propagation.** If the AWS-side value is ever changed (an
  operator action outside this page's scope), consuming Secrets
  re-sync within their `refreshInterval`.
- **Cleanup.** Deleting the `XPlatformSecret` deletes the delivered
  Secret **and** the AWS entry immediately — no recovery window. Treat
  deletion as destroying the credential.

## Remove it

```bash
kubectl delete xplatformsecret my-app-credentials -n <your-namespace>
```

!!! warning "Deletion is immediate and unrecoverable"
    The backing AWS secret is deleted without a recovery window, and
    cross-cluster consumers (unless they set `deletionPolicy: Retain`)
    lose their copy on their next sync.

!!! info "Reality check: tenant self-service wiring"
    The mechanism on this page is fully platform-managed and verified.
    What is *not* yet a self-service product operation is the tenant
    wiring around it — getting your own namespace and a Git path
    synced to the management cluster today involves the platform
    operator (see the tenant onboarding guide, planned). This page
    documents the platform as it is.
