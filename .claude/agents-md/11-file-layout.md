# 11. File layout

```
terraform/base/          # Phase 0 — VPC, Route53, Cognito
terraform/management/    # Phase 1 — EKS, IRSA, ArgoCD, Crossplane, ESO, ExternalDNS, Kyverno
argocd/                  # ArgoCD Applications and Projects
crossplane/              # XRDs, Compositions, Claims
clusters/                # Per-cluster Kubernetes resource overlays
platform-services/       # Helm values for platform components
policies/audit/          # Kyverno audit-mode ClusterPolicies
scripts/                 # Diagnostic helper scripts (read-only)
scripts/_lib/            # Shared bash helpers sourced by scripts/ executables (SPEC-S7+)
tests/unit/              # Pre-apply unit tests (helm-render, IRSA linkage, IAM policy completeness, EKS module defaults)
tests/integration/       # End-to-end smoke tests against the live cluster
tests/chainsaw/          # Chainsaw scenarios for Crossplane XRDs (phase 2+)
tests/e2e/               # Read-only AWS sanity checks
docs/                    # ADRs, operations runbook, diagrams
ai/                      # Design documents, requirements, handoff, testing plan
.github/workflows/       # CI workflows
.github/scripts/         # Helper scripts called by workflows
```

---

*Source detail for `AGENTS.md`. The summary in AGENTS.md is authoritative for scope; this file holds the full text.*
