---
name: tell-me-what-this-does
description: |
  Sub-skill of tell-me-about-this-repo. Generates a single Markdown document
  describing how this repository actually works today — dev workflow, CI/CD,
  secrets, branch policy, PR/issue history, agent/skill integration — with
  heavy use of Mermaid diagrams sourced from existing repo materials.
  Writes to summary/functionality-{UTC_DATE}-{HASH}.md. Always run as a
  subagent (typically dispatched by the parent skill). Performs a mandatory
  render-verification preflight before finishing.
---

# Sub-skill: `tell-me-what-this-does`

Dispatched by `tell-me-about-this-repo` (or directly via `/tell-me-what-this-does`).

## Inputs

- `UTC_DATE` — verified UTC date (passed by parent or computed here).
- `HASH` — `git rev-parse --short HEAD` (passed by parent or computed here).
- Repo working tree.
- GitHub MCP tools restricted to the current repo.

## Required output sections

The document at `summary/functionality-${UTC_DATE}-${HASH}.md` MUST include all of:

1. **Repository layout** — tree (ASCII or Mermaid `mindmap`), every top-level entry annotated with one-line purpose.
2. **End-to-end developer flow** — Mermaid `flowchart` from "developer pushes branch" through CI to "PR merged".
3. **CI workflow walkthrough** — for every YAML in `.github/workflows/`: a Mermaid `sequenceDiagram` of its steps, plus a table listing each step's ID, action, and `continue-on-error` flag. Cite file paths and line ranges.
4. **Secrets table + flow diagram** — table of every required secret (where it's consumed, what's auto-computed) plus a Mermaid `flowchart` mapping secret → workflow step.
5. **Branch policy** — table of branch-name prefix → behavior (auto-trigger CI? manual dispatch only?). Quote the agents file. Note any observed deviations on `main` (commits without PRs).
6. **PR / Issue history** — Mermaid `gantt` over all PRs, plus a per-PR table (`number | title | merge date | one-line purpose`). Use `mcp__github__list_pull_requests state=all`. Same for issues via `mcp__github__list_issues`.
7. **Agent / skill integration** — Mermaid `flowchart` of `.claude/skills/`, `settings.json` hooks, and agent-facing docs.
8. **Cross-reference table** — "where do I find X?" pointers (testing, deploy, debug, design docs).
9. **Honest gaps** — bullet list of things the doc could not answer from source material, OR an explicit "no gaps identified" line.

## Workflow

### Step 1 — Confirm inputs

```bash
UTC_DATE=${UTC_DATE:-$(date -u +%Y-%m-%d)}
HASH=${HASH:-$(git rev-parse --short HEAD)}
OUT="summary/functionality-${UTC_DATE}-${HASH}.md"
mkdir -p summary
```

### Step 2 — Enumerate sources

```bash
find . -name '*.md' -not -path './.git/*'
ls -la .github/workflows/ .github/scripts/
ls -la .github/ISSUE_TEMPLATE/ 2>/dev/null
ls -la .claude/
git log main --oneline -50
```

Plus, via GitHub MCP:
- `mcp__github__list_pull_requests state=all` — paginate as needed.
- `mcp__github__list_issues state=all`.
- `mcp__github__pull_request_read` for each PR.
- `mcp__github__issue_read` for each issue.

### Step 3 — Read

Read every enumerated file that is relevant. Target length: 500–700 lines, ≥7 Mermaid diagrams. Be specific — cite file paths and line numbers.

### Step 4 — Apply Mermaid escaping rules

**Mandatory before writing diagrams:**

- Never put a literal `|` inside `[Label]`, `(Label)`, `{Label}`, `((Label))`, or `[/Label/]` node-label brackets. Use `/` or `&#124;`.
- The `-->|edge label|` arrow syntax IS fine.
- Avoid bare `:` or `;` inside node labels.
- `<br/>` is fine in node labels; don't put it adjacent to `|`.

### Step 5 — Render-verification preflight (mandatory)

After writing the file:

```bash
awk '/^```mermaid/,/^```$/' "$OUT" \
  | grep -nE '\[[^][]*\|[^][]*\]'
```

If this returns any matches, **fix the file** (replace the offending `|` with `/`) and re-run until empty.

### Step 6 — Report back

To the parent (or user, if invoked directly): file path, line count, diagram count, and a 5-line summary of the doc's contents.

## Anti-patterns

- **Fabricating diagrams.** Every diagram must trace to specific PRs / files / issues. If you can't ground it, don't draw it.
- **Truncating the PR list.** "Most PRs" is not enough. List all of them.
- **Glossing the workflow YAML.** Cite line ranges and quote step IDs.
- **Skipping the render-verification preflight.** This sub-skill exists in part because PR #13 in this repo shipped a 2-character fix for an unrendered diagram that escaped a 3-round fact-check loop.
- **Treating `pending` CI status with `total_count: 0` as a failure.** It just means no check registered itself.

## Acceptance

1. File exists at `summary/functionality-${UTC_DATE}-${HASH}.md` with ≥400 lines and ≥6 Mermaid diagrams.
2. Every PR returned by `list_pull_requests state=all` appears in the PR table.
3. Render-verification preflight returns no matches.
4. Every secret named in `CLAUDE.md` / agents file appears in §4.
5. Either ≥1 "honest gap" bullet OR an explicit "no gaps identified" statement.
