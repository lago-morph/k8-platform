# agent instruction

**Use `Bash` with `run_in_background: true` for single-notification waits; reserve `Monitor` for streams of multiple events.** A Monitor that just sleeps and ticks is an anti-pattern — every tick is a chat-visible notification, the monitor doesn't end on the event you care about, and there is no surfaced way to stop it early. For "tell me when X completes", use `Bash` with `run_in_background: true` and an `until` loop that exits when the condition is met.

*Grounded in: 2026-05-28 chainsaw-verify wait — armed a Monitor as a generic ticker, received 29 useless tick notifications before timeout.*

# justification

After re-dispatching `chainsaw-verify.yml` for SHA `ef410ac`, the agent needed exactly one notification: "the verifier finished". It armed `Monitor` with a `while true; sleep 6; echo tick; done` body — but Monitor emits each stdout line as a notification, so every tick polluted the chat. The agent had no `TaskStop` tool available in the loaded set; the monitor ran out its 180-second timeout, producing 29 useless tick events. The correct tool for "one notification when condition is met" is `Bash` with `run_in_background: true` and an `until <check>; do sleep 2; done` body — it exits on success and emits exactly one completion notification. The Monitor tool description explicitly calls this out ("Don't use an unbounded command for a single notification"), but the discipline failed in practice. Codifying the rule in AGENTS.md gives every future session a check at tool-choice time, before the noise materializes. The cost of adoption is zero (it's a tool-selection rule, not new infrastructure); the cost of forgetting it is N chat notifications and the cognitive overhead of recognizing and ignoring each.
