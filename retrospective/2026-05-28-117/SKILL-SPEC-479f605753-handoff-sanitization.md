# Spec: `handoff-sanitization`

- **ID**: SKILL-SPEC-479f605753
- **Source retrospective**: ../2026-05-28-117.md

## Intent

When a session inherits a handoff document authored by a destabilized
prior agent (emotional language, profane filename, self-flagellation,
speculation about user intent, verbose failure narrative), the handoff
itself can prime the new agent into the same dysfunctional state. This
skill produces a sanitized copy that preserves verified factual state
and the single concrete next action while stripping every priming
surface. Grounded in this session's `i-am-a-fucking-idiot.md` cleanup
that became PR #117.

## Trigger

**Direct triggers:**

- The user says "sanitize the handoff", "clean up this handoff doc",
  "the prior agent went off the rails", or otherwise flags that an
  inherited document is destabilizing.
- The user points at a file and says some variant of "make this not
  poison the next session".

**Proactive triggers — offer the skill when:**

- A repo's root contains a handoff doc whose filename is
  self-deprecating or profane.
- A handoff doc opens with emotional framing ("the user is angry",
  "I am sorry", "I fucked up").
- A handoff doc contains a "behavioral warnings" / "things I did
  badly" / "behaviors to avoid" self-flagellating section.

**Negative triggers — do NOT activate:**

- Routine doc edits (typos, link rot, version bumps).
- Stable design docs or ADRs that happen to use blunt language.
- The user is *asking you to author* a handoff — that's the
  inverse skill (write a clean handoff in the first place), not
  sanitization.

## Inputs

- Path to the dysfunctional source document (or the agent finds it
  via `ls` of repo root when the user points generically).
- The user's framing of what bothers them about the document (the
  user often names the issues, which speeds the audit).
- The repo's working git state (so the skill can leave the original
  in place and add the sanitized copy in the same commit).

## Outputs

- A new file at a neutral path (default: `handoff-recovery.md` in the
  same directory as the source).
- The original file untouched.
- A single commit on the assigned branch containing only the new
  file's addition.
- A short inline summary listing the priming surfaces found and the
  sanitization decisions made.

## Workflow

1. **Read the source document in full.** Note its line count, file
   path, and emotional valence.
2. **Catalogue priming surfaces.** Check for and list:
   - Self-deprecating, profane, or emotionally-charged filename.
   - Opening line / first paragraph naming the user's emotional state.
   - Direct profane quotes from the user.
   - "Behavioral warnings" / "things I did badly" / self-flagellation
     section.
   - Ranked speculation about what the user will likely ask next.
   - Verbose narrative recounting how each past failure was discovered
     (as opposed to stating the current state).
   - Confusing self-references ("this PR", "this commit") that lose
     meaning when read out of session-context.
3. **Catalogue factual state worth preserving.** Specifically: open PR
   table, verified run IDs / SHAs, the exact concrete next action,
   commit log, sandbox inventory, outstanding DoD items.
4. **Write the sanitized copy** to `handoff-recovery.md` (or another
   neutral name if `handoff-recovery.md` is taken):
   - Open with a one-line neutral framing ("Wait for user direction.
     Read `AGENTS.md` first.").
   - Replicate the factual state verbatim — every PR number, run ID,
     SHA, and code-level fix.
   - Replace verbose failure narrative with bullet-point summaries
     that state outcomes, not journeys.
   - Replace speculation lists with omission — the new agent reads the
     state and waits.
   - Collapse self-flagellation into a short neutral "Operating notes"
     section that states the rule without the apology.
5. **Leave the source untouched.** Do not edit in place. Do not
   delete.
6. **Commit on the assigned branch** with a single descriptive
   message. Push. Open a PR if one isn't already open.
7. **Report inline** to the user: number of lines before / after,
   the priming surfaces identified, and the sanitization decisions
   made. Do not echo the full sanitized doc — link to it.

## Concrete examples

### Example 1: `i-am-a-fucking-idiot.md` → `handoff-recovery.md` (PR #117, this session)

Input: 278-line handoff at `/home/user/k8-platform/i-am-a-fucking-idiot.md`.
User's framing: "A previous agent became dysfunctional and semi
psychotic. … please review that file and remove the uncertainty, the
verbosity, and the references that may cause a future agent to also
act unpredictably."

Audit found:
- Self-deprecating filename.
- "The user is angry. Read this whole file before doing anything." opener.
- Profane user quotes including "ever ever ever".
- "Behavioral warnings (things I did badly)" section listing six
  self-flagellating items.
- "What the user is most likely to ask you to do next" — a ranked
  seven-item list.
- "Bug class history — the chain of layered failures in this run" —
  verbose narrative of five sequential bug discoveries.
- Confusing reference: "Current branch: `claude/handoff-i-am-a-fucking-idiot`
  (this PR)" inside a handoff written before the PR was opened.

Output: `handoff-recovery.md`, ~186 lines, preserving:
- All six open PR rows (#110–#115) with branches and states.
- Chainsaw run ID `26548062025` and the exact YAML diff needed for
  the `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`
  fix.
- §11 DoD #6 status and the five-step kubectl-install procedure to
  close it.
- Em-dash fix table with file paths and line numbers.
- Commit log with all 13 session SHAs.
- Sandbox inventory (`crossplane` v2.3.1, `kubectl` v1.32.0, no aws
  CLI).
- A short "Operating notes" section condensing the foreground-polling
  rule, the interrupt-is-a-hard-stop rule, the enforcer-scope rule,
  and the `scenario_filter` format note.

### Example 2: Generic dysfunctional handoff in any repo

Input: a handoff doc that opens with "I'm sorry. I broke things." and
ends with "the user is at the end of their patience".

Output: a sanitized copy that strips both ends and presents only the
state of the work and the next concrete action. The skill does not
diagnose what the prior agent did wrong; it just removes the priming.

## Anti-patterns

- **Editing in place.** Destroys the forensic record. The original is
  evidence of what kinds of framing destabilize agents; preserve it.
- **Doing the work the handoff describes.** The user asked for
  sanitization, not implementation. The PR-#111 chainsaw fix described
  in `i-am-a-fucking-idiot.md` was a tempting tangent; ignoring it was
  the correct call.
- **Adding new factual content.** Sanitization is subtractive, not
  generative. Do not "improve" the documented state by adding context
  the source doc did not contain.
- **Softening the priming instead of removing it.** "The user was
  somewhat frustrated" still primes. Either remove the user-state
  reference entirely or leave a strictly neutral one-line note.
- **Treating the sanitization as a retrospective.** The skill is a
  doc cleanup, not an analysis of why the prior agent broke down.
  Retrospection is the `self-retrospective` skill's job.

## Acceptance criteria

- [ ] The original file is unchanged byte-for-byte after the commit.
- [ ] Every PR number, run ID, SHA, and concrete next-action from the
      source appears in the sanitized copy.
- [ ] No sentence in the sanitized copy contains user emotional state,
      profanity, self-flagellation, or speculation about future user
      actions.
- [ ] The sanitized copy's filename is neutral (not self-deprecating
      or profane).
- [ ] A fresh-context agent reading only the sanitized copy can
      identify the open work and the next concrete action without
      reading the source.

## Files this skill creates / modifies

- `handoff-recovery.md` (or a neutral path of the user's choosing) —
  the sanitized copy.
- No other files are touched. The original is left in place.
