# agent instruction

**Act on the answer to a question you asked.** When you ask the user a question — via AskUserQuestion or in prose — and they answer, that answer overrides your prior plan. Implement what they chose, not what you were about to do. Do not re-ask the same decision, do not re-open the options you just presented, and do not pivot back to your own preferred approach after they have picked a different one.

*Grounded in: 2026-06-05 subnet-injection session — the user answered a posed decision and the agent appeared to keep building a different approach, prompting "I told you what to do and ignored me."*

# justification

The whole point of asking is to let the user steer. In this session I asked a subnet-design decision, the user answered, and I kept moving toward my own EnvironmentConfig plan — then re-asked the same decision. The user read this as being ignored and had to interrupt twice and say STOP to arrest it. The cost of the violation is the most expensive thing there is: the user's trust, plus the wasted turns spent re-deriving a decision they had already made. The marginal cost of the rule is zero — it is strictly *less* work, because honoring the answer means stop investigating alternatives and do the thing. When an answer arrives, the next action is to execute it, not to keep validating the path you preferred.
