# Spec: `subagent-log-extraction`

- **ID**: SKILL-SPEC-8afdbefab5
- **Source retrospective**: ../2026-05-25-70.md

## Intent

When a CI log returned by a tool call exceeds ~50 KB (the context-budget threshold above which inlining the log destroys the agent's working memory), delegate analysis to a subagent with a precise extraction brief instead of reading it inline. Provides the brief template: jq query for the envelope, target section headers, verbatim strings to quote, word cap, expected verdict format. Pairs with the existing `subagent-prompting` reference card.

## Trigger

**Direct trigger phrases**: "analyze this log", "what does this CI log show", "extract findings from this workflow log", "summarize this diagnose output".

**Proactive triggers** (offer without being asked):

- A tool call returned the saved-to-file message: `Error: result (N characters) exceeds maximum allowed tokens. Output has been saved to <path>`.
- The agent has just fetched job logs via `mcp__github__*` and the output stream is >50 KB.
- The agent has just run `jq` / `cat` on a file that produced >2000 lines of stdout.

**Negative triggers** (do NOT activate):

- Logs ≤50 KB — read inline, the orchestration overhead isn't worth it.
- Logs the agent intends to grep for a single known string (use `grep -nE … | head -20` directly).
- Logs that are structurally JSON-only with no human-readable section — use `jq` queries inline.

## Inputs

- A path to the log file (typically under `/root/.claude/projects/.../tool-results/` or `/tmp/`).
- The JSON schema if the log is wrapped (most MCP tool results are `{result: {success: bool, output: string}}` where `output` is the actual log).
- A list of extraction targets — section headers, error markers, status strings — supplied by the briefing agent.

## Outputs

- A subagent reply containing 300–600 words of quoted evidence and a one-sentence verdict.
- Optionally a `/tmp/<name>.log` extracted plain log file for further direct inspection by the main agent.

## Workflow

1. **Verify size**: `wc -c <path>` or count from the tool-result error message. If <50 KB, skip — read inline.
2. **Identify the envelope**: most MCP tool results are `{result: {success: bool, output: string}}`. The body lives in `.result.output` and is a single quoted string (multi-line, escape-encoded). For these, the canonical extraction is `jq -r .result.output <path> > /tmp/<name>.log`.
3. **Compose the subagent brief** from this template:
   ```
   <One-sentence task statement: "Verify whether X" or "Root-cause Y".>
   
   Input log: <path>
   Schema: {result: {success: bool, output: string}}.  
   Extract with: jq -r .result.output <path> > /tmp/<name>.log; then grep/sed.
   
   Background: <2–4 sentences naming the bug class, the prior diagnose run, what the agent is verifying.>
   
   What to extract (verbatim where possible, under N words total):
   1. <Target section header 1 from the workflow log> — what to quote.
   2. <Target section header 2> — what to quote.
   ...
   K. **Verdict (one sentence)**: <the question the subagent must answer>.
   
   Use jq probing first (jq 'type, length, keys?') to confirm the schema. Quote AWS / Crossplane / kubectl error strings verbatim — exact strings drive the next fix.
   ```
4. **Dispatch via the Agent tool** with `subagent_type: general-purpose` (or a more specific type if available — e.g., `Explore` for read-only file lookups; this skill targets the catchall case).
5. **Read the subagent's reply**. It should contain quoted evidence + a verdict. If it has paraphrased instead of quoted, send a follow-up message asking for verbatim quotes.
6. **Use the quoted evidence to drive the next fix.** Cite the run URL, the section header, and the verbatim line in any commit / PR description that follows.

## Concrete examples

### Example 1 — composite-not-Ready root-cause (from this session)

After dispatching `phase-2-diagnose.yml` run 26353150253 and downloading the job log via `mcp__github__*` (166,159 chars — exceeded the inline limit), the saved file lived at `/root/.claude/projects/.../tool-results/mcp-…-1779601521568.txt`.

Brief sent to the subagent (excerpt):

> Investigation task: root-cause why the Crossplane composite XR for a PlatformSecret claim never reaches Ready=True…
> 
> Input: GitHub Actions job log at /root/.claude/projects/…/mcp-…-1779601521568.txt
> 
> The file is JSON with schema `{result: {success: bool, output: string}}`. Probe first with `jq 'type, length, keys?'`, then extract with `jq -r .result.output > /tmp/diag.log`.
> 
> What to extract:
> 1. **XR `.status.conditions`** — verbatim. Synced and Ready, with reason and message.
> 2. **For each XR-owned managed resource (ASM Secret + ExternalSecret), its status block** — verbatim. Did the ASM Secret get a real AWS ARN? If not, why?
> 3. **Events** — Warning events in the probe namespace naming the XR.
> 4. **Provider state** — was provider-aws-secretsmanager Healthy=True?
> 5. **Synthesis** — single root cause of the composite never going Ready, one sentence followed by 2–3 sentences of evidence quoted from the log.
> 
> Under 600 words. Quote verbatim where it matters.

The subagent's reply identified the IRSA SA-name mismatch as the root cause with three quoted log lines as evidence. That diagnosis drove PR #66.

### Example 2 — IRSA-fix verification (from this session)

After the IRSA fix was applied, a second `phase-2-diagnose` run (26355033199) produced another ~170 KB log. The verification brief named six specific extraction targets:

1. PlatformSecret claim `status.conditions` (did it go Ready=True?)
2. XR `.status.conditions` (does the XR have any conditions yet?)
3. ASM Secret managed resource (was `status.atProvider.arn` populated?)
4. ExternalSecret (was it created?)
5. `upbound-provider-family-aws` SA (does `kubectl get sa` succeed?)
6. Bottom-line verdict.

The subagent's reply: **partial success**. The SA name pin landed, but the running provider pod was still mounted on the OLD hash-suffixed SA. That finding drove PR #68.

## Anti-patterns

- **"Summarize this log".** Paraphrases lose the exact strings the next fix depends on. Always brief with extraction targets and "quote verbatim".
- **Reading the log inline anyway.** Even at 50 KB, the structural noise crowds out reasoning. Delegate.
- **Skipping the schema probe**. Different MCP tools wrap logs differently (some are `{output: …}`, some are `{result: {output: …}}`, some are raw text). A `jq 'type, length, keys?'` at the start saves the subagent from extracting from the wrong key.
- **Asking the subagent for a fix.** This skill's job is evidence extraction; the main agent reasons over the evidence and decides the fix. Mixing the two roles tempts the subagent into speculation.

## Acceptance criteria

1. Every log >50 KB this session is processed through a subagent brief, not inlined.
2. Subagent replies contain verbatim quotes (with line refs or section headers) rather than paraphrases.
3. The main agent's next action quotes the subagent's findings in the commit / PR description.
4. The brief template above is followed; deviations are documented.

## Files this skill creates / modifies

- No persistent files written by default.
- Optionally writes `/tmp/<name>.log` (extracted plain-text body) for the subagent and the main agent to both reference.
- The brief itself is composed inline as the Agent tool prompt.
