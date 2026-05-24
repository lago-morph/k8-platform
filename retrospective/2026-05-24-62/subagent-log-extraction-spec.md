# Spec: `subagent-log-extraction`

## Intent

When a tool result is too large for the parent agent's context (the harness saves it to a file path), spawn a subagent in fresh context to extract findings. The subagent reads the full file, applies targeted queries (jq / python / regex), and returns a focused summary with verbatim quotes. The parent agent never loads the giant log.

Grounded in: phase-2-diagnose run 26348711132 produced a 155K-char log. Loading it would have blown the context window. A subagent with explicit instructions ("schema, target questions, length cap") returned a 1200-word root-cause analysis with verbatim error messages. Bug 4's root cause was identified in one subagent call.

## Trigger

**Proactive triggers (skill activates automatically):**
- Tool result exceeds the parent's max-tokens and gets saved to a file
- The agent needs to extract findings from a log >30K chars
- Multiple targeted greps would consume many turns

**Negative triggers:**
- Log small enough to read directly (just use `Bash` with grep / head)
- Need is a single field lookup (just use `jq`)

## Inputs

- The absolute file path to the saved tool result
- The file's schema (e.g., `{result: {success: boolean, output: string}}` for jentic)
- The specific questions to answer (the more specific, the better the extraction)
- Output format expectations (length cap, structure)

## Outputs

- A subagent response containing:
  - Direct answers to the questions, ordered
  - Verbatim quotes of relevant log lines (not paraphrases)
  - Severity / confidence rating per finding
  - Optional: "needs more investigation" flag if cause unclear

## Workflow

1. **Identify the file path** from the tool error message ("Output has been saved to /root/.claude/projects/.../tool-results/<hash>.txt").
2. **Identify the schema** the giant log is wrapped in (jentic uses `{result: {success, output}}`; ext-github differs; raw kubectl logs are flat strings).
3. **Frame the questions specifically.** Bad: "summarise this log." Good: "what's the message in `status.conditions[?(@.type=="Synced")].message` for the diag-probe-claim XR?"
4. **Dispatch a subagent** (Agent tool, subagent_type=general-purpose) with the prompt template below.
5. **Quote the subagent's findings in the agent response** — don't paraphrase. The subagent already did the verbatim extraction.

### Prompt template

```
Extract diagnostic findings from a large saved tool result.

File: <absolute path>
Schema: <e.g. {result: {success: boolean, output: string}} — log content is a giant string at .result.output>

To read: jq -r '.result.output' <file> | head -N, OR python to chunk further.

Goal: find the answers to <N> specific questions. Quote exact log lines verbatim.

**Question 1**: <specific question with the YAML path / log substring to look for>
**Question 2**: <…>
**Question 3**: <…>

For each question:
- Quote the exact log lines that answer it
- Mark confidence: high / medium / "needs more investigation"
- If the answer requires multi-line context, include 2-5 surrounding lines

Report under <K> words. Be explicit about what's NOT found if the log doesn't answer a question.
```

## Concrete examples

### Example 1 — the actual session call (phase-2-diagnose 155K-char log)

**Prompt:** (paraphrased) — file path, jentic schema, three specific questions about Bug 3 (Application sync diffs), Bug 4 (probe claim status), and IRSA annotations.

**Subagent output:** root-caused both bugs in <1500 words with verbatim quotes:

> Bug 4 evidence: `cannot compose resources: pipeline step "patch-and-transform" returned a fatal result: invalid Function input: resources[0].patches[0].transforms[0].string.type: Required value: string transform type is required`

The parent agent then used that quote to find the 9 missing transforms across 2 Composition files and ship the fix as PR #61.

### Example 2 — chainsaw failure log extraction (multiple times this session)

Each chainsaw failure produced an 80K-char log. The pattern:

1. Identify file path.
2. Prompt: "find the failing scenario name and the exact ERROR line under it; quote the chainsaw `=== ERROR` block verbatim."
3. Subagent returns the scenario + error block.
4. Parent uses it to identify whether the error is a code regression or transient infra.

## Anti-patterns

- **Use the parent agent's Bash + grep on the saved file directly.** Works for small queries (`grep -c FAIL`), fails when the answer requires multi-paragraph context.
- **Use ToolSearch on the saved file.** ToolSearch is for tool discovery, not log mining.
- **Vague prompts.** "Summarise the log" produces summaries that miss the specific evidence. Always name what you're looking for.
- **No length cap.** Subagent will produce a 5K-word essay. Cap at 1500 words.
- **Trusting the subagent's interpretation without re-reading the quotes.** The subagent should quote verbatim; the parent should sanity-check that the quote actually supports the conclusion.
- **Re-spawning a fresh subagent for follow-up questions.** Use `SendMessage` to continue the same subagent — it already has the file in context.

## Acceptance criteria

1. The parent agent's context never loads the giant log directly.
2. The subagent's response contains verbatim quotes, not paraphrases.
3. The parent agent's user-facing response quotes the subagent's quotes (with attribution if useful).
4. The subagent's response stays under the requested word cap.
5. Follow-up questions on the same log use SendMessage to the same subagent, not a fresh one.

## Files this skill creates / modifies

- No file modifications. This is a procedural skill governing Agent tool invocations.
