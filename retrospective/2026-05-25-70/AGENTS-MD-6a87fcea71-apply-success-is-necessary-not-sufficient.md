# agent instruction

**Apply success is necessary, not sufficient.** When a `terraform apply` or `kubectl apply` returns a green exit, that confirms only the tool's own state operation completed — NOT that the intended cluster state has changed. Before reporting an apply as successful, verify with an evidence query: `kubectl get` the affected object, check its `.spec` / `.status` matches the intent, and watch downstream controllers reconcile. Treat `Apply complete! Resources: 0 added, 0 changed, 0 destroyed` after a manifest edit as a *failure signal*, not success — it usually means `terraform_data.triggers_replace` is missing a dependency.

*Grounded in: terraform-test run 26354235231 — `Apply complete! 0 added` after PR #66's manifest edit, silently no-op'd by a `triggers_replace` miss; only caught by reading the plan/apply log lines.*

# justification

This was the dominant failure mode of the late-2026-05-24 IRSA-fix cascade: three independent times (PR #66, PR #67's first apply, PR #68's first apply) a green tool exit was misread as "the change reached the cluster". Each misread cost an extra dispatch cycle (~3 minutes apply + ~3 minutes diagnose + log analysis) and forced another PR. The marginal cost of the rule is one `kubectl get` per apply (≤2 seconds). The asymmetric payoff is high: catching one missed apply pays for the next 100 verification steps. The same anti-pattern applies to `kubectl apply` (success means the API server accepted the manifest, not that the controller reconciled it) and to ArgoCD sync operations (Synced/Healthy lags the actual workload state by the controller's reconcile interval).
