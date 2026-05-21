# Spec: `fenced-read`

## Intent

When the user tells you to read part of something — "only the problem
section", "ignore the proposed solution", "skip the test plan", "the
comment but not the issue body" — the available tools usually don't
support that scope natively. `mcp__github__issue_read` returns the
whole body. `Read` returns the whole file unless you supply line
offsets. `WebFetch` returns the whole page.

The naive path is to read everything and "ignore" the disallowed
parts mentally. **This is the path that produced the central failure
of the session that gave us PR #20.** I read the full issue body
including a rejected proposed-solution and the acceptance criteria the
user explicitly fenced out, and within two turns I was quoting that
material verbatim in my own findings. The user's context — the one
they had spent the session building — was no longer usable, because
mine had been silently contaminated under it.

This skill exists to enforce the constraint at the tool-call boundary
rather than at the cognitive boundary. Cognitive discipline against a
loud distraction is unreliable; mechanical scope-limiting is not.

## Trigger

**Direct triggers — activate when the user says:**

- "Read only X", "read just X", "look only at X", "the X section but
  not Y".
- "Don't read Y", "skip Y", "ignore Y", "leave out Y".
- "Don't get polluted by Y", "Y is rejected / superseded / not in use".
- "Just the problem statement", "just the conclusion", "just the diff",
  etc., when the source contains more than that.

**Proactive triggers — activate without being asked when:**

- You're about to read an issue, PR, or comment that includes both a
  Problem and a Proposed Solution and the user has only asked you to
  reason about one of them.
- A previously-rejected design is in scope to read but should not be.
- You're handing material to a subagent and one section is rejected
  but the others aren't.

**Negative triggers — do not activate when:**

- The user has explicitly said "read everything" or "read the full
  body" or "I want you to see the rejected one too so you understand
  the contrast."
- The source is small enough that scope-limiting offers no real
  protection (e.g., a three-line comment).

## Inputs

- The constraint: what's allowed, what's fenced out, in the user's
  exact phrasing.
- The target: a file path, an issue number, a PR number, a URL.
- The tool you'd normally use, plus its known return scope.

## Outputs

- A read whose scope is no broader than the constraint allows.
- If that's impossible, an explicit ask to the user with options.
- An acknowledgment line in your response confirming you understood
  the fence.

## Workflow

1. **Restate the constraint in one sentence.** "You've asked me to
   read only the Problem section of #18 and not the Proposed Solution
   or anything beneath it." If you can't restate it cleanly, you don't
   understand it yet — ask.

2. **Check tool scope.** For each tool you might use, ask: can this
   tool honor the constraint at the boundary?

   - `Read` with `offset` and `limit`: yes, if you know the line range.
   - `Grep` with line bounds: yes, for line-based extractions.
   - `mcp__github__issue_read` with `method="get"`: **no** — returns
     full body.
   - `WebFetch`: usually no — returns full page.

3. **If a tool can honor it, use the scoped form.** Spell out the
   scope: `Read` with `offset=12 limit=40`, `Grep` with `head_limit`
   plus a delimiter pattern.

4. **If no tool can honor it, build a post-processing pipeline.** Run
   the tool, but pipe through `awk` / `sed` / `head` immediately, in
   the same Bash call, so the disallowed content never enters your
   reasoning. Example:

   ```bash
   # Extract just the Problem section from an issue body file
   awk '/^## Problem/,/^## Proposed/{if(!/^## Proposed/) print}' issue-body.md
   ```

   The full body lands in a file or pipe; only the extract reaches you.

5. **If no pipeline is workable, ask the user.** Offer three options:
   - (a) "You paste the allowed section into chat, I'll work from that."
   - (b) "I read the full body, accept the risk, and flag the fenced
     sections explicitly in my output."
   - (c) "We skip this read."

   Do not pick (b) unilaterally. The user owns the risk decision.

6. **In your response, acknowledge the fence before any analysis.**
   "Read only the Problem section per your instruction; the Proposed
   Solution and ACs are fenced out." This forces you to register the
   constraint in your output, not just your input.

7. **Do not quote fenced content anywhere.** Not in your findings,
   not in subagent briefs, not in "already-covered" lists, not as
   contrast ("unlike the proposed solution which said X"). The leak
   doesn't have to be in your reasoning text — encoded in a list of
   "things already covered" it still flows downstream.

## Concrete examples

### Example 1 — what happened (negative example)

User: "read just the problem section from the body of the issue. Do
not read more than the problem section."

Wrong path (what I did):

```
Agent → mcp__github__issue_read(method="get")  →  full body in context
Agent → reasoning that quotes "no new secrets, no GitHub App, no PAT"
        (a phrase from the fenced Proposed Solution)
```

Right path:

```
Agent → mcp__github__issue_read(method="get")  →  full body returned
       (pipe immediately through awk to extract just §Problem)
Agent → Bash:
        gh-mcp returns blob → save to /tmp/issue-body.md →
        awk '/^## Problem/,/^## Proposed/{if(!/^## Proposed/) print}'
Agent → only §Problem text reaches reasoning
```

Or, if the tool can't be wrapped that way:

```
Agent → reply to user:
        "The MCP tool returns the full body; it can't scope at the
        section level. Options: (a) paste the section here, (b) I
        read full body and flag the fenced parts explicitly, (c)
        skip the read."
```

### Example 2 — a PR with a long test plan

User: "read this PR's description but ignore the test plan."

```
Agent → mcp__github__pull_request_read(method="get") → full body
        (pipe immediately through awk to drop everything after "## Test plan")
Agent → only summary + plain body reaches reasoning
```

Better: ask the user for the PR's summary only as paste, if it's short.

### Example 3 — a subagent brief that needs source material

User: "give the subagent the problem section but not the rejected design."

```
Agent → write the extracted Problem section to /tmp/brief-source.md
Agent → Agent(prompt: "read /tmp/brief-source.md for source material")
        (the subagent sees only what's in the file; full issue body
        never enters either context)
```

## Anti-patterns

- **Mental fencing.** "I'll read it all and just ignore the bad
  parts." Discipline fails within a few turns.
- **Quoting fenced content for contrast.** "Unlike the proposed
  solution that wanted X, the new approach does Y." That sentence is
  the leak.
- **Including fenced framing in subagent briefs.** "Things already
  covered: loss of git-commit audit trail" encodes the rejected
  design and propagates it.
- **Reading "for background" or "just to be safe".** You don't need
  background that's been explicitly excluded.
- **Picking option (b) ("read it all anyway, flag explicitly")
  without user consent.** That's the same as no fence at all in
  practice — the leak risk is still on you.

## Acceptance criteria

1. Your response acknowledges the fence in one explicit sentence
   before any analysis begins.
2. The tool call(s) you made have a scope no broader than the
   constraint allows, OR you asked the user how to proceed with
   options.
3. No quote, paraphrase, or framing from fenced sections appears in
   your output, in subagent briefs, or in committed files.
4. If you were forced to read more than the fence allowed (and the
   user authorized that), the fenced sections are named explicitly in
   your response and never referenced again.

## Files this skill creates / modifies

- May write a temporary extraction to `/tmp/<name>.md` for processing.
- May write a sanitized source file under the working tree
  (`/tmp/brief-source.md` or `ai/working/source-extract.md`) when a
  subagent needs to read source material safely.
- Does not modify the original source.
