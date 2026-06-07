# 3. Branch policy

**Never commit to `main` directly.** All work happens on named branches.

```
feat/<short-description>    # new functionality
fix/<short-description>     # bug or CI fix
chore/<short-description>   # maintenance (deps, docs, refactor)
test/<short-description>    # adding tests or re-running existing tests
```

The Terraform CI workflow (`terraform-test.yml`) is `workflow_dispatch`-only.
The agent invokes it via the active capability profile (`gh` CLI →
GitHub MCP with Actions coverage → `ext-github` via jentic). Detection and
the per-profile operation table live in
`.claude/skills/terraform-ci-watch/reference/capabilities.md`.

### Stacked PRs

When dependent work needs to start before a parent PR has merged, stack:

1. Create the parent PR off `main` as normal.
2. From the parent branch, create the child branch.
3. Open the child PR with `base = <parent branch>` (not `main`).
4. Once the parent merges, GitHub auto-rebases the child to `main`.

Don't wait for a parent to merge before starting the child. State the
dependency in the child PR's description.

---

*Source detail for `AGENTS.md`. The summary in AGENTS.md is authoritative for scope; this file holds the full text.*
