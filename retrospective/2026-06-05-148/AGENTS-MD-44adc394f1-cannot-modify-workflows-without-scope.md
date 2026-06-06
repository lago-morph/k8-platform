# agent instruction

**Don't assume you can add or edit a `.github/workflows/` file; deliver it as a runbook doc if you can't.** "Before planning work that depends on creating or modifying a GitHub Actions workflow, know that in some environments you cannot: `git push` of a branch touching `.github/workflows/` is rejected when the push token lacks the `workflow` OAuth scope, and `mcp__github__create_or_update_file` returns 404 (not 403) on workflow paths when the GitHub App lacks the `workflows` permission. If both fail, do NOT keep retrying — deliver the workflow YAML inside a normal doc (e.g. `docs/runbooks/<name>.md`) with copy-paste install instructions, and log the constraint to `docs/open-issues.md` so the next session/maintainer can add it from a scoped context."

*Grounded in: auto-007 — adding `argocd-app-sync.yml` was rejected by `git push` (no `workflow` scope) AND 404'd by the MCP App, so the §10.1 CI-sync workflow could not be committed and was shipped as `docs/runbooks/argocd-sync-from-ci.md`.*

# justification

The §10.1 CI-driven ArgoCD sync was the correct unblock for the sandbox-egress problem — and it was un-shippable because neither write path had workflow permissions. Discovering this mid-attempt cost two failed write cycles (a rejected push, a 404'd MCP call) plus a branch-cleanup. Knowing the constraint up front changes the plan: a workflow-dependent unblock is not available, so the value is captured as a runbook for a maintainer rather than pursued as a dead end. The marginal cost of the rule is zero — it's a precondition check; the cost of not knowing it is burning attempts on a path the environment forbids and then having to reconstruct the deliverable as a doc anyway.
