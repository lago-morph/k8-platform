# agent instruction

**§6.6 (extension) — AWS account change is a hard stop condition.** Even under throughput-without-attention mode, a change of AWS account (or its credentials) halts the agent. The agent MUST re-confirm scope, secrets rotation, and Route53 hosted-zone presence with the user before resuming any dispatch.

*Grounded in: AWS account `309191981509` torn down mid-session; the agent's behaviour in that moment was ambiguous between "ask first" (correct) and "throughput mode says press on" (would be catastrophic if the new account's secrets weren't rotated).*

# justification

Throughput mode is grant-once. An account change can invalidate everything the prior grant assumed (state backends, IRSA scope, Route53 zone, IAM policies, even cluster name semantics). The rule is fail-safe — when in doubt, ask. The cost is one extra confirmation per account change (rare). The cost of not having it is potentially destructive dispatches against an account the agent doesn't fully understand.

---
