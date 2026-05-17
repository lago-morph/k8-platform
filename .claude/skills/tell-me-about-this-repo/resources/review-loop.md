# Fresh-context consistency review loop

This document describes the inner-loop procedure used by `tell-me-about-this-repo` to bring two summary documents into factual agreement. The procedure is self-contained: a fresh-context subagent given only this file and the two files under review should be able to execute one round.

## Inputs

- `summary/functionality-{DATE}-{HASH}.md`
- `summary/status-{DATE}-{HASH}.md`
- `summary/run-log-{DATE}-{HASH}.md` (created if missing)
- Repository working tree at HEAD
- GitHub MCP tools, restricted to the current repo
- The current round number `N`

## Per-round procedure

### 1. Dispatch a fresh reviewer

Use the `Agent` tool with `subagent_type: "general-purpose"`. **Never `SendMessage`** — fresh context is the entire point.

The reviewer's brief MUST include:

- Paths to both files under review.
- Source-of-truth artifacts to consult: repository tree + GitHub API via `mcp__github__*`.
- Severity-label rules:
    - `major` — wrong claim that would mislead a reader (always reportable).
    - `minor_factual` — small wrong detail (date off by a day, wrong file count, wrong line number).
    - `cosmetic` — wording, formatting, missing-diagram opinions.
- Round number `N`.
    - If `N == 1`: cosmetic findings are allowed.
    - If `N >= 2`: cosmetic findings MUST be omitted. The reviewer is told this explicitly.
- The required output format (see below).
- Cap of ~20 findings per round.

### 2. Reviewer output format

Reviewer returns a single JSON object inside a ```json fenced block:

```json
{
  "verdict": "clean" | "needs_fixes",
  "findings": [
    {
      "id": "F1",
      "severity": "major" | "minor_factual" | "cosmetic",
      "file": "functionality-{DATE}-{HASH}.md" | "status-{DATE}-{HASH}.md" | "both",
      "location_hint": "section title or line range",
      "claim": "the exact claim the doc makes",
      "reality": "what the source actually says",
      "evidence": "file path, PR #, or other concrete pointer",
      "suggested_fix": "exact text change to make"
    }
  ],
  "summary": "one-paragraph summary"
}
```

Verdict is `clean` iff there are zero `major` and zero `minor_factual` findings (cosmetic-only counts as clean for termination).

### 3. Orchestrator verification (mandatory for `major` findings)

For each `major` finding the reviewer returns:

1. Run a one-line verification command targeting the cited evidence (`grep`, `wc -l`, `ls`, or a GitHub MCP call).
2. Append the verification command and its result to the run-log.
3. If the verification confirms the reviewer's claim → proceed to apply the fix.
4. If the verification contradicts the reviewer → log "reviewer wrong; no edit" and skip.

For `minor_factual` findings, verification is recommended but not strictly required; apply judgment based on how concrete the cited evidence is.

### 4. Apply fixes

Use `Edit` for surgical changes. Both files may need edits — that's fine; that's the whole point of the loop.

### 5. Commit and update run-log

```bash
git add summary/
git commit -m "docs(summary): apply round-N fact-check fixes"
```

Run-log entry for round `N`:

```markdown
### Round N — verdict: `<verdict>` (<count> findings: <major>m / <minor>mf / <cosmetic>c)

| # | Sev | File | Claim flagged | Verification | Resolution |
|---|-----|------|---------------|--------------|------------|
| F1 | major | status | <claim> | `<command>` → <result> | <edit applied / reviewer wrong / skipped> |
| ... |
```

After the table, one paragraph of orchestrator commentary on what this round revealed.

### 6. Terminate or continue

- If `verdict == clean` → loop terminates. Write a final "Phase 3 — Termination" section to the run-log summarizing total rounds, total findings, regressions (if any).
- If round count reaches 5 and the loop is still not clean → write a `STUCK` block to the run-log listing each unresolved finding, then stop. The user decides whether to continue.

## Reviewer brief template

Paste this into the `prompt` parameter of the fresh `Agent` call, substituting the variables:

> You are an independent fact-checker reviewing two summary documents about the `{OWNER}/{REPO}` repository. You have NO prior context — read fresh and find inconsistencies.
>
> # Files under review
> - `/home/user/{repo}/summary/functionality-{DATE}-{HASH}.md`
> - `/home/user/{repo}/summary/status-{DATE}-{HASH}.md`
>
> # Source-of-truth artifacts
> - The repository at `/home/user/{repo}/`
> - GitHub MCP tools restricted to `{OWNER}/{REPO}`
>
> # What to look for (in priority order)
> 1. **Cross-document contradictions** between the two summary docs.
> 2. **Factual errors vs. the source** (PR numbers, dates, file paths, secret names, line counts, "done vs. designed" claims, counts of things).
> 3. **Internal contradictions** within a single doc.
> 4. **Stale or impossible claims** (files/PRs/secrets that don't exist).
>
> # Strict rules for this pass
> - **Round number: N. {Include if N≥2: "Cosmetic findings are NOT permitted in this round."}**
> - IGNORE wording, tone, formatting, missing-diagram opinions, and anything that wouldn't mislead a reader.
> - Verify a claim before flagging it. For any claim you flag, cite the source-of-truth contradiction.
> - Cap findings at ~20.
>
> # Output (return as your final reply, nothing else)
> A single JSON object in a ```json fenced block matching the schema in `review-loop.md`.
>
> # Constraints
> - Do NOT edit either document; do NOT push commits.

## Anti-patterns

- **`SendMessage` to a prior reviewer.** Defeats the entire fresh-context premise.
- **No verification on `major` findings.** Lets a wrong-but-confident reviewer mutate the doc.
- **No round cap.** A loop without a cap is a runaway.
- **No severity discipline past round 1.** Loop never terminates.
- **No run-log entries.** No paper trail after squash-merge.
