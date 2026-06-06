# agent instruction

**ext-github / jentic drives GitHub Actions; it does not author workflow files.** "Use the `ext-github` skill (jentic broker) to DISPATCH workflows and READ runs/jobs/logs — that is its purpose and PAT scope (`k8-platform-actions-only`: Actions read+write, Contents read). Do NOT use it to create or edit `.github/workflows/` files or any repo file; its token has no write scope (a contents PUT returns `Resource not accessible by personal access token`). Neither the git-push OAuth app nor the GitHub MCP can write workflow files either. If a task seems to need a NEW workflow, first ask whether an existing workflow or a non-workflow mechanism achieves it."

*Grounded in: 2026-06-05 auto-005 — agent tried to create an argocd-sync workflow via jentic's contents API; wrong tool, and it failed.*

# justification

The agent spent a tangent trying to PUT a new `.github/workflows/argocd-sync.yml` through jentic's contents API, conflating the ext-github skill's Actions:write (dispatch) with the GitHub PAT `workflow`/`repo` write scope (edit workflow files). Two live probes returned `Resource not accessible by personal access token`. Documenting the boundary — jentic is a dispatcher/reader, not a committer — saves the next session from the same dead end and from over-claiming "I can create the workflow". Marginal cost: one sentence in the agents file; cost of omission: a wasted exploration the user had to interrupt twice.
