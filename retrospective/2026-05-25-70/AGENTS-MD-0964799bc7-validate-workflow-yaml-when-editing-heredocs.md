# agent instruction

**Validate workflow YAML after any heredoc edit.** When editing a `.github/workflows/*.yml` file in a way that touches a `run: |` block — embedded scripts, inline Python, jq filters, `<<-EOT` style heredocs — run `python -c "import yaml; yaml.safe_load(open('<path>'))"` before pushing. GitHub Actions silently refuses to register a workflow that doesn't parse, and the dispatch API returns the misleading error `"Workflow does not have 'workflow_dispatch' trigger"` regardless of the actual cause. Consequence: any non-default-branch dispatch of the edited workflow will fail with a confusing error until the YAML is fixed.

*Grounded in: PR #65 — an unindented Python heredoc inside a `run: |` block terminated the YAML literal early; dispatch of the enhanced phase-2-diagnose against the branch failed for ~10 minutes with the misleading trigger error.*

# justification

This rule has the highest signal-to-cost ratio of any in the session. Marginal cost: one `python -c yaml.safe_load` invocation per workflow-file edit (≤200 ms). Cost of skipping: ~10 minutes of "why is dispatch returning a trigger error when the trigger is literally on line 18" confusion, plus an extra PR to repair the parse error before any further verification is possible. The misleading dispatch error message is the trap — without YAML-validating locally, the symptom does not point at the cause. The rule also catches the related class of bugs in `run: |` blocks (unindented body, missing block scalar marker, tab-vs-space mixing) that GitHub Actions handles in the same silent-rejection way.
