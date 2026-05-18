# AGENTS.md suggestions — 2026-05-17-13

These are proposed additions to the project's agents file (in this repo: `CLAUDE.md`). Each section contains:

1. **Proposed addition** — the exact text to paste.
2. **Why this earns its place** — the argument grounded in this session.

Decide each on its own merits.

---

## Suggestion 1: Always render-verify Mermaid before declaring docs work done

### Proposed addition

> **Mermaid render check.** For any document containing Mermaid diagrams, run a literal-`|`-inside-node-label check before committing:
>
> ```bash
> awk '/^```mermaid/,/^```$/' <file> | grep -nE '\[[^][]*\|[^][]*\]' && echo FAIL || echo OK
> ```
>
> If the check fails, replace the literal `|` with `/` or `&#124;`. The `-->|edge label|` syntax is fine; only node labels (`[…]`, `(…)`, `{…}`) are affected. This applies whether or not the document is also being fact-checked by another reviewer — fact-checking does not catch rendering failures.

### Why this earns its place

PR #12 in this repo shipped two unrendered diagrams that read `Parse error on line 2: ... got 'PIPE'` when viewed on GitHub. The fix (PR #13) was a 2-character change per diagram. Three rounds of fresh-context fact-checking reviewers saw the markdown source but never the rendered diagram, so the bug survived the entire review loop and shipped to `main`. Adding this check costs one `awk | grep` per file and turns "user notices broken diagram in browser" into "skill notices it before push". Marginal cost: 50 ms; marginal saving: one PR round-trip.

---

## Suggestion 2: Worktree isolation is the default for any multi-file subagent

### Proposed addition

> **Worktree isolation for parallel writers.** Any subagent expected to produce or modify files runs under `isolation: "worktree"` unless there is a specific reason to share the working tree. This applies to research agents (which produce reports), generation agents (which produce code), and any fan-out pattern. Reviewers that only read files do not need a worktree.

### Why this earns its place

The session that produced PR #12 dispatched two research subagents in parallel and avoided every file-collision risk by giving each its own worktree. The orchestrator then merged the artifacts. Without worktrees, two agents writing to `summary/` simultaneously would have clobbered each other or produced ambiguous diffs. The cost of `isolation: "worktree"` is one extra parameter on the `Agent` call; the saving is one entire class of "we got intertwined writes" debugging.

---

## Suggestion 3: Fresh-context review requires explicit severity discipline

### Proposed addition

> **Severity labels in review loops.** Any review-loop subagent must be required to label each finding `major` (would mislead a reader), `minor_factual` (small wrong detail), or `cosmetic` (style/wording). Round 1 may include cosmetics. Round 2+ must skip cosmetics entirely. Termination condition: zero `major` AND zero `minor_factual` findings.

### Why this earns its place

A fresh reviewer can always find one more wording preference. Without severity discipline, the review loop has no terminal state and runs forever — or burns out the orchestrator's context. This session terminated cleanly in 3 rounds (15 → 6 → 0 findings) because round 2 onward was told "no cosmetics". The exact same loop without that discipline would have spent rounds 4-7 arguing about commas.

---

## Suggestion 4: Orchestrator dual-verifies every `major` finding before editing

### Proposed addition

> **No edits on reviewer's say-so alone.** When a review-loop subagent returns a `major` finding, the orchestrator must independently verify the claim (one-line `grep`, `ls`, `wc`, or API call) before applying the suggested fix. Verification command and result go in the run-log alongside the finding.

### Why this earns its place

Round 1 of the PR #12 review loop flagged "cert-manager is not installed in terraform/management". The orchestrator ran `grep -E '^resource "helm_release"' helm.tf` and confirmed 4 entries (no cert-manager) before editing. If the reviewer had been wrong, the orchestrator's edit would have introduced a regression in the *opposite* direction. This is the single highest-leverage step in the loop: one extra tool call per major finding, vs. silently shipping reviewer-induced errors. The run-log paper-trail also lets a future human auditor see exactly what was verified.

---

## Suggestion 5: Treat the user's "finalized PR" instruction as overriding any default

### Proposed addition

> **PR finalization is user-driven.** The default rule for newly-opened PRs is `draft: true`. When the user explicitly says "make it a finalized PR" or "open as ready-for-review", set `draft: false`. Do not apologize, do not negotiate — the user has supplied the override they have authority to supply.

### Why this earns its place

This session had an unnecessary moment of hesitation when the user said "make it a finalized PR" while the global rule says "create as draft". The right behavior is to obey the user; the rule exists to handle the *un-instructed* case. Codifying this prevents the orchestrator from re-litigating the same point in future sessions.

---

## Suggestion 6: `pending` PR status with `total_count: 0` is not a failure

### Proposed addition

> **Empty `pending` CI status.** When `mcp__github__pull_request_read get_status` returns `state: "pending"` and `total_count: 0`, this means **no CI check has registered itself**, not that a check is in progress and failing. For repos with branch-prefix-gated CI (`test/**` only, etc.), this is the expected result on docs branches. Do not report it as red.

### Why this earns its place

This session twice queried the PR status, saw `pending` + 0 checks, and had to reason from CLAUDE.md's branch policy that this was expected (the CI workflow only auto-triggers on `test/**`). A future agent looking at the same response without that context would likely escalate it as a CI failure. Adding this rule converts a mini-debug-session into a one-line read.

---

## Suggestion 7: Filename hash anchors the artifact to a commit, not a date

### Proposed addition

> **Commit-hash-anchored summary artifacts.** All files written under `summary/` must include the short commit hash in the filename (`summary/{kind}-{date}-{hash}.md`). When regenerating, **never overwrite a file with a different hash** — write to the new hash-anchored name instead. Files with different hashes are different artifacts about different repo states. Consistency between two same-hash artifacts is restored by the consistency review loop (`tell-me-about-this-repo`), not by silent in-place edits.

### Why this earns its place

The session produced `summary/functionality-2026-05-17.md` without a hash, which is fine for a one-shot doc but breaks the upstream `idea-pipeline#16` spec and makes it impossible to tell, three months from now, which commit a given summary describes. Hash-anchoring is also what makes the consistency loop tractable: the loop *can* assume both files describe the same repo state because the filenames assert it. Cost: 8 extra characters in the filename.

---

## Suggestion 8: A run-log is part of the deliverable, not an afterthought

### Proposed addition

> **Run-log requirement for review loops.** Any multi-round review loop must produce a `summary/run-log-{date}-{hash}.md` (or equivalent) recording: round number, reviewer's verdict, each finding's severity, the orchestrator's verification command + result, the edits applied. The run-log is committed alongside the artifact and included in the PR. No run-log → the loop didn't happen, factually.

### Why this earns its place

In this session, the user explicitly asked for the run-log. Without it, the multi-round process is invisible to a reviewer: the merged squash-commit shows three rounds of edits collapsed to one diff, and the rationale is gone. The run-log preserves the audit trail across squash-merges and gives the user the per-round detail they asked for ("how did each round go?"). The marginal cost is a few minutes of writing per round, paid by the orchestrator, not the user.

---

## Suggestion 9: Cap review loops at N rounds with an explicit STUCK signal

### Proposed addition

> **Bounded review loops.** Review loops terminate after at most 5 rounds. If round 5 is still not `clean`, the orchestrator writes a `STUCK` block to the run-log naming the unresolved findings and stops. The user decides whether to continue. Loops MUST NOT silently run more than 5 rounds.

### Why this earns its place

This session converged in 3 rounds, but a less converging document could plausibly oscillate. A bounded loop with an explicit failure mode protects the user from a runaway agent burning credits on cosmetic disagreements, and gives them a clear decision point ("here are the 4 things we can't agree on, you decide").
