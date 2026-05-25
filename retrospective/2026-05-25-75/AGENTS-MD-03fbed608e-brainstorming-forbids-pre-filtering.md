# agent instruction

**Brainstorming forbids pre-filtering.** When dispatched to brainstorm, an agent must record every idea — including wacky, speculative, or cross-cutting ones — without evaluating, ranking, or filtering. A one-sentence idea + category + justification is the unit; pre-filtering during the brainstorm destroys the long tail that later triage will recover. Filtering is a separate later step with its own PR.

*Grounded in: the six-agent brainstorm fanout in PR #73 produced 400 ideas because subagents were explicitly told "do not pre-filter"; a later triage pass extracted the top-15 in PR #75.*

# justification

Brainstorming and triaging are different cognitive activities that fail when mixed. PR #73 dispatched six subagents with the explicit constraint *"do not pre-filter; wacky ideas welcome"* and produced 400 ideas plus 466 cross-review extensions. PR #75's top-15 triage pass found roughly 5-7 high-leverage items from each cluster — items that would have been silently discarded if any of the six brainstorm agents had pre-filtered to "only the ones I think are good".

The marginal cost of recording an idea is one sentence (~5 seconds of subagent time). The marginal cost of NOT recording a wacky idea is permanent: the long tail isn't recoverable later because no one remembers it existed. Triage is cheap (one user prompt: "give me the top 10"), so deferring filtering to the triage step has near-zero downside.

The rule explicitly extends to: cross-cutting ideas that span two domains, ideas that seem "too obvious to mention", ideas that apply only to a future phase the project isn't on yet, and ideas the agent thinks are infeasible. Capture them all; let triage decide.
