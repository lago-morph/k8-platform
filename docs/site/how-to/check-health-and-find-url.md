---
status: stable
---

# Check an application's health and find its URL

Answer "is my app healthy, and what's its URL?" using only what the
platform exposes. Three layers, checked in order — delivery, runtime,
endpoint — because each one scopes the next. The exact fields and
their meanings live in
[Health and status surfaces](../reference/health-surfaces.md).

## 1. Is it delivered? (Argo CD Application)

On the management cluster:

```bash
kubectl get application <cluster-short-name>-<app> -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}'
```

- `Synced/Healthy` — Git and cluster agree, workload reports ready.
  Move on.
- `OutOfSync/...` — a rollout or a not-yet-reconciled change.
- `.../Degraded` — resources failing; read the message:

```bash
kubectl get application <name> -n argocd \
  -o jsonpath='{.status.operationState.message}'
```

## 2. Is it running? (your namespace)

On the cluster the app runs on:

```bash
kubectl -n <ns> get pods
kubectl -n <ns> rollout status deploy/<name>
kubectl -n <ns> get events --sort-by=.lastTimestamp | tail -5
kubectl -n <ns> logs deploy/<name> --tail=50
```

## 3. What's the URL, and does it answer?

The URL is declared by your own Ingress — read it back rather than
remembering it:

```bash
kubectl -n <ns> get ingress <name> \
  -o jsonpath='{.spec.rules[0].host}'
```

Then:

```bash
curl -sSf https://<that-host>
```

HTTP 200 over verified TLS is the platform's definition of a working
exposure. If layers 1 and 2 are green but this fails, work the
[expose guide's troubleshooting order](expose-an-application.md#troubleshooting-order)
— it is almost always DNS propagation on a fresh Ingress.

## For infrastructure you provisioned

Composite resources report the same way everywhere:

```bash
kubectl get xplatformsecret,xdatabase -n <ns>   # READY column
kubectl describe xdatabase <name> -n <ns>       # conditions + events
```
