# Spec: `doctrine-before-mechanics`

## Intent

When asked to refactor an established workflow that has both a *conceptual* component (how humans and agents should think about and operate the workflow) and a *mechanical* component (CI YAML, scripts, configs), sequence the work so the doctrine ships first as a doc-only PR, and the mechanics follow as a second PR that the doctrine PR enables.

The pattern earns its place because doctrine-and-mechanics-in-one-PR has two failure modes that the split avoids:

1. **The doctrine review gets diluted.** Reviewers focus on the mechanical diff (a YAML file is loud, a doc is quiet) and approve the doctrine wording in passing. Doctrine is the load-bearing artifact for agent behavior, so this is exactly backwards.
2. **The mechanics review can't be done without the doctrine being settled.** Reviewers ask "should this be one input or two?" and the answer depends on doctrine that wasn't pinned down. Doctrine-first lets the mechanics review be purely "does this implement the doctrine correctly?".

A real example: the k8-platform repo had a `mode=apply-and-destroy` monolithic CI input, and the user wanted to refactor it into per-phase apply/destroy/verify actions. The mechanics (workflow inputs, step gating, comment script) and the doctrine ("work on phase N", phase state model, debug loop with three invariants) were both new. Shipping the doctrine first (PR #15) meant the follow-on YAML PR can be reviewed against an already-merged spec.

## Trigger

**Activate when the agent's plan to satisfy a user request contains *both* of:**

1. New conceptual content the agent (or a human operator) is expected to follow — phase models, procedures, invariants, decision rules, terminology.
2. Mechanical implementation changes — workflow YAML, scripts, configs, code — that would *enforce* or *embody* that conceptual content.

**Direct trigger phrases:**
- "Make it explicit so the agent does it the way I want."
- "Document this first, then implement it."
- "What instructions does the agent follow today for X?"

**Proactive trigger:** any plan whose commit sequence already separates "docs" from "YAML" or "script" — that separation is already the doctrine/mechanics split, but agents sometimes still bundle them in one PR for convenience. Flag the split as required, not optional.

**Negative triggers (do not activate):**
- Pure-mechanics refactors with no agent-facing conceptual change (rename a variable, bump a version).
- Pure-doctrine work where no mechanics will follow (writing an ADR, updating a README that has no enforcement counterpart).
- Single-file changes — splitting one file into two PRs is overhead with no benefit.

## Inputs

- The user's stated goal (often conversational, e.g., "I want the workflow more granular").
- The current state of the workflow being refactored (read the existing YAML, scripts, related skills).
- The current state of the docs that *should* describe the workflow (grep `CLAUDE.md`, `AGENTS.md`, project docs dirs, skill READMEs).
- The list of agent triggers the user wants to introduce (e.g., "when I say `work on phase N`...").

## Outputs

Two PRs, sequenced:

1. **Doctrine PR** (this skill's primary output):
   - One or more doc files containing the new conceptual content.
   - A pointer from the project's agents file (`CLAUDE.md` / `AGENTS.md`) into the new doctrine.
   - PR description that explicitly defers mechanics to a follow-on PR.
2. **Mechanics PR** (separate task, not authored by this skill):
   - The YAML / script / config changes that implement the doctrine.
   - PR description that links back to the doctrine PR.

## Workflow

1. **Audit existing docs first** (this is the highest-leverage step):

   ```bash
   grep -rln -iE "<keywords describing current workflow>" \
     CLAUDE.md AGENTS.md ai/ docs/ README.md .claude/skills/
   ```

   Read the matches. The audit answers the question "what does the current doctrine say?" If the answer is "nothing — only the YAML describes it" then the doctrine PR must be substantial (not a small addendum). If the answer is "an outdated section in CLAUDE.md describes the old behavior" then the doctrine PR is a rewrite plus a pointer.

2. **Draft the doctrine in conversation before drafting any file.** Show the user the proposed phase model / state machine / procedure / invariants in chat. Iterate on wording until the user says "go." Only then create files. This avoids re-writing prose after the user has read it once.

3. **Choose the doctrine's primary home.** Patterns that work:
   - A new dedicated doc (e.g., `ai/testing-guidelines.md` rewritten around the new model).
   - A new section in an existing reference (e.g., `docs/operations.md` §"Workflow lifecycle").
   - Both, with one being the deep spec and the other being the operator-facing summary.
   Add a *pointer* (not the full content) to the agents file (`CLAUDE.md` / `AGENTS.md`) so every session loads it.

4. **Update any per-session state artifacts the doctrine implies.** If the doctrine introduces session-scoped state ("current sandbox session", "active phase", "build queue"), add the corresponding schema to the handoff doc *now*, not in the mechanics PR. The mechanics need a place to write; the place must already exist.

5. **Commit, push, open the doctrine PR as a draft** (default — let the user finalize when they've reviewed wording). PR title: `docs: <one-line description of the doctrine>`. PR body must include:
   - "What changes" — list each doc, one sentence per file.
   - "What's intentionally NOT in this PR" — name the mechanics that follow.
   - "Test plan" — doc-reading checklist (no CI required for doc-only PRs).

6. **Wait for the doctrine PR to merge before opening the mechanics PR.** This is the discipline. If you open the mechanics PR while the doctrine is still in review, you've defeated the purpose of the split.

7. **When opening the mechanics PR**, link the merged doctrine PR in the body and frame the diff as "implements the doctrine in [link]." Reviewers can then ask "does this match the spec?" rather than "what's the spec?"

## Concrete examples

### Example 1 — k8-platform phase workflow refactor (PR #15)

- User asked: "make the workflow more granular" — implied per-phase apply/destroy.
- Plan-in-conversation rounds: 3. User pushed back twice, once on doctrine-vs-mechanics ordering, once on adding the "work on phase N" trigger.
- Audit: grep across `CLAUDE.md`, `ai/`, `docs/`, `README.md`, `.claude/skills/` for `iterate|inner loop|incremental|debug loop|phase.*apply` returned **zero** matches. The only existing references were to the old `apply-and-destroy` monolith.
- Doctrine PR (#15) modified 3 files:
  - `ai/testing-guidelines.md` rewritten with 6-section structure (constraints, phase state model, "work on phase N" procedure, debug loop, budget arithmetic, action reference).
  - `CLAUDE.md` got a new "Phase Workflow" section (29 lines) pointing into testing-guidelines and codifying three invariants.
  - `ai/handoff.md` got a new "Current Sandbox Session" block (35 lines) — the session-scoped state the mechanics will write to.
- PR body explicitly said "no `.github/workflows/terraform-test.yml` changes, no `post-comment.py` changes, no skill changes — those land in the next PR."
- Mechanics PR (not yet opened) will modify the YAML, the comment script, and the `terraform-ci-watch` skill. It can be reviewed purely as "does this implement testing-guidelines.md §3?"

### Example 2 — hypothetical: API rate-limit middleware

- User asks for a rate-limiter on an internal API.
- Audit: there's no doctrine for "what we rate-limit, why, and what 429 responses look like." Mechanics would be a middleware module.
- Doctrine PR: a new `docs/rate-limiting.md` defining the policy (which routes are limited, the budget per token bucket, the 429 response shape, the back-off header contract), plus a `CLAUDE.md` pointer for agents that will hit the API.
- Mechanics PR: the middleware module + tests + wiring, all implementing the spec.
- If the doctrine PR were skipped, every code reviewer would ask "is `X-RateLimit-Remaining` part of the contract or an implementation detail?" — and the answer would have to be re-litigated in every follow-on PR.

## Anti-patterns

- **Bundling doctrine and mechanics in one PR "for convenience."** The whole point is the review separation. If they're together, the doctrine is rubber-stamped because the diff is visually dominated by the mechanical changes.
- **Writing the doctrine as a tiny addendum when the audit shows nothing exists.** If grep returns zero, the doctrine PR is substantial — usually a new dedicated doc, not a paragraph stapled onto an existing one. Right-size the doctrine to the gap it fills.
- **Adding the agents-file pointer in the mechanics PR instead of the doctrine PR.** The pointer is part of the doctrine — it's how the agent finds the doctrine. Without it, the doctrine ships but never gets read.
- **Forgetting to add session-scoped state schema to the handoff doc in the doctrine PR.** If the mechanics need to write to a state block that doesn't exist yet, the mechanics PR has to invent the schema mid-implementation, which leaks doctrine-decisions into a "mechanics" review.
- **Drafting files before the user has signed off on wording in chat.** Re-writing prose is expensive; iterate in chat where iteration is cheap.

## Acceptance criteria

1. The doctrine PR's diff contains only docs (and possibly an empty placeholder for state schemas). Zero `.yml`, `.py`, `.tf`, code-file changes.
2. The doctrine PR body explicitly names what's deferred to the mechanics PR.
3. The project's agents file (`CLAUDE.md` / `AGENTS.md`) gets a pointer to the new doctrine in the same PR.
4. An agent reading only the agents file and the doctrine — no other context — could correctly execute the user's trigger phrase ("work on phase N", or whatever applies).
5. The mechanics PR is opened only after the doctrine PR merges, and its body links the doctrine PR.

## Files this skill creates / modifies

- One or more doc files defining the new conceptual content (paths vary by project).
- The project's agents file (`CLAUDE.md` or `AGENTS.md`) — pointer addition only, do not bundle other unrelated edits.
- Any session-scoped state artifact the doctrine implies — typically the project's handoff doc (`ai/handoff.md` or similar).
- The retrospective directory if invoked as part of a wrap-up (not strictly created by this skill, but commonly co-occurs).
