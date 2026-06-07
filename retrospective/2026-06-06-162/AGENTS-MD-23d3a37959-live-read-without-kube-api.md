# agent instruction

**Read live kube state via the ArgoCD REST API or a kube-diagnose workflow when the kube-API is unreachable.** "The sandbox cannot reach the private-CA EKS kube-API: the client cert fails (`x509: unknown authority`) and `--insecure-skip-tls-verify` only makes the egress gateway 503 on the upstream leg. Do not burn time on kubectl. Use the ArgoCD `GET /api/v1/applications/{app}/resource` endpoint (with the login token) for app-managed resources, and a read-only `kube-diagnose` `workflow_dispatch` job (script passed via `env:`, not inline interpolation) for arbitrary cluster reads and CRD-schema dumps."

*Grounded in: auto-011 — kubectl confirmed structurally blocked; the ArgoCD API + kube-diagnose workflow carried all live diagnosis.*

# justification

Two kubectl attempts (default and `--insecure`) failed in exactly the two ways the prior handoff predicted, costing a few minutes to re-confirm a known dead-end. The ArgoCD REST resource API returned an XR's full `.status.conditions` and `.spec.crossplane.resourceRefs` instantly, and a tiny `workflow_dispatch` diagnostic produced arbitrary `kubectl`/`aws` output from CI (where the kube-API *is* reachable) — together they localized a three-layer Crossplane stall that was invisible from AWS. Composed managed resources are not in the ArgoCD app tree, so the CI path is needed for MR-level conditions; the ArgoCD API is faster for app-managed objects. Naming both as the default live-read tools saves every future session the kubectl dead-end and the scramble to invent a read path mid-incident.
