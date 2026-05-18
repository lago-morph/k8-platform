# AGENTS.md suggestions — 2026-05-18-15

These are proposed additions to the project's agents file (`CLAUDE.md` for this repo). Each section contains:

1. **Proposed addition** — the exact text to paste.
2. **Why this earns its place in your agents file** — the argument for doing it, grounded in something that happened this session.

Decide each on its own merits. Skip ones that don't apply; copy-paste the ones that do.

---

## Suggestion 1: Audit existing docs before proposing a workflow refactor

### Proposed addition

> **Pre-refactor doc audit.** Before proposing any refactor of an established workflow (CI, deployment, branching, release), `grep -rln` the project's docs (`CLAUDE.md`, `AGENTS.md`, `ai/`, `docs/`, `README.md`, `.claude/skills/`) for terms describing the current behavior. Report the result in the plan: "doctrine exists in file X" or "no doctrine exists — refactor must include a doctrine doc, not just mechanical changes." Do not skip this audit when you "already know" the answer.
>
> *Grounded in: the phase-workflow refactor planning session — needed a user prompt ("is there a workflow baked in anywhere?") to discover that nothing was documented.*

### Why this earns its place in your agents file

A workflow refactor without an audit produces one of two failure modes: (a) you bundle doctrine and mechanics together because you didn't realize the doctrine was missing, and the doctrine gets rubber-stamped; (b) you propose mechanics changes assuming doctrine already exists, and reviewers can't evaluate the changes because there's no spec to check them against.

In this session, the agent's first plan presented `CLAUDE.md` and `docs/operations.md` updates as small addenda to an existing doctrine. A 30-second grep (the user prompted it) revealed there was no existing doctrine — the only documented workflow was the monolithic `apply-and-destroy`. Once that was clear, the plan inverted: doctrine became a substantial new file (`ai/testing-guidelines.md` rewritten end-to-end), and the agents-file change became a *pointer* into it.

Marginal cost: one `grep -rln` and reading the matches. Maybe 90 seconds. The asymmetry is large — without it, the agent silently mis-frames the whole refactor.

---

## Suggestion 2: Iterate plans in chat before drafting files

### Proposed addition

> **Plan-in-conversation before drafting.** For any task that will produce new conceptual content (procedures, state machines, invariants, agent triggers), present the proposal in chat with concrete content snippets — section headings, the exact wording of invariants, the schema of new tables — *before* creating or rewriting any file. Iterate on wording in chat until the user says "go." Only then write files. Rewriting prose after the user has read it is expensive; rewriting in chat is cheap.
>
> *Grounded in: the phase-workflow planning session — went through 3 rounds of plan refinement (initial → "is anything baked in?" → "I like this, go forward") before any file was created, and the final files were close to what the user had already approved.*

### Why this earns its place in your agents file

The cost of changing a written-out file is high — re-reading the file, re-iterating in chat, fixing references. The cost of changing a chat proposal is essentially zero. Three rounds of chat refinement before the first write means the agent spent its file-writing budget on the right file at the right wording, not on rework. This session produced one commit, no reverts, no second-pass edits.

The counterfactual is the common pattern of "I'll just draft it and iterate on the file." That pattern produces 3–5 commits per file as the wording converges, plus the cognitive cost of context-switching between the editor and the chat. Chat-first is strictly cheaper when the artifact is prose-heavy.

The rule prescribes a behavior the agent already drifts toward when the task is large; making it explicit means it happens even when the task feels small.

---

## Suggestion 3: Doctrine and mechanics ship in separate PRs

### Proposed addition

> **Doctrine-first PR sequencing.** When a refactor produces *both* new conceptual content (procedures, state machines, invariants, agent triggers in docs) *and* mechanical implementation (CI YAML, scripts, configs), ship them as two separate PRs in this order: (1) doctrine-only PR with the new content + a pointer from the agents file; (2) mechanics PR that implements the doctrine. Do not bundle them. The doctrine PR's body must explicitly name what's deferred to the mechanics PR.
>
> *Grounded in: PR #15 ("docs: define phase-by-phase workflow doctrine") — landed as the first of a planned two-PR sequence, with the workflow YAML / `post-comment.py` / skill changes deferred to a follow-on PR.*

### Why this earns its place in your agents file

Bundled doctrine+mechanics PRs have a well-known review failure mode: the YAML/code diff is visually loud and pulls reviewer attention; the doctrine wording slips through unexamined. Then the doctrine becomes load-bearing for agent behavior and turns out to be slightly wrong, and every subsequent PR re-litigates it.

Doctrine-first inverts the dynamics. The doctrine PR is small enough to read end-to-end; reviewers focus on whether the wording captures what they actually want. The mechanics PR becomes a *check* against the now-merged doctrine — "does this implement testing-guidelines.md §3?" — which is a much sharper review question than "is this the right behavior?".

The marginal cost is one extra PR (open, review, merge) per refactor. The marginal benefit is that the doctrine actually gets read.

---

## Suggestion 4: Add session-scoped state schemas in the doctrine PR, not the mechanics PR

### Proposed addition

> **State-schema-with-doctrine.** When a doctrine introduces session-scoped or runtime-scoped state ("current sandbox session", "active phase", "current build queue"), add the schema for that state (typically in the project's handoff doc) in the *doctrine* PR, not the mechanics PR. The mechanics need a place to write; that place must already exist. Inventing the schema mid-implementation leaks doctrine decisions into a "mechanics" review.
>
> *Grounded in: PR #15 added a "Current Sandbox Session" block to `ai/handoff.md` alongside the new procedure in `ai/testing-guidelines.md`. The follow-on YAML PR can now just write to that block; it doesn't need to decide what fields exist.*

### Why this earns its place in your agents file

State schemas are doctrine — they encode "what does the system need to know about itself to behave correctly?". Hiding them in a mechanics PR mislabels them. It also gives the schema review fewer eyes (because the mechanics PR has many other things competing for attention).

The k8-platform case is concrete: the `Current Sandbox Session` block has six fields. The follow-on workflow YAML PR will read three of them, write two of them, and rely on a third for the agent's decisions in the "work on phase N" procedure. All three of those couplings are doctrine — they belong with the spec, not with the YAML.

Marginal cost: roughly 30 lines of markdown in the doctrine PR. Marginal benefit: the schema gets reviewed as part of the spec it serves.

---

## Suggestion 5: Trigger phrases belong in the agents file, with a pointer to the procedure

### Proposed addition

> **Conversational triggers are explicit.** Any conversational phrase the user expects the agent to expand into a multi-step procedure ("work on phase N", "ship this", "/babysit the PR") must be enumerated in the agents file, each with a one-line pointer to the procedure document and a "follow without further prompting" annotation. Do not rely on the procedure document being discovered organically — the agents file is the index.
>
> *Grounded in: PR #15's `CLAUDE.md` addition listed three trigger variants ("work on phase N", "let's do phase N", "/work-on N") and explicitly told the agent to follow `ai/testing-guidelines.md` §3 without asking for clarification.*

### Why this earns its place in your agents file

Conversational triggers are a UX contract between the user and the agent. The user types one phrase; the agent does ten minutes of orchestration. If the trigger isn't enumerated in the file the agent reads first, the contract is undocumented and the agent will sometimes ask "what do you mean?" instead of acting — defeating the whole point.

Each trigger entry is two lines: the phrase variants and the pointer to the procedure. Marginal cost is near-zero; marginal benefit is consistent agent behavior across sessions and across people working in the repo.

Pair this with the existing convention of putting *invariants* (the "regardless of what the user appears to ask for" rules) directly in the agents file. Triggers say "do this when X"; invariants say "never do that, even if asked." Together they're a complete agent-behavior contract.
