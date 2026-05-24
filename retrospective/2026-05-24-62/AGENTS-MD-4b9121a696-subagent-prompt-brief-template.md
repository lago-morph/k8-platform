# agent instruction

**§6.X — Subagent prompts MUST include: (a) the exact file path or context source, (b) the data schema (YAML, JSON, etc.), (c) specific questions to answer (not "summarise"), (d) output format and word cap, (e) verbatim-quote-required-for-evidence directive.** A subagent with vague questions returns vague summaries; a subagent with specific questions returns specific evidence. The verbatim-quote directive prevents paraphrase drift.

*Grounded in: phase-2-diagnose log was 155K chars. The subagent prompt that worked had file path + jentic schema + three specific questions + 1500-word cap + "quote verbatim" directive. Returned both root-causes in one call.*

# justification

Most subagent prompts in this codebase already follow this; codifying the rule prevents drift. The cost is ~30 extra seconds per subagent dispatch (writing the structured prompt). The value is the difference between a useful return and a useless return — measured in entire subagent dispatches saved.

---
