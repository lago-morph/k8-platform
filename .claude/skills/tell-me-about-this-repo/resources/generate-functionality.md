# Generate `summary/functionality-{DATE}-{HASH}.md`

Loaded by the subagent that the `tell-me-about-this-repo` skill dispatches when the user wants a "what this does" / workflow / functionality overview of the repo. **Always run as a subagent in an isolated worktree.**

## Inputs (passed in the subagent brief)

- `UTC_DATE` — verified date string `YYYY-MM-DD`.
- `HASH` — `git rev-parse --short HEAD` at the moment the parent skill was invoked.
- Repo working tree.
- GitHub MCP tools restricted to the current repo.

## Output

A single Markdown file at `summary/functionality-${UTC_DATE}-${HASH}.md`. Target length: 500–700 lines, ≥7 Mermaid diagrams.

## Required sections

1. **Repository layout** — tree (ASCII or Mermaid `mindmap`); every top-level entry annotated with one-line purpose.
2. **End-to-end developer flow** — Mermaid `flowchart` from "developer pushes branch" through CI to "PR merged".
3. **CI workflow walkthrough** — for every YAML in `.github/workflows/`: a Mermaid `sequenceDiagram` of its steps, plus a table listing each step's ID, action, and `continue-on-error` flag. Cite file paths and line ranges.
4. **Secrets** — table of every required secret (where it's consumed, what's auto-computed) plus a Mermaid `flowchart` mapping secret → workflow step.
5. **Branch policy** — table of branch-name prefix → behavior (auto-trigger CI? manual dispatch only?). Quote the agents file. Note any observed deviations on `main` (commits without PRs).
6. **PR / Issue history** — Mermaid `gantt` over all PRs, plus a per-PR table (number / title / merge date / one-line purpose). Use `mcp__github__list_pull_requests state=all`. Same for issues via `mcp__github__list_issues`.
7. **Agent / skill integration** — Mermaid `flowchart` of `.claude/skills/`, `settings.json` hooks, and agent-facing docs.
8. **Cross-reference table** — "where do I find X?" pointers (testing, deploy, debug, design docs).
9. **Honest gaps** — bullet list of things the doc could not answer from source material, OR an explicit "no gaps identified" line.

## Workflow

### 1. Confirm inputs

```bash
UTC_DATE=${UTC_DATE:-$(date -u +%Y-%m-%d)}
HASH=${HASH:-$(git rev-parse --short HEAD)}
OUT="summary/functionality-${UTC_DATE}-${HASH}.md"
mkdir -p summary
```

### 2. Enumerate sources

```bash
find . -name '*.md' -not -path './.git/*'
ls -la .github/workflows/ .github/scripts/
ls -la .github/ISSUE_TEMPLATE/ 2>/dev/null
ls -la .claude/
git log main --oneline -50
```

Via GitHub MCP:
- `mcp__github__list_pull_requests state=all` — paginate as needed.
- `mcp__github__list_issues state=all`.
- `mcp__github__pull_request_read` for each PR.
- `mcp__github__issue_read` for each issue.

### 3. Read

Read every enumerated file that's relevant. Cite file paths and line numbers. Don't paraphrase YAML — quote step IDs.

### 4. Write the document with Mermaid escaping rules

- **Never** put literal `|` inside node-label brackets `[…]`, `(…)`, `{…}`, `((…))`, `[/…/]`. Use `/` or `&#124;`.
- The `-->|edge label|` arrow syntax IS fine — only node labels are affected.
- Avoid bare `:` and `;` inside node labels.
- `<br/>` is fine inside node labels; don't put it adjacent to `|`.

### 5. Render-verification preflight (mandatory)

After writing the file:

```bash
awk '/^```mermaid/,/^```$/' "$OUT" | grep -nE '\[[^][]*\|[^][]*\]'
```

If anything matches, fix the offending diagrams (replace `|` with `/`) and re-run until empty.

### 6. Report back

To the parent (or user, if invoked directly): file path, line count, diagram count, 5-line summary of doc contents.

## Anti-patterns

- **Fabricating diagrams.** Every diagram must trace to specific PRs / files / issues.
- **Truncating the PR list.** List all of them, not "most".
- **Glossing the workflow YAML.** Cite line ranges; quote step IDs.
- **Skipping the render-verification preflight.** PR #13 in this repo's history is the reason this step exists.
- **Treating `pending` CI status with `total_count: 0` as a failure.** It just means no check registered itself.

## Acceptance

1. File ≥ 400 lines and ≥ 6 Mermaid diagrams.
2. Every PR returned by `list_pull_requests state=all` appears.
3. Render-verification preflight returns no matches.
4. Every secret named in the agents file appears in §4.
5. Either ≥1 "honest gap" bullet OR an explicit "no gaps identified" statement.
