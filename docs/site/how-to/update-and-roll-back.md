---
status: stable
---

# Update and roll back an application

Day-2 changes: ship a new image or configuration, watch it land, and
undo it if it's bad. Both directions are the same mechanism — a commit
to `main` — because Git is the only write path this platform has.

## Update

1. Change the chart in Git — typically the pinned image tag:

    ```yaml
    image:
      repository: registry.example.com/myapp
      tag: "1.4.2"        # was 1.4.1 — always pinned, never latest
    ```

2. Merge to `main`. The Application reconciles automatically; no
   command is issued.

3. Watch it land:

    ```bash
    kubectl get application <cluster>-myapp -n argocd \
      -o jsonpath='{.status.sync.status}/{.status.health.status}'
    # OutOfSync/Progressing → Synced/Healthy

    kubectl -n myapp rollout status deploy/myapp
    ```

Rollouts follow your Deployment's strategy (rolling update by
default) — the platform adds delivery, not new rollout semantics.

## Roll back

A bad change is undone by reverting the commit:

```bash
git revert <bad-commit>
git push        # via your PR flow
```

Once the revert merges, the same reconcile loop converges the cluster
back to the previous state. Verify exactly as above, then confirm the
running image:

```bash
kubectl -n myapp get deploy myapp \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

## What NOT to do

!!! warning "Hand edits do not survive"
    `kubectl edit`, `kubectl set image`, and console changes are
    reverted by the platform's self-heal within its reconcile
    interval. This is by design — an emergency fix that only exists on
    the cluster is a fix that vanishes on the next sync. If it matters,
    it goes through Git.

## Notes for scenario oracles

- After a merge, expect the Application to pass through
  `OutOfSync` → `Synced` with `Healthy` at the end; there is no
  platform-provided "deployment finished" event beyond that.
- Reconciliation is continuous with retry/backoff (up to ~5 minutes
  between attempts on a failing sync). There is no tighter published
  latency contract for merge → `Synced/Healthy` than "within minutes";
  as a planning bound, allow **10 minutes** end-to-end before treating
  a healthy-looking change as stuck — that headroom covers the
  reconcile interval plus one full retry backoff.
- A revert produces a **new** commit; the platform has no concept of
  "previous version" outside Git history.
