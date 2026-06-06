# agent instruction

**Drive provisioned public APIs directly from the permissive sandbox.** "When the agent has provisioned a service that exposes a public, internet-facing endpoint with a publicly-trusted TLS cert (e.g. ArgoCD behind an internet-facing NLB at `argocd.management.<domain>`), call that service's API DIRECTLY from the sandbox — the sandbox has permissive network egress. Obtain the credential created at install time (e.g. the `argocd_admin_password` / `argocd_server_url` Terraform outputs, §10.1) and run `argocd login` then `argocd app sync` from the sandbox. Do NOT assume the service is CI-only or unreachable and do NOT build a CI workflow to proxy it. Only the EKS kube-API (private CA) and reading Terraform state / AWS APIs without creds genuinely require CI."

*Grounded in: 2026-06-05 auto-005 — sessions stalled phase-3 by treating ArgoCD as unreachable and hunting for a sync workflow.*

# justification

Multiple sessions (this one included) stalled phase-3 provisioning for a long time by concluding "I can't reach the cluster / I need a CI sync workflow", then hunting for or trying to author a workflow they had no scope to create. The reality is cheap: ArgoCD is exposed on a public NLB with an ACM cert, the admin credential is already a Terraform output, and the sandbox can `argocd login` + `argocd app sync` directly. The marginal cost of the rule is one mental check ("is this endpoint public and do I have an install-time credential?"); the cost of missing it is a whole tangent of dead-end workflow engineering. The user named the recurrence explicitly: "You and other sessions keep getting hung up on this."
