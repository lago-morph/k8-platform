# Spec: `tell-me-where-we-are` (sub-skill of `tell-me-about-this-repo`)

## Intent

Generates a project-status report: what has been shipped, what is in progress, what remains, what blocks the next step, and what blockers are anticipated. Reasons from concrete evidence (merged PRs, merged commits, ADRs, handoff notes, sandbox constraints). Heavy on diagrams (Gantt, dependency graph, risk matrix, status-coloured architecture map).

Models `summary/status-2026-05-17.md` (354 lines, 7 Mermaid diagrams). That document is the reference quality bar.

## Trigger

Invoked by the parent `tell-me-about-this-repo` skill, or directly by:

- "Tell me where we are."
- "What's the project status?"
- "What's left to ship?"
- "How's the project going?"
- `/tell-me-where-we-are`

## Inputs

- Repo working tree at HEAD.
- `UTC_DATE` and `HASH` passed from parent (or computed if invoked directly).
- GitHub MCP tools restricted to the repo.

## Outputs

Single Markdown file at `summary/status-{UTC_DATE}-{HASH}.md`. Required sections:

1. **Iteration / milestone scorecard** — table mapping iteration → status (Shipped / Plan-green / Designed / Not started) → evidence (which PRs, which files) → notes.
2. **What's done vs. what's left** — per-iteration two-column table.
3. **Issue / PR throughput** — pie chart by state, throughput Gantt.
4. **Dependency graph** — Mermaid flow showing which planned features depend on which others.
5. **Architecture diagram with status colouring** — Mermaid graph with components shaded by Shipped/In-progress/Not-started.
6. **Current blockers (B1..Bn)** — table: blocker → reason → mitigation. Each row cites a file path or PR.
7. **Anticipated future blockers (F1..Fn)** — table: anticipated → reason it's likely → likelihood/impact → suggested pre-emption. Reason from the evidence (sandbox limits, infra constraints, dependency chains).
8. **Risk matrix** — Mermaid quadrant chart of blockers.
9. **Recommended immediate sequence** — numbered list, the next 3 actions.
10. **Repository state snapshot** — fenced block summarizing file counts / LOC per subtree and a state label.

## Workflow

### Step 0 — Confirm inputs

```bash
UTC_DATE=${UTC_DATE:-$(date -u +%Y-%m-%d)}
HASH=${HASH:-$(git rev-parse --short HEAD)}
OUT="summary/status-${UTC_DATE}-${HASH}.md"
```

### Step 1 — Enumerate evidence

```bash
find . -name '*.md' -not -path './.git/*' | xargs grep -l -E 'handoff|status|roadmap|iteration' 2>/dev/null
find terraform/ argocd/ crossplane/ clusters/ platform-services/ -maxdepth 2 -type f 2>/dev/null
ls -la docs/ ai/
git log main --oneline -50
```

Plus all PRs + all issues via the GitHub MCP tools.

### Step 2 — Read carefully

Especially:

- `ai/handoff.md` or any session-handoff doc.
- `ai/REQUIREMENTS.md`, `ai/DESIGN.md`, or equivalents — distinguish shipped vs. specified.
- Every `*.tf` file: which resources are real vs. which directories are empty/stubbed.
- `docs/operations.md` — note any stale links (this is a known pattern in this repo).

### Step 3 — Classify each piece of work

| Classification | Definition |
|---|---|
| **Shipped** | Code merged AND an apply / run / e2e test has confirmed it works. |
| **Plan-green** | Code merged, `terraform plan` (or equivalent dry-run) succeeds, but no real-world execution. |
| **Designed** | A spec/ADR/requirement exists but no code. |
| **Stubbed** | Directory or scaffolding exists with no real content. |
| **Not started** | Mentioned in plans only. |

Use these terms throughout. Cite PR numbers (`#N`) for shipped/plan-green claims. Cite the spec file path for designed claims.

### Step 4 — Identify blockers

A blocker is something **specific** that prevents the next named milestone. Not "we need to test more". Examples:

- "Iteration 1 apply has never been observed to succeed end-to-end against the sandbox — handoff §X."
- "Iteration 5 cannot proceed until Cognito groups are added to `terraform/base/cognito.tf`."

For anticipated blockers, reason from constraints documented in the repo (sandbox quotas, IAM caps, rate limits, etc.).

### Step 5 — Write the document

Apply all Mermaid escaping rules from `tell-me-what-this-does`'s spec (no literal `|` inside node labels).

### Step 6 — Render-verification preflight

```bash
awk '/^```mermaid/,/^```$/' "$OUT" \
  | grep -nE '\[[^][]*\|[^][]*\]' && exit 1 || true
```

### Step 7 — Save and report

Write to `$OUT`. Report back to parent: path, line count, blocker count (current + anticipated), 5-line summary.

## Concrete examples

### Example 1 — Mid-iteration project (this repo on 2026-05-17)

`tell-me-where-we-are` produced `summary/status-2026-05-17.md`: 7 iterations (0 shipped; 1 plan-green; 2–6 designed). 6 current blockers (B1–B6), chief being "Iter 1 apply never observed". 9 anticipated future blockers (F1–F9) reasoned from Pluralsight sandbox 4-hour session limit and 9-instance cap.

### Example 2 — Greenfield repo

If nothing has shipped: §1 scorecard shows "Not started" for everything, §6 blockers list lists the first one (probably "no CI workflow yet"), §9 recommended sequence proposes the first three actions. Length will be shorter than this repo's status doc; that's fine. Don't pad.

## Anti-patterns

- **Conflating shipped with plan-green.** This repo had a real instance where the status doc claimed cert-manager was installed because it appeared in the design doc. The actual Helm release set didn't include it. Always check the implementation, not the spec.
- **Listing vague blockers.** "Need more testing" is not a blocker. "Iter 1 apply has never run end-to-end against a real AWS account — see handoff §X" is.
- **Skipping the render-verification preflight.** Same lesson as `tell-me-what-this-does`.
- **Padding the anticipated-blockers section with hypotheticals.** Each F-row must trace to a documented constraint.
- **Refusing to say "Not started" when that is the truth.** Don't soften.

## Acceptance criteria

1. Output file ≥ 300 lines and ≥ 5 Mermaid diagrams.
2. Every iteration / milestone mentioned in `ai/` or `docs/` appears in the scorecard.
3. Every blocker row cites a file path, PR number, or specific source.
4. Render-verification preflight passes.
5. The "Recommended immediate sequence" section has at most 3 numbered actions.

## Files this skill creates / modifies

- `summary/status-{UTC_DATE}-{HASH}.md` — written fresh (overwritten if exists).
