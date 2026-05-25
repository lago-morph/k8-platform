# agent instruction

**Subagent briefs use absolute paths and prohibit cross-task edits.** Every subagent brief that creates or edits files MUST: (a) name the output file as an absolute path starting with `/home/user/`; (b) explicitly state "Do NOT commit. Do NOT modify any other file"; (c) include a "Report under N words" upper bound on the subagent's final message. Briefs lacking (a) cause directory drift when the subagent's working directory differs from the parent's; briefs lacking (b) cause cross-spec edits when subagents share a worktree; briefs lacking (c) inflate the parent context with verbose intermediate reports.

*Grounded in: 2026-05-25 session 49-subagent Phase 0 fanout where this discipline kept all 49 outputs in clean, non-overlapping files.*

# justification

The 2026-05-25 session dispatched 49 background subagents in parallel — 34 authoring new specs and 15 augmenting existing specs. Every brief followed the discipline: an absolute output path (`/home/user/k8-platform/ai/brainstorming/specs/SPEC-<id>-<slug>.md`), a hard prohibition on committing or modifying any other file, and a tight word cap on the final report. Result: all 49 subagents wrote exactly the files they were assigned to; no spurious commits; no cross-file conflicts; the parent context was protected from 49 long-form summaries.

The cost of the discipline is one extra paragraph in each brief — under a minute of brief-authoring time. The cost of skipping it: the agent has seen prior sessions where a subagent without (a) wrote to a relative path that resolved against a different CWD; where a subagent without (b) "helpfully" modified an adjacent file and clobbered another subagent's work; where a subagent without (c) returned a 2000-word essay that flooded the parent's context. The asymmetry is decisive: one paragraph upfront vs hours of cleanup downstream.

This rule pairs with the "Batch-commit during high-fanout subagent waves" rule (`AGENTS-MD-97813da854`): the no-commit prohibition is what makes batch-commit work — only the parent commits, in batches, with coherent commit messages.
