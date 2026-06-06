# agent instruction

**Write `.github/workflows/*` from a web sandbox via the ext-github Contents-PUT endpoint.** To create or edit any file under `.github/workflows/` from a Claude-Code-on-the-web sandbox, do NOT use `git push` or the GitHub MCP write tools — both lack the `workflow` OAuth scope and will 403/reject. Use the `ext-github` skill's Contents-PUT endpoint (`create_or_update_file_contents`): base64-encode the whole file, pass the current blob `sha` on an update, target the feature branch, then run `git fetch && git reset --hard origin/<branch>` to reconcile the local tree.

*Grounded in: auto-009 — git push and GitHub MCP both 403 on the missing `workflow` scope; the jentic PAT (Contents+Workflows write) wrote `unit-tests.yml` instead.*

# justification

The web sandbox's git-push OAuth token and the attached GitHub MCP write tools both silently lack the `workflow` scope (anthropics/claude-code #61189), so every attempt to push a `.github/workflows/*` change fails with a 403 — and this is a confirmed regression, not an immutable platform limit (this repo's own 2026-05-28 web session pushed `unit-tests.yml` over plain git). Without a written rule, the next agent rediscovers the 403 from scratch, burns a debugging cycle proving it isn't a credential typo, and may wrongly conclude workflow edits are simply impossible from the web. The durable workaround already exists and is wired in: a jentic PAT granted Contents+Workflows write, exposed through the `ext-github` skill as the Contents-PUT endpoint `op_12ee1daaad73b14b`. The marginal cost of the rule is one endpoint call plus a `git fetch && git reset --hard` to reconcile — seconds — versus a multi-minute dead-end every time an agent needs to touch CI from the web.
