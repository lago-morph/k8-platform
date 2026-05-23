# AGENTS.md suggestion: Confirm before acting on compound prompts

## Proposed addition

> **§6.5 Confirm before acting on compound prompts.** For any user
> message that contains three or more distinct actions, bundles a
> feature request with a meta-instruction, or crosses more than one
> PR scope, the agent's first response is a structured repeat-back
> of its understanding before any tool calls. The repeat-back lists
> (a) numbered actions in execution order, (b) explicit stopping
> points, (c) flagged ambiguities with intended interpretations,
> (d) any assumptions inferred from context. The agent then waits
> for the user's chat reply.
>
> The default is **only** skipped when the prompt itself contains
> an explicit opt-out: "do this without confirming", "just do it",
> "skip the recap", "no need to repeat back", or equivalent.
>
> **System actions are not approval.** If the user takes a system
> action (merges a PR, leaves a review comment, dispatches a
> workflow, edits a file) without replying in chat, **do not
> interpret it as approval**. The user is often reviewing and
> approving pull requests in parallel with agents doing work and
> may take those actions without realizing the agent has asked for
> approval for something. Continue waiting for the chat reply. If
> the wait is unproductive, the agent may do orthogonal work or
> send a chat-only follow-up naming the open question; the agent
> does not proceed on the pending question until the user replies
> in chat.
>
> *Grounded in: 2026-05-23 session where the agent twice misread
> PR merges as implicit approval of pending repeat-backs.*

## Why this earns its place in your agents file

The original framing of this rule treated system actions as
implicit confirmation. The user corrected that mid-session: they
are often reviewing and approving pull requests in parallel with
agents doing work, and may take those actions without even
realizing the agent has asked for approval for something. Treating
those actions as approval would routinely commit the agent to
work the user did not actually approve.

The corrected rule keeps the structured repeat-back as the default
for compound prompts (which surfaces ambiguity before the work),
and makes explicit that approval is **only** from chat, with words.
System actions and chat replies are two orthogonal channels; only
one of them carries approval.

The marginal cost is the agent occasionally waiting longer for an
explicit chat reply when the user is busy. The marginal benefit is
that the agent never silently moves forward on a question the user
didn't actually answer.
