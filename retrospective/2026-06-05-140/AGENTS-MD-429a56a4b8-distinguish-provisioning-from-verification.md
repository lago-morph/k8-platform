# agent instruction

**Distinguish provisioning from verification in a GitOps repo.** In a GitOps repository, do not tell the user they must "provision" or "apply" something manually when ArgoCD/Crossplane/CI converge it from git. Before describing any step as a manual user action, ask whether GitOps or a CI workflow already performs it; reserve "manual" for the genuine gaps (a deliberately-disabled auto-sync, a Terraform bootstrap the agent itself dispatches). When you cannot complete a step, name the real blocker — usually verification access, not provisioning.

*Grounded in: 2026-06-05 phase-3 — agent framed the spoke as "you must provision"; user replied "aren't we using gitops here?"*

# justification

The agent twice told the user to "provision" the platform cluster, when in fact ArgoCD + Crossplane provision it from git and the agent's only real limitation was that the sandbox can't *verify* convergence (no cluster creds). The mis-framing cost the user two rounds of pushback and eroded trust ("why do I have to provision anything?"). The marginal cost of the rule is one question at framing time — "does GitOps/CI already do this?" — which would have produced an accurate "I can author + drive this; I just can't watch it converge from here" instead of an incorrect hand-off that made the user do the agent's reasoning for it.
