# `<run-name>` — last night's run, in plain terms

**Write this with the [`human-scoped-deliverables`](../../human-scoped-deliverables/SKILL.md)
skill.** It is the user's primary review artifact, read with a human brain at the
start of the day — lead with the story, plain words, tables for comparison, small
Mermaid diagrams (≤7 elements, render-verified), no hash-ID / "§X.Y" soup in the
body (push every exact pointer to the audit-trail section at the bottom), describe
effort instead of estimating hours, mark opinion as opinion.

**What this is:** ~50-word orientation. What the run was, what it produced, how to
read this page, where the code-level detail lives (the PRs).

---

## The short version: goal, plan, what changed, what's next

- **What we were trying to do** — the objective, in plain language.
- **Where the night would have gone if everything broke our way** — the happy-path
  next step (the same thing posted to the user at run start).
- **What actually changed the plan** — the honest findings/constraints that stopped
  the run short of that. The most useful part for deciding what to do next.
- **What's next, in order** — concrete next steps.

`<optional small Mermaid flowchart: planned trajectory, with done / partway /
not-started shading>`

## What's live / what got built

`<what's confirmed working, with how-we-know — a small table reads well>`

`<the pieces shipped: a table of piece → one-human-sentence of what it does → merge
risk>`

`<Speculative recommendation: ... — mark opinion as opinion when you give one>`

## The order to merge them

Numbered, stack-bottom first. Call out any PR safe to merge independently. `<small
Mermaid of the stack shape is optional>`

## Decisions you may want to confirm

For each: what you did, the alternative, the rewind path if the user would call it
differently. **Zero is valid** if the run closed everything.

## What I deliberately did NOT do

Adjacent work bounded out per the envelope, plus any in-scope work deferred — each
with its reason. Hiding deferrals is forbidden.

## How to undo any of it

| To undo | Revert | What survives |
|---|---|---|
| `<scope>` | `<what to revert>` | `<what's left>` |

---

## Pointers / audit trail

*Every precise reference, collected here so it stays out of the read above.*

- **Run / date / account:** `<...>`. **Plan + envelope:** `<paths, PR #>`.
- **Live evidence (CI run IDs):** `<...>`.
- **PRs:** table of PR # → branch → base → plan section → title.
- **Decision briefs (if any):** `<auto-NNN-* + round status>`, else "none — the
  decisions were pre-answered / auto-resolved."
- **Tests / subagents / retrospective path / branch chain / run start-end:** `<...>`.
