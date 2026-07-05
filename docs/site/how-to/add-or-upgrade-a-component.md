---
status: stable
---

# Add or upgrade a platform component

Operator task: extend the platform's add-on stack (ingress, DNS,
observability, auth, and the like) or move an existing component to a
new chart version — as a reviewed Git change with an observable
rollout, never a console session. Every component already on the
platform landed exactly this way, so the recipe below is the committed
pattern, not aspiration.

## Add a component

**1. Allow its chart source.** Add the chart repository's **exact
URL** to `sourceRepos` in `argocd/projects/platform-spoke.yaml`.
No wildcards — CI rejects them. This list is the platform's
supply-chain boundary; adding to it is a deliberate, reviewed act.

**2. Commit its values.** Per-cluster or shared values live in this
repository under `platform-services/<component>/`. Account-specific
values (domains, role ARNs, regions) are **never committed** — they
are injected per cluster from the platform's cluster-facts mechanism
at sync time.

**3. Add the ApplicationSet.** `argocd/apps/spoke/<component>.yaml`,
following the committed pattern of the existing components:

- `project: platform-spoke`
- cluster generator selecting `k8-platform.io/cluster-role: spoke`
- the upstream chart pinned to an **exact** `targetRevision`
- a `sync-wave` that respects ordering (e.g. ingress and DNS run at
  wave 20, workloads at 30; pick where the component belongs)
- automated sync with prune + self-heal

**4. Merge and verify.** The app-of-apps picks it up. Verify the new
Application reports `Synced/Healthy`, then verify **no tenant
impact**: the built-in demo endpoint must still answer —

```bash
curl -sSf https://hello.platform.<domain>
```

## Upgrade a component

1. Bump the pinned `targetRevision` (chart version) in its
   `argocd/apps/spoke/<component>.yaml` — one version, one commit,
   with the reason in the commit message.
2. If the component's version is **paired** with another pin (some
   components pin a chart version and a matching CLI/schema version in
   `versions.env`), bump the pair together — CI holds them equal.
3. Merge; the rolling upgrade happens on sync.
4. Verify as above: component `Synced/Healthy`, demo endpoint still
   200, and any component-specific health (its UI answering, its
   controller logs clean).

## Roll back a component change

`git revert` the bump commit and let the platform converge back —
same loop as [application rollback](update-and-roll-back.md). The
demo-endpoint check is your no-tenant-impact oracle in both
directions.

## Boundaries that protect you here

- The management cluster is not a valid destination for this stack —
  a component App cannot accidentally target the control plane
  ([Tenant boundaries](../reference/tenant-boundaries.md)).
- Unlisted chart repos and wildcard sources fail admission.
- Hand-tuning a live component is reverted by self-heal; if an upgrade
  needs a live experiment, do it knowing the cluster will snap back to
  Git.
