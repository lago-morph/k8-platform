# Spec: `handoff-spec`

## Intent

Some design work outlives a single session — either because the
context window will compress, because the current agent's context is
contaminated, or because the user wants to do the next phase in a
fresh session. The handoff has to be a self-contained file: the next
session reads only that file plus a small list of project files, with
no external chase-pointers.

In the session that produced PR #20, this pattern emerged under
pressure. My context had been polluted by reading a rejected
proposed-solution, and the user couldn't safely use me to draft the
spec. The fix was a single durable file (`ai/specs/ext-github-design.md`,
736 lines) carrying the entire briefing — Problem section verbatim,
user's directive verbatim, modified design, mermaid flowchart, 12-item
open-risks list with three alternatives each, instructions to the next
agent at the top, and an explicit prohibition against chasing the
originating issue. The next session reads only that file plus
`ai/handoff.md`, `ai/testing-guidelines.md`, `CLAUDE.md`.

This skill codifies the file structure, the prohibition pattern, and
the resolutions-before-critique workflow that emerged.

## Trigger

**Direct triggers — activate when:**

- User says "write a spec to hand off to a new session".
- User says "I'm going to use a new session" / "switching sessions".
- User says "make this durable across sessions".
- User explicitly invokes `/handoff-spec`.

**Proactive triggers — activate when:**

- Multi-session work is expected and the current session has
  accumulated substantial state.
- Your context has been polluted and the user needs a clean handoff.
- You're approaching context limits and durable state is needed.
- A subagent's output is large and the user wants to preserve it
  past the current session.

**Negative triggers — skip when:**

- The task will complete in this session.
- A simple `.session/<name>.md` checkpoint file
  (see `session-state-checkpoint`) is sufficient.

## Inputs

- The full design context: decisions made, open questions, source
  material to preserve, risks identified, deliverables planned.
- A target path (default: `ai/specs/<descriptive-name>.md`).
- Any prohibitions the next session needs to honor.

## Outputs

- One markdown file at the target path.
- Self-contained: a cold reader can pick it up with no external
  context.
- Three rounds of self-review applied before commit (see
  `subagent-prompting` anti-patterns: self-review against your own
  context, do not delegate that to a subagent).

## Workflow

1. **Pick a path under `ai/specs/<descriptive-name>.md`.** Use kebab-
   case. The directory `ai/specs/` is convention; create it if it
   doesn't exist.

2. **Write the agent-instructions block at the top.** Required
   content:

   - "READ FIRST" header so the section is unmissable.
   - Required reading list: this file + 2-4 project files. Examples
     for this repo: `ai/handoff.md`, `ai/testing-guidelines.md`,
     `CLAUDE.md`.
   - **Explicit prohibition: do not search the repo for issues, PRs,
     comments, or discussions that originated this work.** Phrase it
     this way: "that material is intentionally fenced out of this
     file. Looking for it pollutes context with a rejected design and
     risks repeating mistakes already made."
   - Required procedure as numbered steps. Steps 1, 2, 3 minimum.

3. **Add a Resolutions placeholder section.** Empty table, one row
   per open risk, columns for "Selected mitigation" and "Reasoning"
   marked TBD. The next agent fills this in *before* doing any
   critique.

4. **Add a Critique placeholder section.** Free-form, populated by
   the next agent after Resolutions are filled in.

5. **Write the Background section.** Rich — at least as much context
   as you'd give in chat to orient someone cold. Include:
   - The operating environment (sandbox? long-running CI?
     constraints?).
   - The blocker that motivated the work.
   - The supporting infrastructure the design assumes (other MCP
     servers, project structure, conventions).

6. **Write the Source Material section.** Verbatim copies of any
   external content (issue text, PR comment, user directive).
   **Strip cross-references.** Specifically:
   - Issue numbers (`#17`, `#42`).
   - Section anchors (`§3`, `§6`).
   - PR / comment links.

   Add a header note explaining what was redacted: "verbatim, lightly
   redacted to remove issue and section cross-references".

7. **Write the Modified Design section.** Summarize the agreed
   approach. Name the deliverables (PR1, PR2, …) and their scope.

8. **Add a procedure flowchart if the design has non-trivial flow.**
   Mermaid `flowchart TD`. Quote node labels that contain parens or
   commas (`node["text with (parens)"]`) — unquoted parens inside
   `[...]` labels can confuse the parser.

9. **Add a Decisions Already Taken section.** Bullet list of what's
   settled. Auth/credentials, audit-trail trade-offs, naming
   conventions, sequencing.

10. **Define your rating scale.** L/M/H definitions, explicit
    permission for ranges (`L–M`, `M/H`) if any of your risks use
    them. Without the scale, ratings drift between sections.

11. **Write the Open Risks section.** Per risk:
    - Explanation (the original concern, in plain prose).
    - Risk statement (one sentence).
    - Impact if unmitigated (one paragraph).
    - Likelihood: L / M / H with one-line justification.
    - Severity: L / M / H with one-line justification.
    - Three alternative mitigations: a, b, c. Each is a short
      paragraph, not a single sentence.

12. **Write the Implementation Deliverables section.** Generic.
    **Do not pre-determine resolutions** — the implementation should
    defer to whatever the next agent picks in §Resolutions.

13. **Self-review against your own context.** Three rounds maximum,
    early exit on a clean review.

14. **Commit, push, open draft PR.**

## Concrete examples

### Example 1 — PR #20 (the session that produced this skill)

File: `ai/specs/ext-github-design.md`. 736 lines. Twelve open risks
with three alternatives each. One mermaid flowchart for the meta-skill
procedure. Verbatim Problem section + verbatim user directive (with
naming substitutions in square brackets, both edits disclosed in the
section header).

The file's processing order: next agent reads context files → fills
in Resolutions table for all twelve risks → then writes Critique with
resolutions incorporated → waits for user sign-off before
implementation.

### Example 2 — handoff for a multi-PR refactor

A refactor that will span three PRs over multiple sessions can use
the same shape:

- Agent instructions: read this file + `docs/architecture.md` +
  module-specific docs.
- Resolutions: one row per architectural choice still open.
- Background: why the refactor exists.
- Source material: relevant existing-code excerpts and ADRs.
- Modified design: the target architecture.
- Decisions taken: name conventions, interface shapes.
- Open risks: things that might surface during migration.
- Implementation deliverables: PR1, PR2, PR3 with rough scope.

## Anti-patterns

- **Referencing the originating issue or PR by number in the file.**
  Fresh-context agents follow numbers and contaminate themselves the
  same way you did. Strip all `#NNN` and `§N` references.
- **Pre-determining resolutions in the Implementation Deliverables
  section.** "Includes the action-class declaration and the
  concurrency pre-flight" pre-supposes mitigations (a) on risks 2
  and 3. Phrase generically: "includes the resolutions from
  §Resolutions baked in".
- **Including rejected proposals as 'background'.** A rejected design
  has no place in the handoff file. The next agent doesn't need it.
- **Leaving the rating scale undefined.** Risks rated L/M/H without a
  scale section drift between sections.
- **Forgetting to quote mermaid labels with parens / commas.** Modern
  mermaid mostly handles them, but quoting is free safety.
- **Making the file long enough to skim.** Cap around 700-900 lines
  for a 12-risk handoff. Past that, content gets ignored.
- **Trusting a subagent to self-review the file against your context.**
  Subagents don't have your context. Self-review is the only path.
  (Subagents can error-check the file as a standalone artifact; that's
  a different task, and it should be reserved for the next session,
  not the authoring session.)

## Acceptance criteria

1. A cold agent reading only the file + the named context files can
   fill in Resolutions and Critique without external lookup.
2. No `#NNN` or `§N` cross-references appear in the file.
3. All required sections present: agent instructions, resolutions
   placeholder, critique placeholder, background, source material,
   modified design, flowchart (if applicable), decisions taken,
   rating scale, open risks, implementation deliverables.
4. Each open risk has explanation + risk + impact + L/M/H likelihood
   + L/M/H severity + three alternative mitigations.
5. Mermaid (if present) renders.
6. File self-reviewed against your context across at most three
   rounds, with early exit on a clean round.

## Files this skill creates / modifies

- `ai/specs/<descriptive-name>.md` — the handoff file.
- May create `ai/specs/` directory if it doesn't exist.
