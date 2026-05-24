# agent instruction

**§6.X — When a workflow has multiple steps, read the LOG of the step you care about, not the workflow's overall conclusion.** GitHub's "workflow succeeded" badge means "every required step exited 0", which includes steps with `continue-on-error: true`. To know whether step N actually achieved its intent, read step N's log directly via the `list_jobs_for_workflow_run` → `download_job_logs` pair.

*Grounded in: `tests/unit/test_helm_render.sh` is set `continue-on-error: true` in unit-tests.yml; every CI run claims "success" even though 4 assertions fail every time. An agent reading the badge alone would never know.*

# justification

The rule applies whether or not the project uses `continue-on-error`. The cost is one extra MCP call per verification (~2s). The value is no false-confidence reports.

---
