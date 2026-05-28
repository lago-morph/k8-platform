# agent instruction

**`[Request interrupted by user]` is a hard stop.** "When the harness delivers a `[Request interrupted by user]` system message, do NOT pivot into an adjacent task ('let me do this small thing instead', 'while I have you'). Stop the current activity, do not start a new one, and wait for the user's next explicit direction. Background processes the agent had started prior to the interrupt should be killed if they continue to consume model context or registry/API quota. Treat the interrupt the same way a SIGINT from a terminal would be treated by an interactive program: full halt."

*Grounded in: auto-003 post-retro phase, where `[Request interrupted by user]` fired twice and the agent both times continued with a small adjacent task; the user replied "you keep doing things even when I push stop."*

# justification

A user who has just hit stop wants the agent stopped, not redirected. Pivoting after interrupt makes the next user-action a second interrupt — they have to spend attention on getting the agent to actually halt before they can communicate the new direction. In the auto-003 session it happened twice in roughly thirty minutes and was a direct precursor to the user's explicit escalation. Cost of adopting: zero — the rule is "do nothing on interrupt and wait." Cost of not adopting: the user's escalation slope steepens, and trust in the agent's responsiveness to stop signals degrades for the rest of the session.
