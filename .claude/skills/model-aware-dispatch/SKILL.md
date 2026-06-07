---
name: model-aware-dispatch
description: Pick the right model for each subagent to optimize for SPEED without sacrificing quality (not to save tokens, and not via fast mode). Load whenever it is natural to spawn a subagent — any delegable subtask such as a code/file search, a fan-out of independent edits, running tests/lints, drafting a self-contained module or doc section, or an adversarial review. The orchestrator (opus) stays in the lead and synthesizes; it delegates each subtask to the fastest model that still clears the quality bar — haiku for mechanical/well-specified/verifiable work, sonnet for medium-judgment self-contained work, opus for hard reasoning where being wrong is expensive. Triggers on phrases like "spawn a subagent", "fan out", "delegate this", "do these in parallel", "use subagents", "which model", "speed this up", or proactively at the start of any multi-step task with delegable parts. Pairs with subagent-prompting (how to write the brief) and parallel-subagent-fanout (orchestration mechanics).
tags: [subagents, models, speed, orchestration, performance, parallelism]
---

# Model-aware dispatch

Spawn subagents both to **preserve the orchestrator's context** and to **go
faster** — and choose each subagent's **model** to match the subtask. The goal is
**wall-clock speed without sacrificing quality.** It is explicitly **not** about
saving tokens, and the lever is **model choice, not fast mode.**

The three models trade speed for capability:

| Model | Speed | Capability |
|---|---|---|
| **haiku** | fastest | strong on mechanical, well-specified, verifiable work |
| **sonnet** | medium | solid judgment on self-contained build/analysis |
| **opus** | slowest | best reasoning; reserve for the hard, expensive-to-get-wrong calls |

Speed comes from two moves together: **(1) right-size the model** to each subtask
(don't pay opus latency for a grep), and **(2) parallelize** independent subtasks
across the fast models. A wide fan-out of haiku/sonnet subagents finishing at once
beats one long serial opus pass — that is where the wall-clock win lives.

## The orchestrator stays opus

You (the lead) are opus and stay opus. You own the plan, the load-bearing
decisions, the synthesis, and the final review. **Never let a fast subagent make
an architectural, security, or otherwise irreversible call** — delegate the *work*,
keep the *judgment*. A fast model is a fast pair of hands, not the architect.

## Which model for which subtask

Ask one question per subtask: **what is the fastest model that won't lower the
quality of this result?** Default to the fastest that clears the bar; escalate only
when the task genuinely needs it.

| Give it to **haiku** (fast hands) | Give it to **sonnet** (medium judgment) | Give it to **opus** (hard reasoning) |
|---|---|---|
| code/file search, grep sweeps, enumerating naming conventions | writing a self-contained module to a clear spec | architecture / design decisions |
| applying a clearly-specified edit across many files | drafting a doc/section from an outline | adversarial review of a load-bearing plan |
| running tests/lints and reporting pass/fail | a single-file refactor with a clear target | ambiguous synthesis across many inputs |
| format/data conversions, fact collection | moderate debugging with a clear repro | security-sensitive or hard-to-reverse calls |
| wide fan-out where each item is simple + verifiable | summarizing one file / moderate analysis | resolving cross-cutting trade-offs |

These are starting points, not a rulebook. The discriminators are **task
difficulty**, **ambiguity**, and **cost of being wrong** — not the file count.

## Heuristics

- **Right-size, don't down-size blindly.** "Speed without sacrificing quality" means
  matching capability to difficulty, not minimizing everywhere. A quality-critical
  or ambiguous subtask gets sonnet/opus even though it's slower — that's the correct
  trade, not a failure of the skill.
- **Parallel beats serial.** Independent subtasks go out together in one message
  (multiple `Agent` calls) so they run concurrently. Don't serialize what could fan
  out.
- **Verify cheaply, escalate on doubt.** If a fast model's output is cheap to check
  (tests, a lint, a quick read), trust-but-verify. If a haiku subagent returns
  low-confidence or fails twice, **re-dispatch on sonnet/opus** rather than thrashing
  on the weak model.
- **Hard-to-verify or high-stakes ⇒ stronger model or orchestrator review.** Don't
  ship an unverifiable result from the fastest model just because it was fast.
- **Set the model explicitly.** Use the `Agent` tool's `model` parameter
  (`haiku` / `sonnet` / `opus`). If omitted, the subagent inherits the parent — so
  be deliberate; inheriting opus everywhere is the slow default this skill exists to
  fix.
- **Don't use fast mode for this.** Fast mode is a separate lever; optimize via
  per-subagent model choice so the orchestrator keeps full reasoning where it
  matters.

## Worked shape

A typical multi-step task:

1. **Opus orchestrator** plans and decomposes into subtasks, tagging each with a
   model.
2. **Fan out the fast, independent work in parallel** — haiku for searches/recon and
   wide mechanical edits, sonnet for the self-contained modules — in one message.
3. **Keep the hard reasoning** (the design call, the adversarial review, the final
   synthesis) on opus — either the orchestrator itself or a dedicated opus subagent.
4. **Orchestrator reviews and integrates.** Re-dispatch anything that came back weak
   on a stronger model.

## Anti-patterns

- **Everything on opus "to be safe."** Kills the speed-up; the whole point is to not
  pay opus latency for haiku-grade work.
- **Everything on haiku "for speed."** Sacrifices quality on the hard subtasks —
  the failure mode this skill is calibrated against.
- **Reaching for fast mode instead of model choice.** Wrong lever.
- **Letting a fast subagent own a load-bearing decision.** Delegate work, keep
  judgment.
- **Serial opus passes where parallel fast fan-out would do.** The wall-clock win is
  in the fan-out.
- **Optimizing for token cost.** Wrong objective — this is about speed (and context
  preservation), not spend.

## See also

- [`subagent-prompting`](../subagent-prompting/SKILL.md) — how to write the brief
  you hand each subagent (the 9-section template, return-budget discipline).
- [`parallel-subagent-fanout`](../parallel-subagent-fanout/SKILL.md) — orchestrating
  a parallel decompose → dispatch → merge workflow on sub-branches.
