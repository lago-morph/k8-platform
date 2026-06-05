# `clusters/platform/`

Manifests specific to the **platform services cluster** (Iteration 3 in
`ai/DESIGN.md`, REQ-PLAT-01..06).

This directory holds the inputs that turn the management cluster's
platform abstractions into a running platform cluster:

| File | Purpose |
|---|---|
| `platform-cluster-claim.yaml` | The `PlatformCluster` claim that Crossplane reconciles into a real EKS cluster + node group + IAM roles. Provisioning is **manual**: the ArgoCD app at `argocd/apps/platform-cluster-claim.yaml` is configured `syncPolicy: {}` (no automated sync) because applying this claim creates real EKS resources that take ~15 minutes to provision and ~10 minutes to tear down. Sync explicitly from the ArgoCD UI or `argocd app sync platform-cluster-claim` when you mean to. |

## Workflow (phase 3 entry point)

1. Edit `platform-cluster-claim.yaml` — substitute the placeholder
   `subnet-REPLACE-ME-*` IDs with private subnet IDs from the base
   module output (`terraform output -raw private_subnet_ids` once base
   exposes that output).
2. Commit + merge.
3. In the ArgoCD UI: `platform-cluster-claim` → Sync. Watch the
   Crossplane composite reconcile (`kubectl get xplatformcluster`).
4. Once `Ready=True`, the cluster is up. Subsequent phase-3 PRs add:
   - ArgoCD ApplicationSet targeting the new cluster
   - ingress-nginx, ExternalDNS (scoped to `platform.<domain>`),
     wildcard ACM certificate (provisioned by the cluster Composition; docs/decisions/0003)
   - A `hello.platform.<domain>` test app

## Why a separate directory

`crossplane/claims/` holds **example** claims (copy/paste starting
points; warned-not-applied). `clusters/platform/` holds the **actual**
claim that defines this cluster — applied by ArgoCD as the platform's
identity, not as documentation.

The lifecycle is also different: `crossplane/claims/` is part of the
XRD's developer-docs surface; `clusters/platform/` is operational
truth.
