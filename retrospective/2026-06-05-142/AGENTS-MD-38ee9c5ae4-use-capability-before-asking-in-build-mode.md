# agent instruction

**In a delegated/long build session, exhaust available tools and make a defensible call before asking the user.** "When the user has delegated execution (build everything tested, use the skill, go), do not stop on an `AskUserQuestion` for something a tool or a defensible default can resolve — check the capability first (dispatch the probe, try the install, read the output) per §6.12/§8.5. Reserve user questions for genuine forks with cost/irreversibility and no defensible default. Asking when the path was available reads as not-listening and wastes a round-trip."

*Grounded in: 2026-06-05 auto-005 — the agent asked about creds/mechanism the user expected it to resolve itself (check yourself, use it).*

# justification

The user pushed back repeatedly — "The credentials are current. In the future check yourself", "use it", and an explicit "Stop" — whenever the agent asked or assumed instead of using a capability it had (dispatching a workflow to check creds, or driving Actions via ext-github). In a delegated build session an unnecessary question is both a round-trip cost and a trust cost ("I told you what to do and ignored me"). The rule's marginal cost is a few seconds of "can I resolve this myself first?"; the cost of over-asking is user frustration and stalled throughput.
