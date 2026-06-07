# agent instruction

**Audit the crossplane IAM policy for full per-kind lifecycle actions when a Composition adds new MR kinds.** "When a Crossplane Composition introduces a new managed-resource kind, audit the crossplane IRSA policy for that kind's every create/observe/update/delete/tag action BEFORE relying on it live; upjet observes via Get and reconciles via Update, so a policy missing Get/Update/Tag for a kind fails closed at apply with AccessDenied even when Create is present."

*Grounded in: auto-012 — four separate AccessDenied rounds (TagOIDC, UpdateAssumeRolePolicy, GetRolePolicy, all of rds:*).*

# justification

This session lost four expensive live reconcile-loop rounds discovering missing crossplane permissions one at a time — `iam:TagOpenIDConnectProvider`, then `iam:UpdateAssumeRolePolicy`, then `iam:GetRolePolicy`, then the entire `rds:*` set. Each round cost a kube-diagnose dispatch to read the MR's failure condition, a policy-version edit, and a reconcile wait. upjet surfaces missing permissions one lifecycle phase at a time (create succeeds, the next reconcile's observe/update/tag fails), so they never appear together. A single up-front audit mapping the MR kinds a Composition renders (OIDC provider, Role, RolePolicy, AccessEntry, RDS Instance) to their required actions would have caught all four in one pass. Marginal cost: one grep+read pass per new Composition; cost of skipping it: ~15 minutes per missed action per live loop.
