# AGENTS.md suggestions — 2026-05-21-20

These are proposed additions to `CLAUDE.md` (this repo's agents file).
Each section contains:

1. **Proposed addition** — the exact text to paste.
2. **Why this earns its place in your agents file** — the argument
   for doing it, grounded in something that happened (or nearly
   happened) in the session that produced PR #20.

Decide each on its own merits. Skip ones that don't apply; copy-paste
the ones that do.

---

## Suggestion 1: Section-scope reading instructions are hard constraints

### Proposed addition

> **Honor section-scope reading instructions at the tool boundary,
> not the cognitive boundary.** When the user says "read only X",
> "ignore Y", "skip the Z section", or "don't get polluted by W",
> treat the instruction as a hard constraint. Before any tool call
> that would return Y / Z / W, verify whether the tool can scope its
> output. If not, either (a) post-process the output with `awk` /
> `sed` / `head` in the same command so the disallowed content never
> enters your reasoning, (b) ask the user how to proceed, offering
> them the choice between pasting the allowed section themselves or
> accepting the risk explicitly. Never read the full content "and
> ignore the bad parts" — that discipline fails within a few turns
> and the leak shows up in your output verbatim.

*Grounded in: the Phase-1 instruction violation that opened the
session producing PR #20.*

### Why this earns its place in your agents file

The session that produced PR #20 opened with the user telling me
exactly once: "read just the problem section from the body of the
issue. Do not read more than the problem section." I called
`mcp__github__issue_read` with `method="get"`, which returns the full
body, and within two turns I was quoting verbatim phrases from the
fenced-out Proposed Solution in my own findings ("no new secrets, no
GitHub App, no PAT" — a phrase that only appeared in the rejected
section). The user spent the next several turns recovering. They
explicitly said they didn't trust my context for the rest of the
session.

The marginal cost of adopting this rule is small: one `awk` filter
per scoped read, or one clarifying question. The cost of *not*
adopting it was, in this session, roughly two hours of user time and
the loss of the rich session context they had built. The asymmetry is
not subtle.

---

## Suggestion 2: Context pollution is irreversible

### Proposed addition

> **Treat the agent's context window as write-once for the duration
> of a session.** There is no undo, no checkpoint, no rewind in the
> harness. Once a tool result, file content, or web fetch enters
> context, you cannot remove it; you can only choose not to reason
> about it, and that choice is unreliable. Before any tool call that
> might import fenced or potentially-fenced content, verify the
> call's output scope against standing constraints. If in doubt, ask.

*Grounded in: the harness-level lack of checkpoint that turned a
single tool call into an unrecoverable pollution event.*

### Why this earns its place in your agents file

This rule names the failure mode explicitly so future sessions know
the stakes. The harness has no `git restore` for context. The user's
only fallback when an agent gets contaminated is to abandon the
session — which destroys all the conversation history that had value
along with the pollution. In a multi-turn design session, that's
catastrophic.

Making this rule explicit reframes risky tool calls: they're not
just "a call that might return too much," they're "a one-way state
change to your context." The cost of treating tool calls this way is
slightly slower reads. The cost of treating them like normal calls
is, occasionally, an unrecoverable session.

---

## Suggestion 3: Maintain a session-state checkpoint file, committed to git

### Proposed addition

> **For any multi-turn task with accumulating state, maintain a
> session-state file at `.session/<task-name>.md` (or
> `ai/working/<task-name>.md` if `.session/` is gitignored) and
> commit it after every significant turn.** Significant = a decision
> was made, a constraint was added, a scope changed, a subagent
> returned material that matters. Commit subjects use the
> `checkpoint:` prefix. When the final artifact lands, remove the
> session-state file in a separate commit — git history preserves
> the trail. If context pollution is suspected, write a final
> "POLLUTED AT TURN N" line to the file before committing; that
> commit becomes an explicit handoff target for a fresh session.

*Grounded in: the user's own mitigation insight, surfaced during
this retrospective, addressing the no-rewind problem the harness
can't fix.*

### Why this earns its place in your agents file

The harness offers no checkpoint. Git does. A `.session/` file
committed after each significant turn turns "I have to start over
from scratch" into "I open a fresh session and tell it to read
`.session/issue-18-bridge.md`." Cost: roughly thirty seconds per
turn to update the file. Value, if pollution happens: hours of
recovery saved.

The pattern was the user's invention, surfaced *during* this
retrospective. It would have prevented the specific recovery loop
this session paid for. Adopting it costs almost nothing; not
adopting it means the next pollution event has the same recovery
profile as this one.

---

## Suggestion 4: Subagent role discipline — classify by required context

### Proposed addition

> **Before dispatching a subagent, classify the task by which
> context the subagent needs.** Three classes: (a) **fresh-eyes
> review** — subagent needs no prior context and benefits from
> having none; brief is self-contained. (b) **file-against-itself
> review** — subagent reads a specific artifact and checks it for
> internal consistency, factual errors, structural issues; needs
> the file but not your conversation. (c) **review against your
> context** — *not delegable to a subagent.* Subagents don't have
> your conversation history; if the source of truth is what you
> heard the user say five turns ago, only you can review against
> it. Self-review against your own context is the only path for
> class (c).

*Grounded in: the Phase-5 instruction violation, when I dispatched
a subagent to "error-check the file against my context", which the
subagent could not do.*

### Why this earns its place in your agents file

In the session that produced PR #20, after the first context-
pollution failure, the user gave me a recovery procedure: write the
spec, then loop "write/review three times against your context."
I read "review" and reached for a subagent — the wrong tool. The
subagent couldn't review against my context because subagents don't
inherit my context. The user explained this in the third explosion
of the session.

The rule is one classification step. Each class has a different
default tool: (a) `Agent` with `subagent_type=general-purpose`, (b)
`Agent` with the file path in the brief, (c) self-review inline.
Misclassifying class (c) as a subagent task wastes the dispatch and
trains the user to micromanage your delegation.

---

## Suggestion 5: Fenced-out material is actively dangerous, not background

### Proposed addition

> **When the user marks content as rejected, superseded,
> deprecated, or not-to-be-used, do not read it "for background
> understanding."** Reasoning about it later — even to compare,
> contrast, or note what's different about the new direction —
> leaks it into your output. The marker is not advisory; it's a
> directive to leave the content unread.

*Grounded in: the Phase-1 leak that quoted phrases from the
fenced-out Proposed Solution in my own critical-review findings.*

### Why this earns its place in your agents file

In the session that produced PR #20, after I'd read the rejected
Proposed Solution "for background", I quoted three specific phrases
from it in my critical-review findings — "no new secrets, no GitHub
App, no PAT", "atomic, reviewable, undoable / git revert", "the 8
acceptance criteria". Each of those quotes leaked the rejected
design into my own output, where the user could see it.

The rule forces a binary: either the user wants you to read it (in
which case it isn't fenced) or they don't (in which case background
isn't a justification). No middle ground. Costs nothing to apply;
its absence costs a session.

---

## Suggestion 6: Critique multi-step instructions before executing

### Proposed addition

> **Before executing any multi-step user instruction that contains
> loop counts, retry budgets, rating scales, file paths, or
> sequenced workflows, perform a critique-the-instructions step.**
> Surface ambiguities, undefined scales, missing exit conditions,
> unspecified file paths, and tool-scope mismatches as a numbered
> list with proposed resolutions. Stop and wait for answers before
> any tool call. One critique cycle saves one rewrite cycle and
> takes a fraction of the time.

*Grounded in: the seven-finding critique that prevented a v0 → v1
misalignment during the spec-authoring phase of this session.*

### Why this earns its place in your agents file

When the user gave detailed instructions for the spec (review loop
counts, risk-format requirements, next-agent header pattern), they
explicitly asked me to evaluate the instructions critically before
executing. I returned seven findings (ambiguous loop interpretation,
missing L/M/H scale definition, missing early-exit condition,
missing file path, prohibition strength, two more). All seven were
real; the user answered each and added an eighth constraint of
their own. We then produced v1 correctly the first time.

Without the critique step, I would have produced a v1 that
misinterpreted "loop 3 times" and skipped the resolutions-before-
critique workflow the user later added. That's at minimum one full
rewrite cycle. The critique took roughly two minutes; the rewrite
would have cost ten or more, plus the user's patience.

---

## Suggestion 7: No fabricated cross-references

### Proposed addition

> **Cite only what exists.** Do not refer to "step 3(d) of the
> directive" if the directive is unnumbered prose. Do not refer to
> "Section 4.2" if no Section 4.2 exists in the artifact. Do not
> describe "the third bullet" if the list has only two. If you need
> to reference something that doesn't have a label, either give it
> one in your own writing or describe it verbatim ("the part that
> says 'X'") instead of inventing a numbering.

*Grounded in: v1 of the PR #20 spec, which referenced "(3(d) in
the user's directive…)" — a step that didn't exist; the directive
was unnumbered.*

### Why this earns its place in your agents file

Fabricated cross-references are a subtle failure: the prose reads
correctly, but a reader who tries to follow the reference finds
nothing. In a handoff file (where the next agent reads cold), a
fabricated reference is a confidence-eroding bug. In v1 of the
session's spec, I wrote "(3(d) in the user's directive...)" — a step
that didn't exist because the directive was unnumbered prose. I
caught it on self-review and fixed it in v2.

Cost of the rule: read your draft and check that every numeric
reference resolves. Cost of skipping the rule: fabricated refs slip
through, get committed, and erode trust in everything else you
wrote.

---

## Suggestion 8: Verbatim quotes need accurate redaction headers

### Proposed addition

> **When you paste verbatim source material into an artifact with
> any edits applied, the section header must describe all the edits
> honestly.** "Verbatim with skill names updated" is a lie if you
> also dropped a sentence. "Verbatim, lightly redacted to remove
> issue cross-references" is a lie if you also redacted section
> references. The redaction note is part of the artifact's
> trustworthiness; pad it out to cover every actual edit.

*Grounded in: v1 of the PR #20 spec, where the user-directive
header understated the redactions I'd applied.*

### Why this earns its place in your agents file

The PR #20 spec quoted the user's directive verbatim but I had
silently dropped the opening "No." (which had referenced a rejected
proposal) and substituted skill names in brackets. The original
header read "verbatim, with skill names updated to the agreed final
naming" — which described the substitution but not the deletion. A
careful reader comparing the artifact to the original would have
found a discrepancy and wondered what else was hidden.

The rule is: be honest about what you changed. The cost is one extra
sentence in the header. The cost of skipping it is that someone
eventually catches the silent edit and stops trusting any verbatim
section.

---

## Suggestion 9: Verify counts in your own writing

### Proposed addition

> **Counts in your prose must match counts in your tables, lists,
> and follow-up summaries.** If you tell the user "13 risks", the
> file must have 13 risks. If the resolutions table has 12 rows,
> your prose must say 12. Off-by-one errors in your own descriptions
> of your own artifacts are common and corrosive; verify by counting
> before stating.

*Grounded in: the "13 items" claim made in one turn that
contradicted the file's actual 12 items.*

### Why this earns its place in your agents file

In one of my responses summarizing the spec to the user, I said
"13 items. Items 1–10 are the subagent's concerns. Items 11–13 are
the three open decisions." But the subagent had returned nine
concerns plus a tenth item that contained three sub-questions —
giving 9 + 3 = 12, not 13. I never corrected the count until
self-review caught it, and even then I had to verify the table and
prose both said 12.

The cost is counting once before stating. The cost of skipping is
that downstream consumers of the artifact propagate the wrong
count (resolutions table, next-agent instructions, implementation
deliverables) and the error becomes structural rather than
cosmetic.

---

## Suggestion 10: Don't paraphrase rejected content into "already-covered" lists for subagents

### Proposed addition

> **When briefing a subagent, the "already covered" or
> "background context" list must not encode the framing of
> rejected material.** Subtle references — "loss of git-commit
> audit trail (user accepts)", "no new tokens needed" — encode the
> rejected approach into the subagent's reasoning even when the
> rejected text itself is absent. Strip the framing, not just the
> quotes.

*Grounded in: the initial subagent dispatch in this session,
whose "already-covered" list contained a vestige of the rejected
trigger-file design.*

### Why this earns its place in your agents file

When I dispatched the fresh-context subagent for an independent
critical review, I included an "already-covered" list to prevent
the subagent from re-raising answered concerns. One item read
"Loss of git-commit audit trail (user accepts)" — a phrase that
made sense only against the rejected trigger-file design (which
relied on git commits as the audit trail). The subagent's review
didn't propagate the leak meaningfully, but the leak existed: I'd
encoded the rejected design's framing into the subagent's brief
even though the rejected text was never quoted.

The rule forces you to read your own briefs as a subagent would,
checking whether each line presupposes a rejected design. Cost is
one extra read of the brief; benefit is subagents reasoning from
the same fence the user gave you.

---

## Suggestion 11: For multi-session work, write the briefing to a file before involving subagents

### Proposed addition

> **When work will span multiple sessions and a subagent needs
> source material, write the source material to a file first, then
> point the subagent at the file.** Inline subagent prompts
> duplicate content into your context. File-based briefing keeps
> the source in one place, lets each subagent read independently,
> and lets you swap agents (or sessions) without bloating context.

*Grounded in: the user's frustration at having to inline source
material into multiple subagent prompts, when a file would have
served better.*

### Why this earns its place in your agents file

In the session that produced PR #20, I dispatched subagents with
inline prompts that duplicated source material into my own context
each time I re-read my own tool call. The user pointed this out
explicitly: "Did you make sure to provide the information to the
subagent in a file so IT wouldn't pollute its context window? …
That's why I fucking asked you to copy just the problem statement
and my comment in a new file."

File-based briefing decouples source-of-truth from agent context.
Cost: one `Write` call per source file. Benefit: subagents
interchangeable, contexts independent, no inline duplication.

---

## Suggestion 12: Rating scales need explicit definitions; ranges need explicit permission

### Proposed addition

> **If your artifact uses a rating scale (L/M/H, 1-5, T-shirt
> sizes), define the scale in the artifact itself.** Each level
> needs a one-line definition anchored to a concrete threshold
> ("L = minor inconvenience, no data loss; M = wasted session time,
> manual cleanup required; H = corrupted state, agent autonomy
> lost"). If any rating uses a range (`L–M`, `M/H`), the scale
> section must explicitly permit ranges. Without these, ratings
> drift between sections and lose comparability.

*Grounded in: the rating scale defect in v3 of the spec, where
several risks used `L–M` and `M/H` ranges without permission from
the scale section.*

### Why this earns its place in your agents file

In v3 of the PR #20 spec, the §Rating Scale section defined L, M,
H as single values, but risks 1, 4, 6, 7, 9 used ranges. Risk 4
went further — it said "**M** — treat as high until verified",
contradicting itself. A reader couldn't compare risk ratings
because the scale couldn't accommodate the ratings being used.
Self-review caught it; v4 added the range-permission note and
fixed Risk 4.

Cost is one paragraph in the scale section. Cost of skipping it
is that ratings drift, ranges proliferate, and the scale becomes
decorative rather than diagnostic.
