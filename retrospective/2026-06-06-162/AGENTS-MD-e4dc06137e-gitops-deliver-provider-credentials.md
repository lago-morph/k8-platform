# agent instruction

**GitOps-deliver Crossplane provider credentials, never leave them as manual bootstrap steps.** "Any resource every composition depends on — the shared `ClusterProviderConfig`/`ProviderConfig`, provider runtime configs — must be delivered by terraform or a GitOps app, never a one-off `kubectl apply` documented only in a plan/runbook. A manual bootstrap step is absent on every rebuilt cluster and silently stalls all managed resources (Synced=False, zero cloud API calls)."

*Grounded in: auto-011 blocker #2 — the missing ClusterProviderConfig/default (SEG-1 §0c manual step) stalled all 11 platform-cluster MRs.*

# justification

The `ClusterProviderConfig/default` was documented as a manual `kubectl get || kubectl apply` in a plan doc and never automated. On the rebuilt management cluster it was simply gone, and every AWS managed resource sat `CannotConnectToProvider` with zero AWS API calls in CloudTrail — a failure that is invisible from AWS and from the ArgoCD app tree, surfacing only when a CI kube-diagnose dumped the MR conditions (~30 minutes of layered diagnosis). The marginal cost of the rule is a single manifest committed to the GitOps tree (or a terraform_data block); the cost of skipping it is a fully-stalled control plane on every fresh account plus a long blind diagnosis. The asymmetry is overwhelming.
