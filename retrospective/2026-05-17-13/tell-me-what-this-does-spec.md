# Spec: `tell-me-what-this-does` (sub-skill of `tell-me-about-this-repo`)

## Intent

Generates a conceptual / functionality overview of the current repository: how it actually works *today*. Emphasis on the development workflow, CI/CD, secrets, branch policy, PR flow, automation, and the integration points (skills, hooks) that future contributors must understand to operate the repo. Heavy on diagrams sourced from existing repo materials.

Models the document already produced in this session: `summary/functionality-2026-05-17.md` (657 lines, 7+ Mermaid diagrams). That document is the reference quality bar.

## Trigger

Invoked by the parent `tell-me-about-this-repo` skill, or directly by:

- "Tell me what this does."
- "What is this repo?"
- "Explain this repo's workflow."
- `/tell-me-what-this-does`

## Inputs

- Repo working tree at HEAD.
- `UTC_DATE` and `HASH` passed from parent (or computed if invoked directly).
- GitHub MCP tools restricted to the repo.

## Outputs

A single Markdown file at `summary/functionality-{UTC_DATE}-{HASH}.md` containing:

1. **Repository layout** — a tree (ASCII or Mermaid) annotated with one-line purposes per top-level entry.
2. **End-to-end developer flow** — Mermaid flowchart from "developer pushes branch" through CI to "PR merged".
3. **CI workflow walkthrough** — for every workflow file under `.github/workflows/`, a sequence diagram and a table of steps with `continue-on-error` markers. Cite file paths and line ranges.
4. **Secrets** — table of every secret required, what consumes it, and what is auto-computed at runtime. Flow diagram showing secret → step.
5. **Branch policy** — table mapping each branch-prefix convention (from `CLAUDE.md` / `AGENTS.md`) to behavior, plus any observed deviations on `main` (commits without PRs).
6. **PR / Issue history** — a Mermaid Gantt or timeline plus a per-PR table (number, title, merge date, one-line purpose). Cover **all** PRs (use `mcp__github__list_pull_requests` with `state=all`). Same for issues.
7. **Agent / skill integration** — diagram of how `.claude/skills/`, hooks (`settings.json`), and any agent-facing docs wire into the dev loop.
8. **Cross-reference table** — "where do I find X?" pointers (testing, deploy, debug, design docs).
9. **Honest gaps** — a "not documented" section listing things the doc could NOT answer from source material.

## Workflow

### Step 0 — Confirm inputs

```bash
UTC_DATE=${UTC_DATE:-$(date -u +%Y-%m-%d)}
HASH=${HASH:-$(git rev-parse --short HEAD)}
OUT="summary/functionality-${UTC_DATE}-${HASH}.md"
```

### Step 1 — Enumerate source material

Run **all of** the following (in parallel where possible):

```bash
find . -name '*.md' -not -path './.git/*'      # every markdown file
ls -la .github/workflows/ .github/scripts/      # all CI artifacts
ls -la .github/ISSUE_TEMPLATE/ 2>/dev/null      # issue templates (may be absent)
ls -la .claude/                                  # agent integration
git log main --oneline | head -50               # recent commit history
```

Plus, via GitHub MCP:

- `mcp__github__list_pull_requests` with `state=all` — paginate if needed.
- `mcp__github__list_issues` with `state=all`.
- `mcp__github__pull_request_read` per PR for body/labels.
- `mcp__github__issue_read` per issue.

### Step 2 — Read

Read every file enumerated in Step 1 that's relevant. Be aggressive: a 600-line doc is the target. Be specific: cite file paths and line numbers.

### Step 3 — Write the document

Required Mermaid diagrams (minimum):

- High-level developer flow (`flowchart`).
- CI workflow sequence (`sequenceDiagram`).
- Secret-flow (`flowchart` or `graph`).
- Skill/hook integration (`flowchart`).
- Branch-prefix → behavior (`table` is acceptable here; or a `stateDiagram`).
- PR timeline (`gantt`).
- Repository layout (`tree` rendered as code-block, or `mindmap`).

**Mandatory escaping rules for Mermaid:**

- Do NOT put literal `|` inside `[Label]`, `(Label)`, `{Label}`, or `((Label))` node-label brackets. Use `/` or `&#124;`. The `-->|edge label|` syntax is fine.
- Do NOT put `<br/>` directly adjacent to `|` characters in any context.
- Do NOT use bare `:` or `;` inside node labels without quoting.

### Step 4 — Render-verification preflight

Before writing the file to its final path, scan the generated content:

```bash
awk '/^```mermaid/,/^```$/' "$OUT" \
  | grep -nE '\[[^][]*\|[^][]*\]' && exit 1 || true
```

If the check fails, fix the offending diagrams (replace `|` with `/`) and re-run.

### Step 5 — Save and report

Write to `$OUT`. Report back to the parent with: path, line count, diagram count, 5-line summary.

## Concrete examples

### Example 1 — Fresh repo

User asks "what does this repo do?". Sub-skill runs, enumerates 24 markdown files, 1 workflow YAML (425 lines), 11 PRs, 1 issue. Produces `summary/functionality-2026-06-01-ab12cd3.md` with 7 Mermaid diagrams. Render check passes. Returns to parent.

### Example 2 — Repo with no GitHub history

If the repo has zero PRs (fresh init), the PR section becomes:

> No pull requests yet. This repo is pre-PR-flow.

…and the section is shorter. Don't fabricate. The "honest gaps" section gets a corresponding bullet.

## Anti-patterns

- **Fabricating diagrams.** Every diagram must trace to specific files/PRs/issues. If you can't ground it, don't draw it.
- **Skipping the render-verification preflight.** This sub-skill exists in part because PR #13 in this repo had to ship a 2-character fix for an unrendered diagram. The preflight catches it before it leaves the worktree.
- **Truncating the PR list.** "Most PRs" is not enough. List all of them.
- **Glossing the workflow YAML.** Cite line ranges and quote step IDs. A reader should be able to map your sequence diagram to actual YAML.
- **Treating `pending` CI status as a failure.** If `total_count: 0`, no check ran. Say so plainly.

## Acceptance criteria

1. Output file ≥ 400 lines and ≥ 6 Mermaid diagrams.
2. Every PR returned by `mcp__github__list_pull_requests state=all` appears in the PR table.
3. Render-verification preflight passes (no literal `|` inside `[Label]`).
4. Every secret listed in `CLAUDE.md` / agents file appears in the secrets section.
5. At least one "honest gap" bullet is present, OR explicit confirmation that nothing was missing.

## Files this skill creates / modifies

- `summary/functionality-{UTC_DATE}-{HASH}.md` — written fresh (overwritten if exists).
