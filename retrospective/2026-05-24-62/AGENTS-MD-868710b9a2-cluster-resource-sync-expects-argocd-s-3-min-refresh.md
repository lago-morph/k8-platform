# agent instruction

**§6.X — After triggering ArgoCD-managed state (e.g., a Terraform apply that runs `terraform_data.argocd_bootstrap`), wait at least 3 minutes before asserting the resources are present.** ArgoCD's default refresh interval is 3 min; sync-wave cascades are serial. "Just dispatched, immediately polling" creates a race condition that surfaces as `OutOfSync` from timing, not from real drift.

*Grounded in: handoff iteration 1 review surfaced "Step 3 says wait ~30 seconds, that's way too short."*

# justification

A short wait causes false-positive diagnostics that lead to chasing non-bugs. The rule's cost is 2.5 extra minutes per dispatch. The cost of not having it is hours debugging ghosts.
