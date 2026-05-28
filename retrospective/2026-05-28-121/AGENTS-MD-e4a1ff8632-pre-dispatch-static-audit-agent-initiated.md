# agent instruction

**Pre-dispatch static audit is mandatory before every agent-initiated chainsaw.yml dispatch.** Before any `mcp__*__execute` call (or `gh workflow run`) that targets `chainsaw.yml`, run `scripts/pre-chainsaw-audit.sh` from the repo root, read the output, and fix every FAIL before dispatching. AGENTS.md §6.13 sets this rule for user-initiated dispatches; it applies equally to agent-initiated dispatches even when the agent's working text doesn't match the `pre-dispatch-static-audit` skill's trigger phrases.

*Grounded in: PR #111 chainsaw rounds 1-4 (2026-05-28), each surfacing a different bug class the audit script encodes.*

# justification

PR #111's chainsaw fix took four cloud-CI iterations (~25 minutes total) to land green. Rounds 1 and 2 (missing 3-condition assert; `set -o pipefail` under `/bin/sh`) are exactly two of the six checks that `scripts/pre-chainsaw-audit.sh` already encodes — running the audit once before the first dispatch would have flagged both in seconds and collapsed two rounds into zero. The script exists. AGENTS.md §6.13 mandates it for user-initiated chainsaw dispatches. The `pre-dispatch-static-audit` skill catalogs it. None of those fired because the agent's working text ("dispatching chainsaw against PR #111 with `scenario_filter=...`") didn't match the skill's user-facing trigger phrases ("dispatch chainsaw", "kick off chainsaw"), and the agent didn't re-read §6.13 at dispatch time. The marginal cost of adopting the rule is one bash invocation per chainsaw dispatch — ~3 seconds. The cost of not adopting it, paid this session, was ~15 minutes of unnecessary iteration plus the cognitive load of peeling off bugs one at a time. The asymmetry is overwhelming.
