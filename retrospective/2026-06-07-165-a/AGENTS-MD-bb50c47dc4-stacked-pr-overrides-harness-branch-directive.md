# agent instruction

**Honor an explicit stacked-PR request over the harness single-branch directive.** "When the user explicitly asks for stacked PRs, use the stacked-PR workflow even if the harness pinned the session to one branch; the owner has given standing permission (recorded in the stacked-pr-on-feature-branch skill) to override the branch-shape directive for that request, while still never committing to main and keeping all other PR/test discipline."

*Grounded in: auto-012 — the user noted agents keep refusing stacked PRs because the harness says one-branch, and granted a standing override.*

# justification

The user observed that "most sessions, even when instructed to use stacked PRs, don't want to because the agent harness instructs them to just use one branch" — and this very session did exactly that, honoring the single-branch task directive over the stacked-PR skill's default. The owner's standing permission resolves the conflict cleanly: an explicit stacked-PR request from the user wins over the harness branch-shape directive. The override is deliberately narrow — it covers only branch shape (one branch vs. stacked child branches); it never waives the no-commit-to-main rule or any test/commit/PR-review discipline. The cost of adopting the rule is zero; the cost of ignoring it is that the user's explicitly-stated workflow preference gets silently overridden every session.
