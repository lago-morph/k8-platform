# agent instruction

**Every test in `tests/unit/run.sh` MUST also be enumerated in `.github/workflows/unit-tests.yml`'s per-step list, OR the workflow must end with a `run.sh` catch-all step that invokes it.** Per-step CI is preferred for separate-failure diagnosability but silently drifts when tests are added to `run.sh` without a paired workflow edit. The catch-all alternative trades UI clarity for guaranteed coverage. Either pattern is acceptable; the gap between them is not.

*Grounded in: 2026-05-28 audit found 17 of 39 tests in `tests/unit/run.sh` missing from `unit-tests.yml`'s per-step list, including the two enforcers whose absence caused PR #111's chainsaw rounds 1-2 (POSIX-sh + 3-conditions).*

# justification

`test_chainsaw_script_shell_portable.sh` and `test_chainsaw_xr_conditions_complete.sh` were both added to `tests/unit/run.sh` in recent PRs as TDD regression gates for the exact bug classes PR #111 hit. Both were correctly scoped, both pass locally — and neither was in the CI workflow's per-step list. PR #111's HEAD `9addd6d` had a green `unit-tests` check despite the local enforcers being red, because CI didn't run the enforcers. The result: two chainsaw rounds (~10 minutes of cloud-CI time + agent context) re-discovering bugs the enforcers were authored specifically to catch. The fix is one of: (a) add a final `- name: run.sh catch-all` step that invokes `tests/unit/run.sh` — guarantees coverage forever, accepts that per-test failure UI lives behind that one step; (b) add each missing per-step entry now and a CI-completeness test that fails when `run.sh` and `unit-tests.yml` drift apart. Either way, the contract is single-source-of-truth: a test in `run.sh` is enforced on push, or the agent must intentionally and visibly opt it out.
