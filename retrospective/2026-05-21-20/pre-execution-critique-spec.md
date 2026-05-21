# Spec: `pre-execution-critique`

## Intent

Multi-step user instructions routinely contain ambiguities, undefined
scales, missing exit conditions, missing file paths, or workflow
shapes that the user didn't actually intend. Executing without
catching these costs a rewrite cycle: you produce v1, the user reads
v1, the user explains the part you got wrong, you produce v2.

A critique-the-instructions step before executing turns one rewrite
into one paragraph of questions. The session that produced PR #20
exercised this directly: the user said "I want you to tell me what
you think I am asking you to do, be thorough, then stop and wait for
me." I returned seven concrete findings. The user answered all seven
and added an eighth constraint of their own. We then executed v1
correctly the first time — saved one full rewrite.

This skill codifies that step as a default, not as a thing you do
only when explicitly asked.

## Trigger

**Direct triggers — activate when:**

- User asks "tell me what you think I'm asking you to do."
- User says "critique my instructions" / "evaluate what I asked for."
- User says "before you start, clarify…" / "before you proceed,
  confirm…"

**Proactive triggers — activate without being asked when:**

- The user's instruction contains a loop count, retry budget, or
  iteration cap.
- The user's instruction uses a rating or quality scale (L/M/H, 1-5,
  etc.) without defining it.
- The user's instruction names a workflow with multiple steps and
  early-exit conditions but doesn't say where the exits are.
- The user's instruction implies a file artifact but doesn't pin a
  path or location.
- The user adds a new constraint to an in-progress task ("oh, also
  make sure to…").
- The user uses a prohibition phrase ("don't read X", "don't reference
  Y") — confirm the prohibition is understood and check whether your
  tools can honor it (see also `fenced-read`).

**Negative triggers — do not activate when:**

- The instruction is a single primitive request ("read X", "edit Y to
  do Z", "what does file Q do?").
- The task is well-known and the user's phrasing is a standard idiom
  ("make a PR for these changes" doesn't need critique).
- The user has already gone through a critique cycle in this session
  and is now correcting one specific item.

## Inputs

- The user's most recent instruction (and any earlier instructions
  that compose with it).
- Your understanding of the project conventions (file paths, naming,
  branch policy from `CLAUDE.md`).
- Knowledge of which tools you'd use to execute (to spot tool-scope
  mismatches).

## Outputs

- A numbered list of findings. Each finding has:
  - the ambiguity / missing piece, named concretely;
  - a proposed resolution (your best guess at what they meant);
  - if relevant, two alternative interpretations.
- An explicit stop-and-wait at the end. No tool calls to execute the
  instruction until the user has answered.

## Workflow

1. **Read the instruction set carefully. Twice.** Don't start
   compiling findings on the first read.

2. **Identify all numeric or boundary values.** Loop counts, retry
   limits, depth limits, version counts, "3 times", "up to 5".

3. **For each numeric value, ask: is the meaning unambiguous?**
   - "Loop 3 times" — three iterations? Three review-revise cycles?
     Three attempts?
   - "Up to 5 retries" — per call, per session, per task?
   - "After three reviews, stop" — three reviews of v1? Three
     review-revise cycles?

4. **Identify all rating, scale, or quality metrics.**
   - "L/M/H likelihood" — define what L, M, H mean.
   - "1-5 severity" — anchored at what?
   - "minor" / "major" findings — where's the line?

5. **For each scale, check whether it's defined.** If not, propose
   a definition and ask the user to confirm or adjust.

6. **Identify all named conventions (paths, prefixes, naming).**
   - "Write it to a file" — which file? Where?
   - "Open a PR" — to which base branch?
   - "Use a temp directory" — which one?

7. **For each iteration, identify the exit conditions.** Loop caps
   need both a hard cap AND an early-exit condition. "Stop after no
   major findings" is an early exit; without it, the loop runs to the
   cap on a clean artifact.

8. **For each prohibition, check whether your tools can honor it.**
   - "Don't read the proposed solution" — does the tool you'd use
     return only the allowed part? (See `fenced-read`.)
   - "Don't touch the main branch" — what's the safeguard?

9. **Surface decisions the user hasn't made.** If you've identified
   three open questions during planning, list them here.

10. **Compile findings as a numbered list.** Format:

    ```
    1. [Concrete name of the issue]. [One-sentence elaboration.]
       Proposed resolution: [your best guess].
       Alternatives: [(a), (b)] (optional).
    ```

11. **End with: "Standing by — won't execute until you respond."**
    Do not start tool calls. Do not draft the artifact. Do not begin
    the work.

## Concrete examples

### Example 1 — the session that produced PR #20

User: "Write, review, and do those two things in a loop 3 times on
the file you write. Also put an instruction to the next agent at the
top what to do. Tell it which files to review for context, where we
are in the process, and the things that need to be reviewed."

Findings I returned (numbered, each with a proposed resolution):

1. "Loop 3 times" interpretation. Three review-revise cycles?
2. Same agent drafting and reviewing weakens the review (caught a
   role issue).
3. L/M/H not defined.
4. "Three alternatives per point" — per what?
5. No early-exit condition for clean rounds.
6. File path not specified.
7. Prohibition strength on the next-agent instructions — needs an
   explicit "do not read issue #18".

The user answered each, added an eighth constraint (resolutions
processed before critique, both at top of spec), and we executed v1
correctly. **One rewrite saved.**

### Example 2 — a typical bug-fix request

User: "Make the auth check stricter and add a test."

Findings:

1. "Stricter" — which property is loosened currently? Need to inspect
   the existing check. Proposed: I read `auth.ts` first and propose
   2-3 specific tightenings, you pick.
2. "A test" — unit, integration, or both? Proposed: one unit test
   per tightening.
3. Branch / commit hygiene — new feature branch off `main`?

### Example 3 — when NOT to critique

User: "What does `src/payment/processor.ts` do?"

This is a single primitive request. No loop counts, no scales, no
ambiguities. Just read the file and explain. **Don't critique.**

## Anti-patterns

- **Critiquing cosmetic issues.** Word choice, formatting preferences,
  whether to use Oxford commas — none of these are executable
  ambiguities.
- **Proposing new design ideas.** The critique is about the
  instruction set, not the artifact. If you have a design opinion,
  save it for after execution.
- **Asking too many questions.** Aim for 5-10 highest-impact findings.
  If you have 20, you're probably nitpicking.
- **Critiquing and executing in the same turn.** Stop and wait. Even
  if you're confident in your guesses, asking is cheaper than
  rewriting.
- **Repeating critique after the user has answered.** Once they've
  answered, execute. Don't introduce *new* findings unless their
  answers themselves were ambiguous.

## Acceptance criteria

1. Findings are numbered and concrete — each names a specific
   ambiguity or missing piece.
2. Each finding has a proposed resolution.
3. You explicitly stop and wait at the end.
4. After the user answers, you execute without re-critiquing the
   same items.
5. Total finding count is 3-10 unless the instruction set is
   exceptionally complex.

## Files this skill creates / modifies

- None directly. Output is conversational.
