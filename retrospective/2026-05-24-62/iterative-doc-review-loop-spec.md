# Spec: `iterative-doc-review-loop`

## Intent

For long-form prose documents that must be load-bearing (handoffs, RFCs, specs, plans), one pass is not enough. Run iterations of `subagent review + self review → consolidate findings → fix → re-review` until a fresh pass surfaces no major or factual errors. Most documents stabilize in 2–4 iterations.

Grounded in: the user asked for at-least-3 iterations of review on the handoff rewrite (PR #62). Iteration 1 found 12 issues. Iteration 2 verified those fixed and found 11 new ones. Iteration 3 found 5 medium-or-higher and confirmed convergence. The final doc was materially better than what 1 pass would have produced.

## Trigger

**Direct user phrases:**
- "Review the doc"
- "Double-check the handoff"
- "Iterate on this"
- "Is the doc internally consistent?"

**Proactive triggers:**
- About to commit a long-form planning/handoff/spec document (>200 lines)
- A document that will be read by a fresh-context agent (the next session)
- After substantial multi-section edits on a load-bearing doc

**Negative triggers:**
- Short docs (<100 lines) — one careful pass is enough
- Drafts not yet stable enough to review

## Inputs

- The document path
- Specific concerns the user named (if any)
- Number of iterations (default: 3; minimum: 2)

## Outputs

- A revised document with cross-iteration findings applied
- A short summary per iteration: findings count by severity, fixes applied
- Final-iteration report: what remains, would another loop help

## Workflow

For each iteration N:

1. **Spawn a subagent** with this brief (template below). Crucially: the prompt names previous-iteration findings as "verify FIXED / PARTIAL / STILL-BROKEN" so we can detect regressions.

2. **In parallel, do a self-review.** Re-read the agent's own edits with fresh eyes. Look for things the subagent might miss (agent's stylistic patterns, cross-file consistency, semantic correctness against your own session knowledge).

3. **Consolidate findings.** Dedupe between subagent and self-review. Classify by severity (HIGH / MEDIUM / LOW). Identify which to fix this iteration.

4. **Apply fixes.** Use Edit tool calls per finding. Quote the old text and the new text for traceability.

5. **Decide: another iteration?** Stop conditions:
   - All findings <= LOW AND no factual errors → stop
   - User specified N iterations → run exactly N
   - Two consecutive iterations surface zero MEDIUM+ findings → stop

### Subagent prompt template

```
Critical review pass #<N> on <doc path>. The author has applied <N-1> rounds of fixes. Find any remaining bugs.

Scope: <named sections>.

Previous-iteration findings to verify (label each FIXED / PARTIAL / STILL-BROKEN, quote evidence):
- <finding 1>
- <finding 2>
- ...

Look for NEW issues, especially:
- <specific concern 1 from the user>
- <specific concern 2>
- <specific concern 3>

For each finding output:
- Severity: HIGH / MEDIUM / LOW
- Where: line range or section name
- What: concrete description
- Suggested fix: precise edit text

Report under <K> words. Quote exact lines.
```

## Concrete examples

### Example 1 — the handoff review (the actual session)

Iteration 1 subagent prompt named 7 specific concerns (mode= contradiction, secrets prerequisite, log evidence criteria, Bug 3 fields, chainsaw ESO caveat, §6.6 contradiction, route53 verification command). Surfaced 12 findings. All fixed.

Iteration 2 prompt named those 12 as "verify FIXED" + asked for new issues with 7 new concerns. Verified 10 of 12 fixed (2 PARTIAL acceptable), surfaced 11 new findings — including a HIGH (Bug 4 warning too late in Step 0).

Iteration 3 prompt named those 11 as "verify FIXED" + asked for new issues with 10 new concerns. Verified all 11 fixed, surfaced 6 (mostly LOW, 2 MEDIUM, 1 HIGH about pull_request_read being read-only). All fixed.

Final report:
- 22 distinct issues found and fixed across 3 iterations
- Iteration 3 surfaced no factual errors and no MAJOR findings
- Would another loop help? Probably not — the remaining LOW items were judgement calls or out-of-scope edits to other files

### Example 2 — workflow for a new RFC (hypothetical)

Same skill, 3 iterations, prompt sequence:

1. Iteration 1: "Find ambiguity, contradiction, under-specification" + RFC-specific concerns (does the proposed migration name a rollback path? Does it specify error handling?).
2. Iteration 2: verify iteration-1 findings + look for "test plan", "security considerations", "cross-team impact".
3. Iteration 3: verify all + look for "anything a reviewer in 6 months would ask".

## Anti-patterns

- **Single-pass review.** The first pass catches obvious things. The second pass catches things the first agent missed because they were anchored on the first pass's findings. The third pass catches things only stable after the first two passes.
- **No previous-finding verification in iteration N's prompt.** Without it, you can't detect regressions where iteration N-1's fix broke something.
- **Subagent only, no self-review.** Subagents miss agent-specific patterns and cross-document consistency. Self-review catches those.
- **Apply fixes incrementally without consolidation.** Each finding might fix one line but break another. Consolidate first, then apply.
- **No stop condition.** Loop forever. Define convergence (no MEDIUM+ findings in 2 consecutive passes).
- **Apply only HIGH findings, defer MEDIUM and LOW to "next iteration."** They don't get done. Apply all findings the loop produces unless they're out-of-scope edits to other files.

## Acceptance criteria

1. At least 2 iterations per long-form doc, regardless of how confident the agent feels after iteration 1.
2. Each iteration's subagent prompt explicitly names the previous iteration's findings for re-verification.
3. Each iteration produces a written list of findings with severity tags.
4. The loop terminates with an explicit "would another loop help?" judgement.
5. The final doc has zero factual errors and zero unresolved HIGH findings.

## Files this skill creates / modifies

- The document under review (multiple Edit calls per iteration)
- (Optional) `<doc>-review-log.md` — a session-local log of findings per iteration, useful for retros
