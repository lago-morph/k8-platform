# scripts/

Deterministic helpers for inspecting a live management cluster. Designed
for use during debugging, in incident response, or to be invoked from the
GitHub Actions workflow when a verify step fails.

All scripts:

- Take their kubeconfig from `$KUBECONFIG` (or fall back to the cluster
  the current AWS creds can reach via `aws eks update-kubeconfig`).
- Print human-readable output to stdout, errors to stderr.
- Exit non-zero only on hard failure (no cluster reachable, missing tool);
  never fail because a resource is missing — that's information.
- Are safe to read-only: nothing in this directory mutates cluster state.

## Inventory

| Script | Purpose |
|---|---|
| `whereami.sh` | Session-start probe: account, region, EKS, zone, kubectl ctx, ArgoCD URL, Crossplane version. Use `--json` as an e2e precondition gate; `--cache` to write `/tmp/session.env` for subagents. |
| `k8s-status.sh` | Overall snapshot: nodes, namespaces, pod summary per ns. |
| `k8s-logs.sh` | Pull recent logs for a labelled deployment. |
| `diag-component.sh` | All-in-one dump for one of our components (argocd, external-dns, etc.) — pods, logs, events, the helm release row. |
| `kyverno-policies.sh` | List installed ClusterPolicies and their mode. |
| `kyverno-violations.sh` | Current PolicyReport violations across all namespaces. |
| `argocd-apps.sh` | ArgoCD Application/AppProject status. |
| `route53-records.sh` | List record sets in the discovered hosted zone. |
| `aws-creds-check.sh` | STS round-trip + Route53 zone discovery (no cluster needed). |
| `wait-for-claim.sh` | Polls a Crossplane claim's `Ready=True`; dumps conditions+events on timeout (SPEC-S7). |

Shared helpers (sourced, not executed): `_lib/k8s-helpers.sh` (introduced
by SPEC-S7) holds read-only kubectl helpers consumed by `wait-for-claim.sh`
and future scripts (`crossplane-trace.sh`, etc.).

## Conventions

- Component names used by `diag-component.sh`: `argocd`, `crossplane`,
  `external-dns`, `eso`, `ingress-nginx`, `kyverno`.
- `k8s-logs.sh` accepts `<namespace> [<label-selector>]`. Default selector
  is `app.kubernetes.io/component=controller` if you omit it.
- All scripts honor `--help` and print a one-paragraph synopsis.

## Bootstrap

```sh
# One-time per session: point kubectl at the management cluster.
aws eks update-kubeconfig --name k8-platform-mgmt --region us-east-1
```

After that, every script in this directory works without further setup.
