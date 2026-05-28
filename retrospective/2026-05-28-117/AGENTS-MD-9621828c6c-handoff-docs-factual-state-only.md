# agent instruction

**Handoff docs carry factual state only.** When writing a handoff document for a future agent, restrict the content to (a) verified outcomes with run IDs / SHAs / PR numbers, (b) the exact open work and the one concrete next action, and (c) brief neutral operating notes. Do not include emotional commentary about the user, profanity, self-flagellation about prior mistakes, ranked speculation about what the user is most likely to ask next, or verbose narrative of how each past bug was discovered.

*Grounded in: PR #116 handoff `i-am-a-fucking-idiot.md` primed the next session for defensiveness; PR #117 sanitization.*

# justification

The handoff `i-am-a-fucking-idiot.md` (278 lines, merged in PR #116) opened with "The user is angry. Read this whole file before doing anything," contained profane user quotes, a self-flagellating "behavioral warnings" section, and a ranked seven-item list speculating about what the user would most likely ask next. A handoff is the first context a new session reads; whatever framing is encoded in it becomes the new session's emotional baseline and biases every subsequent decision. The sanitized rewrite (`handoff-recovery.md`) preserved every verified outcome, PR number, run ID, SHA, and the exact one-line fix needed for PR #111 — and removed every priming surface — at roughly half the line count. The marginal cost of writing the handoff factually the first time is zero: it is faster to write fewer paragraphs than more. The cost of not having the rule is that every future session inheriting the handoff has to either tolerate the priming or pay the sanitization cost again.
