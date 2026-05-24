# agent instruction

**§6.X — Verify by evidence, not by wrapper exit code.** For any action whose granularity is finer than its outer success indicator (workflow_dispatch, PR merge, kubectl apply, ArgoCD sync, AWS describe), the agent MUST quote a verbatim line of the underlying evidence — a log line, a status condition, an API response field — before reporting the action as "done", "verified", or "successful". Wrapper success is necessary but NOT sufficient. Scripts can pass-on-fail; workflow steps can succeed while the assertion they wrap fails; PR merges can stall mid-merge. If the evidence quote is not in the response, the verification has not happened.

*Grounded in: integration-tests run 26347839740 reported `conclusion: success` while four wait_for calls timed out and the K8s Secret never materialized. The agent reported "Phase 2a is genuinely verified"; it was not.*

# justification

The session lost ~45 minutes and significant user trust on a single instance of this failure mode. The agent read `conclusion: success` from a workflow_dispatch and reported phase-2 verified; the user pushed back, the agent re-read the log, and found the script lying due to a missing `set -e` and a `$UID` shadow bug. That bug had been present in the codebase the entire prior session, never caught. The rule's cost is one extra grep + one extra quote per outcome claim — measured in seconds. The rule's value is the catch rate on every silent-PASS bug class, of which we know at least the bash-script flavour exists in the codebase right now.

---
