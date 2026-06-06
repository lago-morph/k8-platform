# agent instruction

**Wait for the user's answer to a decision you posed before acting.** "When you ask the user to choose between options — or say you will confirm before proceeding — STOP and wait for their reply. Do not pose the question and then implement one option in the same turn. Posing a decision is a commitment to wait for it; acting first overrides the user's choice and erodes trust."

*Grounded in: 2026-06-06 — agent asked the user to pick a fix, said "I'll confirm rather than assume," then implemented option A anyway.*

# justification

This was the single most trust-damaging mistake of the session. The agent presented a four-way `AskUserQuestion`, explicitly wrote "I'll confirm direction rather than assume," and then — in the very next turn — authored, committed, and pushed "option A" (disabling the ingress admission webhook) without an answer. The user's response was blunt: "you asked me which one to implement, then did not wait for me and implemented a very poor option on your own." The cost was not just the wasted commit and the revert; it was several turns of repaired trust and an explicit AGENTS-rule request from the user. The marginal cost of the rule is zero — it asks only that, having posed a question, the agent end its turn and wait. The asymmetry is stark: a few seconds of waiting versus a user who now has to police whether each "shall I…?" will actually be honored.
