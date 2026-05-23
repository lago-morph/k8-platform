# AGENTS.md suggestions — 2026-05-23-51

One proposed addition this turn. The other suggestions from `2026-05-23-50` still apply unchanged.

---

## Suggestion 1: Force-fire every new CI workflow before the PR that adds it merges

### Proposed addition

> **A CI workflow's first real fire MUST happen before the PR adding it is merged.** Add a no-op edit (whitespace, comment refresh) to a file inside the workflow's `paths` filter, in the same branch. Without it, the first run is on a future PR — where any install bug, missing `sudo`, or path-filter typo shows up as a confusing red check on someone else's work.
>
> *Grounded in: the `chainsaw.yml` `chmod /usr/local/bin/kind: Operation not permitted` bug surfacing only when PR #49 merged main and accidentally triggered the workflow for the first time, four PRs after authoring.*

### Why this earns its place in your agents file

PR #41 added `chainsaw.yml` and a unit test that verified the workflow YAML parsed, but the workflow never actually fired because the branch only touched `tests/chainsaw/**` and the workflow file itself — and the workflow's own path filter doesn't include `tests/unit/*` so a typo-fix push didn't trigger it either. The install bug (`sudo` missing on `/usr/local/bin/kind`) sat through:

- PR #41 authoring + adversarial subagent review (both didn't catch it — they were reviewing test plans, not runtime install).
- Three merges (#41 → main; #42 → main with chainsaw.yml present; #43 → main).
- Multiple `git merge origin/main` cycles in the stack.

It only surfaced when PR #49 merged main and the new merge commit's diff happened to touch a path the workflow filtered on. Total elapsed time between the bug being authored and it being caught: ~2 hours of session time across multiple PRs.

The rule's marginal cost is one trivial commit (e.g. `chore: trigger CI on chainsaw.yml` editing a whitespace line). Marginal benefit: every new CI workflow ships in a proven-firing state, install-step bugs surface on the PR that introduced them, not four PRs later on someone unrelated.

This rule already exists implicitly in the `ci-on-every-push` skill spec from `2026-05-23-50` (under "Acceptance criteria — workflow fires on a feature-branch push that touches the path filter"). Surfacing it in AGENTS.md makes it a checklist item, not just a skill-internal property.
