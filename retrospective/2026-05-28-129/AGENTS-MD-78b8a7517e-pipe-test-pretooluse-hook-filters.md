# agent instruction

**Pipe-test PreToolUse hook filters with dispatch and read shapes.** When wiring a PreToolUse hook that gates an `mcp__*__execute` matcher, pipe-test the wrapper command against at least three synthetic JSON inputs before pushing: (a) a non-MCP tool call, (b) an `mcp__*__execute` *read* operation that mentions the gated resource (e.g. `list_workflow_runs` targeting `chainsaw.yml`), and (c) the actual *dispatch* operation. Confirm the wrapper only fires on (c). The filter must distinguish the dispatch UUID from any read query that happens to name the same workflow.

*Grounded in: 2026-05-28 PR #125 audit hook over-filtered on `chainsaw.yml` substring and blocked `list_workflow_runs` on PR #128 review; PR #128 fix narrowed to `op_2acb005c9f3704ad`.*

# justification

The PR #125 hook's filter was `tool_input contains "chainsaw.yml"`. That matched the actual workflow_dispatch (correct) AND every subsequent `list_workflow_runs`, `list_jobs_for_workflow_run`, and `download_job_logs` call that named the workflow (incorrect — these are reads that don't provision anything). The first time I needed to inspect a chainsaw run's status, the hook blocked the read query and the audit ran against an unrelated PR's working tree. I spent 5 minutes diagnosing the false-positive before realizing the filter was over-broad. The marginal cost of pipe-testing three synthetic inputs is ~30 seconds with `echo '...' | bash wrapper.sh` per input; the cost of NOT pipe-testing is the same 5-15 minutes I spent unwinding the hook's misfire, multiplied by the number of agents who'd hit it in the field. The fix was a one-line change to require both the dispatch UUID AND the workflow name in the filter — a check that the pipe-test would have surfaced in the first session.
