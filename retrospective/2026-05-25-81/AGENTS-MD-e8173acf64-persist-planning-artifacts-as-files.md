# agent instruction

**Persist user-facing planning artifacts as files.** When the user requests a plan, design document, prompt template, or other reviewable artifact, write it to a file in the repo BEFORE summarizing in chat. Chat is ephemeral; the file is the durable artifact that survives context truncation and re-grounds the next session. This applies even when the user has not explicitly said "write a file". Exception: trivial responses (one paragraph, no structure) stay in chat.

*Grounded in: 2026-05-25 session where IMPLEMENTATION-PLAN.md and PHASE-1-2-AGENT-PROMPT.md were created as files; the prompt file is now what the user will copy-paste into the next session.*

# justification

The 2026-05-25 session produced two major planning artifacts: `IMPLEMENTATION-PLAN.md` (8-phase pipelined rollout for 49 specs) and `PHASE-1-2-AGENT-PROMPT.md` (copy-pastable kickoff for the next session). Both were committed to the repo as durable files. The chat-summary versions were short pointers to those files, not duplicates.

This pattern is what makes the next session work. When the user starts the Phase 1+2 implementation session, they will copy-paste the inner block of `PHASE-1-2-AGENT-PROMPT.md` — a file that survived this session's context window because it lives in git. If the prompt had been only in chat, the user would have had to dig through this session's transcript to find it, or worse, ask the next agent to re-derive it.

Cost of the rule: file write + commit instead of chat output — under 30 seconds. Cost of not having it: context-truncated sessions cannot recover the artifact; the user has to re-explain or the agent has to re-derive. The asymmetry is brutal: the agent's chat output costs are charged once per session and burn context for everyone else in the session; a committed file is read on demand and free thereafter.

The rule is broad: it applies to plans, prompts, runbooks, design notes, ADR drafts — anything the user might want to reference in a future session. The narrow exception (trivial responses stay in chat) is to avoid bloating the repo with one-paragraph utterances that genuinely belong in conversation.
