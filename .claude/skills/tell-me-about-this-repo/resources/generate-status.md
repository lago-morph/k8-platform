# Generate `summary/status-{DATE}-{HASH}.md`

Loaded by the subagent that the `tell-me-about-this-repo` skill dispatches when the user wants a project-status report — what's shipped, what's left, what's blocked, what's anticipated. **Always run as a subagent in an isolated worktree.**

## Inputs (passed in the subagent brief)

- `UTC_DATE` — verified date string `YYYY-MM-DD`.
- `HASH` — `git rev-parse --short HEAD`.
- Repo working tree.
- GitHub MCP tools restricted to the current repo.

## Output

A single Markdown file at `summary/status-${UTC_DATE}-${HASH}.md`. Target length: 300–500 lines, ≥5 Mermaid diagrams.

## Required sections

1. **Iteration / milestone scorecard** — table: iteration → status (Shipped / Plan-green / Designed / Stubbed / Not started) → evidence (PR numbers, file paths) → notes.
2. **What's done vs. what's left** — per-iteration two-column table.
3. **Issue / PR throughput** — Mermaid `pie` chart by state, plus a `gantt` of merged PRs over time.
4. **Dependency graph** — Mermaid `flowchart` showing which planned features depend on which others.
5. **Architecture diagram with status colouring** — Mermaid `graph` with components shaded by status (use `classDef` for `done` / `progress` / `todo`).
6. **Current blockers (B1..Bn)** — table: blocker → reason → mitigation. Each row cites a file path or PR number.
7. **Anticipated future blockers (F1..Fn)** — table: anticipated → reason it's likely → likelihood/impact → suggested pre-emption.
8. **Risk matrix** — Mermaid `quadrantChart` of the blockers.
9. **Recommended immediate sequence** — at most 3 numbered next actions.
10. **Repository state snapshot** — fenced code block summarising per-subtree file counts / LOC / state label.

## Classification vocabulary (use these exact terms)

| Term | Means |
|---|---|
| **Shipped** | Code merged AND an apply / run / e2e test has confirmed it works. |
| **Plan-green** | Code merged and dry-run (`terraform plan` etc.) succeeds, but never executed against a real environment. |
| **Designed** | Spec / ADR / requirement exists, no code. |
| **Stubbed** | Directory or scaffolding exists with no real content. |
| **Not started** | Mentioned only in plans. |

## Workflow

### 1. Confirm inputs

```bash
UTC_DATE=${UTC_DATE:-$(date -u +%Y-%m-%d)}
HASH=${HASH:-$(git rev-parse --short HEAD)}
OUT="summary/status-${UTC_DATE}-${HASH}.md"
mkdir -p summary
```

### 2. Enumerate evidence

```bash
find . -name '*.md' -not -path './.git/*' | xargs grep -l -E 'handoff|status|roadmap|iteration' 2>/dev/null
find terraform/ argocd/ crossplane/ clusters/ platform-services/ -maxdepth 2 -type f 2>/dev/null
ls -la docs/ ai/
git log main --oneline -50
```

Plus all PRs and issues via the GitHub MCP tools.

### 3. Read carefully

- `ai/handoff.md` (or equivalent session-handoff doc).
- `ai/REQUIREMENTS.md`, `ai/DESIGN.md` — distinguish shipped vs. specified.
- Every `.tf` file in real Terraform dirs: which resources are real vs. which directories are empty.
- `docs/operations.md` (or equivalent) — note any stale links.

### 4. Identify blockers

Each blocker must be **specific** and cite a concrete evidence pointer. Not "we need more testing" — instead "Iter 1 apply has never been observed to succeed end-to-end against the sandbox (see `ai/handoff.md` §Current State)".

For anticipated blockers, reason from documented constraints (sandbox quotas, IAM caps, rate limits, dependency chains).

### 5. Write the document with Mermaid escaping rules

Same rules as the functionality generator:

- Never put literal `|` inside node-label brackets (`[…]`, `(…)`, `{…}`). Use `/` or `&#124;`.
- The `-->|edge label|` arrow syntax IS fine.

### 6. Render-verification preflight (mandatory)

```bash
awk '/^```mermaid/,/^```$/' "$OUT" | grep -nE '\[[^][]*\|[^][]*\]'
```

Must return no matches. Fix and re-run if it does.

### 7. Report back

To the parent (or user, if invoked directly): file path, line count, blocker counts (current + anticipated), 5-line summary.

## Anti-patterns

- **Conflating shipped with plan-green.** Always check the implementation, not the spec.
- **Vague blockers.** Each blocker row must cite a file path or PR.
- **Padding the anticipated-blockers section with hypotheticals.** Trace each F-row to a documented constraint.
- **Refusing to write "Not started" when that's the truth.** Don't soften.
- **Skipping the render-verification preflight.** Same lesson as the functionality generator.

## Acceptance

1. File ≥ 300 lines and ≥ 5 Mermaid diagrams.
2. Every iteration / milestone named in `ai/` or `docs/` appears in §1.
3. Every B-row and F-row cites a file path, PR number, or specific source.
4. Render-verification preflight returns no matches.
5. §9 has at most 3 numbered actions.
