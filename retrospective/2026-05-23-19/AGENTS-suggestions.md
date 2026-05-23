# AGENTS.md suggestions — 2026-05-23-19

These are proposed additions to the project's agents file (`CLAUDE.md` for this repo). Each section contains:

1. **Proposed addition** — the exact text to paste.
2. **Why this earns its place in your agents file** — the argument for doing it, grounded in something that happened this session.

Decide each on its own merits. Skip ones that don't apply; copy-paste the ones that do.

---

## Suggestion 1: Doctrine-vs-implementation cross-check at orient

### Proposed addition

> **Doctrine-vs-implementation cross-check at orient.** When the user invokes a documented procedure ("work on phase N", "follow the runbook", "do the deploy procedure"), and after reading the procedural doc, spot-check that the concrete artifacts the doc references actually exist and match: workflow YAML files expose the documented inputs, scripts referenced by name are present and executable, env vars are wired through, CLIs are on PATH. Emit a one-screen manifest (`✓` / `✗` / `⚠` per artifact) before starting any work. This is mandatory even when the procedural doc is recent or "feels familiar" — drift between doc and implementation is invisible until exercised.
>
> *Grounded in: the 2026-05-23 phase-1 session — `testing-guidelines.md` §6 documented a `phase × action` dispatch matrix that `terraform-test.yml` did not actually expose; the gap surfaced only after planning had already started.*

### Why this earns its place in your agents file

The 2026-05-18 retro recommended doctrine-first PR sequencing, and that recommendation was followed for PR #15 — the doctrine landed. But the mechanics PR never shipped, leaving a 7-day window where every subsequent session inherited a load-bearing procedure that didn't run. The 2026-05-23 session was the first to *exercise* the doctrine, and the first to discover the gap.

A 90-second cross-check at orient time (read §6's table, grep the workflow YAML for the documented inputs, report match/mismatch) would have surfaced the gap *before* the user asked "is the sandbox live?" — not after the workflow refactor was already underway. The asymmetry is large: ~90 seconds vs ~15 minutes of mid-task pivoting and one back-and-forth round of "should I refactor first?" / "follow the procedure."

The rule applies broadly: any time the agent reads a procedural doc and the doc references concrete artifacts (file paths, CLI commands, workflow inputs, env vars), the existence and shape of those artifacts is testable in seconds. The cost of being wrong about whether they exist scales with task length.

---

## Suggestion 2: Tooling gaps are escalations, not design problems

### Proposed addition

> **Tooling gaps escalate, do not silently work around.** When you discover you cannot perform a step the procedure prescribes because a required tool, API, or capability is unavailable in this environment (no `workflow_dispatch`, no `gh` CLI, no write access to path X), the default response is to flag it to the user as a platform-tooling gap and ask whether to (a) escalate to platform owners and wait, (b) build a workaround, or (c) defer the task. Do NOT silently design and ship a workaround under the assumption the limitation is permanent — limitations are often temporary, and workarounds become technical debt the moment the limitation is removed.
>
> *Grounded in: the 2026-05-23 session — the agent's response to "I cannot dispatch workflows" was to design `.trigger-action.json` + agent-trigger.yml + a 52-test harness (31 files, 985 insertions); that mechanism was then reverted because the proper fix is direct GitHub API access for the agent.*

### Why this earns its place in your agents file

This is the most expensive lesson of the session. PR #19 was a competent, well-tested implementation of a workaround that should never have been built. The user did explicitly ask for the issue and the implementation — but the agent never paused to ask "is this a platform thing that should be fixed properly?" before agreeing. The default direction of conversation was workaround-ward, not escalation-ward.

Workarounds for platform limitations have three failure modes: (1) the limitation gets fixed and the workaround becomes dead code that someone has to remove; (2) the workaround becomes load-bearing and *prevents* the proper fix from being adopted because removing it is too expensive; (3) the workaround diverges from the platform's actual capability over time and becomes a maintenance burden of its own. In PR #19's case, (1) bit immediately — the mechanism was reverted within days.

The cost of asking "should we escalate this?" is one round of conversation. The cost of building a workaround that gets reverted is a 31-file PR plus the cleanup PR plus the cognitive load of two reviewers reading dead code. The asymmetry is enormous.

---

## Suggestion 3: State the purpose of a refactor at its top, not at its end

### Proposed addition

> **Announce-before-refactor.** Before starting an edit that the user did not explicitly ask for (workflow refactor, dependency upgrade, file restructure — anything where the agent is initiating structural change rather than implementing a directly-requested feature), state in one sentence what you are about to change and why, *before* the first edit. "I'm about to refactor X because §Y documents Z that the current implementation doesn't expose; without this, the procedure can't run" — first user-facing line of the turn, not after the diff lands.
>
> *Grounded in: the 2026-05-23 session — the agent began refactoring `terraform-test.yml` and the user interrupted partway through with "what are you refactoring?" The refactor was correct and necessary; the failure was not announcing it first.*

### Why this earns its place in your agents file

The user's interrupt — "what are you refactoring?" — is a signal that the agent was acting on a chain of reasoning the user could not see. The agent had: read the doctrine, found a gap, decided the gap had to be closed, started closing it. Each step was sound. But none of them surfaced to the user until edits started landing.

When an agent initiates structural change on its own authority (not directly requested by the user), the user's mental model of "what is happening right now" is set by the agent's first sentence of that turn. If the first sentence is the start of the edit, the user has to interrupt to recover context. If the first sentence is "Here's what I found, here's what I'm about to do, here's why," the user has the option to redirect cheaply or approve silently.

The "tone and style" section of this repo's prompt already says "Before your first tool call, state in one sentence what you're about to do." The rule above is the specific case for agent-initiated structural change, which the general rule covers but which is easy to skip when the agent is mid-flow.

---

## Suggestion 4: Don't update state files before the state exists

### Proposed addition

> **Write state files only after state changes succeed.** Files that track live system state (sandbox session blocks, deployment manifests, runtime registries) must be updated *after* the state-changing operation succeeds — never before, even when the file "is about to be needed." Don't write timestamps for resources that haven't been created. Don't mark a phase as `applied` until apply actually succeeded. The state file is a record, not a prediction.
>
> *Grounded in: the 2026-05-23 session — the agent wrote the "Current Sandbox Session" block in `ai/handoff.md` with start time and active phase before any AWS operation had run; the user reverted it as premature.*

### Why this earns its place in your agents file

State files are read by the next session to orient itself — that's their purpose. If the state file claims phase 1 is active and the sandbox is live, the next session believes it. If neither is true because the agent wrote the entry pre-emptively and then crashed/got interrupted/got reverted, the next session orients off a lie. Recovering requires the user to manually reset the file, which they're unlikely to remember to do because the file *looked* correct.

The cost of the rule is small — one extra commit (or one commit on a feature branch deferred until after the state-changing op). The cost of violating it is a state file that diverges from reality, silently, until someone notices.

This is a specific application of a more general rule: don't predict state. Record it.

---

## Suggestion 5: Tag platform-workaround code with sunset conditions

### Proposed addition

> **Sunset-tag platform workarounds.** Any code or config shipped specifically because a platform/tool/environment lacks a capability the project needs must include an explicit sunset condition: a one-line annotation in the commit message AND a comment in the file header naming the limitation, who's tracking the fix, and the condition under which the workaround should be removed. Format suggestion: `# SUNSET: remove when <X>; tracked at <link or "(no tracking issue)">`. Without this tag, workarounds rot into permanent infrastructure that future agents are afraid to remove.
>
> *Grounded in: the 2026-05-23 session — PR #19's `.trigger-action.json` + `agent-trigger.yml` were shipped to work around the agent's lack of `workflow_dispatch` access; the work-around was reverted within days. Had the workaround been tagged, the reverter would have had unambiguous license to remove it; the absence of a tag would have made the removal feel like undoing real architecture.*

### Why this earns its place in your agents file

The reverter of PR #19 had to make a judgment call: was the `.trigger-action.json` mechanism load-bearing, or was it a workaround that could be cleanly removed? The PR body argued for the latter, but the *code itself* (with tests, doctrine in §8/§9, an example file, validation, post-comment integration) looked like architecture. Without a sunset tag, a less-aggressive reviewer might have kept the workaround "just in case."

The cost of the tag is one extra commented line per workaround file. The benefit is unambiguous removal license when the limitation goes away. The k8-platform repo is small enough today that workarounds are easy to track in human memory; that won't stay true.

---

## Suggestion 6: "Follow procedure without asking" requires reading the whole procedure, including implementation assumptions

### Proposed addition

> **"Don't ask" presupposes "have read the whole procedure."** When the agents file says "follow procedure P without further clarification," that instruction presupposes the agent has read P in full — including any sections P refers to elsewhere (typically §6 / §Reference / appendices that document the dispatch matrix, the env-var schema, the workflow inputs the procedure assumes). Skim only the entry point and you'll ask permission for things the procedure already prescribes; the user's redirect will be "re-read the procedure, it answers your question." The "no clarification" rule is harder than it looks: it forbids the agent from off-loading uncertainty to the user, which means the agent must actually resolve the uncertainty itself by reading further.
>
> *Grounded in: the 2026-05-23 session — the agent asked the user a 3-option permission question about how to handle the doctrine-impl gap; the user's response was "re-read CLAUDE.md, the files it points to answer that question." The procedure did prescribe the right answer (make §6 real); reading §6 fully would have replaced the question with the action.*

### Why this earns its place in your agents file

The "follow procedure without asking" pattern is increasingly common in agent operation (CLAUDE.md, AGENTS.md, runbooks, ops docs). Its failure mode is asymmetric: when the agent skims the entry point, finds an apparent ambiguity, and asks the user, the user *cannot tell* whether the procedure actually answered the question — they have to re-read the procedure themselves to find out. So the cost of an unnecessary clarification question is borne mostly by the user.

The remedy is uncomfortable: when the procedure says "don't ask," the agent has to do the harder work of actually resolving the ambiguity by reading further, even when that's expensive. The rule above states that explicitly so the agent doesn't default to the easier (for itself) path of asking.

---

## Suggestion 7: When user expands scope mid-task, restate the new total before continuing

### Proposed addition

> **Scope-expansion checkpoint.** When the user adds requirements to a task already in progress ("also implement X", "make sure to add tests", "this might involve Y and Z"), pause the current work and restate the *total* new scope — original requirements plus additions — in one user-visible message before resuming. Estimate the new size if it has materially grown ("the test harness expands this from ~5 files to ~30 files; do you want me to proceed or split into a follow-up PR?"). Do not silently absorb scope expansions; they're a fork point, not a continuation.
>
> *Grounded in: the 2026-05-23 session — mid-implementation of issue #18's trigger mechanism, the user said "Make sure to implement numerous unit and e2e tests for this method of triggering... This might involve creating a third phase (test), and extra commands (test-unit and test-e2e)." The agent absorbed the expansion without restating; PR #19 grew from a 4-file trigger mechanism to a 31-file PR with a parallel test phase. The user got what they asked for, but they didn't get an opportunity to scope it down if they'd realized how much it implied.*

### Why this earns its place in your agents file

Scope expansion from the user is legitimate — the user has new information or a better idea, and the task should adapt. But the user is also often *not* tracking the cumulative size of what they've asked for. The agent has a clearer view of the total work pending, and that view is exactly the thing the user needs at the moment they're proposing an addition.

The 2026-05-23 case is canonical: the user's expansion request was four sentences. Implementing it required (a) extracting two scripts so they were testable, (b) inventing a third phase to host the test action, (c) wiring the new phase through compute-gates + parse-trigger + workflow gating + post-comment rendering, (d) writing 14 fixtures + 52 unit tests + 3 e2e tests + shared assertion helpers + a tests README + §9 doctrine. None of that was in the original ask; all of it followed inevitably from the request as written.

The checkpoint costs one round of conversation. The benefit is the user gets to make an informed decision: "yes, that's what I wanted" or "actually, just unit-test the parse function and we'll add the rest in a follow-up." The user retains the option without the agent having to ask permission — restating the scope is informational, not interrogative.

---

## Suggestion 8: Doctrine without implementation is a half-merged refactor — flag at orient

### Proposed addition

> **Doctrine-without-implementation is a half-merged refactor.** When the agents file or a doctrine doc describes a workflow that the implementation doesn't yet support, treat that as an in-progress refactor — not as stable doctrine. At orient time, if the doctrine-impl cross-check finds the implementation lagging the doctrine, name the situation explicitly: "the doctrine in §X is ahead of the implementation; before I follow the procedure I need to bring the implementation up to the doctrine, OR demote the doctrine to spec-only with a `STATUS:` annotation." Do not pretend a partially-real procedure is a fully-real procedure.
>
> *Grounded in: the 2026-05-23 session — PR #15 landed the phase × action doctrine on 2026-05-18 and deferred the mechanics PR; the mechanics PR did not ship before the 2026-05-23 session attempted to follow the doctrine, creating the gap that the workflow refactor in PR #17 had to close.*

### Why this earns its place in your agents file

The 2026-05-18 retro proposed doctrine-first PR sequencing, and that's a good rule. But "doctrine first" without "mechanics within the same session" creates a window where the doctrine is load-bearing on infrastructure that doesn't exist. The 2026-05-23 session was that window's bill coming due.

The rule above gives the next agent a script for handling the situation explicitly: when the cross-check reveals the gap, *name* it as "this is a half-merged refactor," and propose either closing it (the path PR #17 took) or annotating the doctrine with `STATUS: spec-only, implementation pending` so future sessions don't try to execute a procedure that can't run. Either resolution is fine; the worst outcome is to discover the gap mid-execution and improvise.

Pairs naturally with Suggestion 1 (the cross-check itself) and Suggestion 5 (sunset-tagging) — together they form a small discipline around "the state of the doctrine vs the state of the code."
