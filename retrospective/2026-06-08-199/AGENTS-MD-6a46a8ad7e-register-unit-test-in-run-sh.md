# agent instruction

**Register a new unit test in tests/unit/run.sh; the catch-all step gates it.** "Adding `run_suite tests/unit/test_X.sh` to tests/unit/run.sh is sufficient to gate a new unit test on push, because unit-tests.yml runs a run.sh catch-all step that is the source of truth for completeness. A per-test workflow step is optional visibility only, and editing .github/workflows/ may be blocked by the push token's missing workflow scope."

*Grounded in: auto-014, where two new unit tests (account-mutex, reaper-select) were gated by adding them to tests/unit/run.sh without touching the workflow.*

# justification

It is easy to assume a new test must be added to the CI workflow YAML to be gated — and in this repo that assumption both wastes effort and can hit a wall: the push OAuth token lacks the `workflow` scope, so a `.github/workflows/` edit is rejected. The workflow is deliberately structured so a final `run.sh catch-all` step runs every test wired into `tests/unit/run.sh` and is the documented source of truth for completeness; the per-test steps are convenience for failure visibility. So one line in `run.sh` is necessary and sufficient to make a test required-to-pass on push. The rule saves the dead-end of trying to push a workflow edit and the risk of an un-gated test slipping through because someone only added the convenience step.
