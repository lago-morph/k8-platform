# agent instruction

**Never pre-stage a self-gating SKIP-until-reachable stub for deferred coverage.** "Deferring a behavioral check by committing a stub that SKIPs until some precondition is met re-introduces the silent-skip-reads-green disease: an all-skipped-RED floor is suite-level, and a non-COVERS SKIP never triggers expect-full promotion, so the stub rots green for months. Defer with an open-issue entry instead; ship the check as a HARD gate when the precondition is met."

*Grounded in: auto-014 decision brief auto-014-003, where a reviewer showed a self-gating hub-to-spoke curl stub would sit SKIPping undetected because run.sh's all-skipped floor is suite-level.*

# justification

A self-gating stub feels responsible — "the check exists, it'll run once reachable" — but it is the exact failure ADR-0006 was written to kill. Verified against the orchestrator: the all-skipped-RED floor fires only when the WHOLE suite has zero passes, and a SKIP that emits no COVERS line never enters the expect-full promotion path. So a single stub in a suite with other passing checks SKIPs silently, forever, while the suite reads green and a human reviews nothing. A deferred gap belongs in `docs/open-issues.md`, where a human reviews it, plus a plan to ship the real check as a HARD gate (non-zero on a reachable-but-failing condition). The cost is an OI entry; the cost of the stub is months of fake coverage nobody notices.
