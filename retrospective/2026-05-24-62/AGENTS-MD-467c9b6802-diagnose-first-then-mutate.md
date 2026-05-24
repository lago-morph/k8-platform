# agent instruction

**§6.X — Diagnose before any mutating op >5 minutes.** Before dispatching any cluster-mutating workflow whose runtime exceeds 5 minutes (apply-and-verify, teardown-rebuild, EKS provisioning), the agent MUST dispatch a read-only diagnostic first to verify the pre-state. The diagnose's evidence MUST be quoted in the announcement of the mutating dispatch.

*Grounded in: phase=management apply-and-verify dispatched against an unfixed phase-2 state; 15 min of CI wasted before the policy-09 admission failure surfaced. A 2-min diagnose would have caught it.*

# justification

Mutating operations on the live cluster cost: real $$, real time, occasional cleanup work, and agent context. The cheapest precaution — a read-only diagnose — is at least 5× faster than the operation it gates and catches the majority of preventable failures. This session has the bug-of-record.

---
