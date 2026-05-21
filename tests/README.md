# Tests

The harness that the agent uses to drive Terraform — workflow gates,
trigger-file parsing, the `.github/scripts/*` helpers — has its own
unit and e2e suites. They live here so the agent (and reviewers) can
run them locally and so CI can exercise them via the `phase=test`
dispatch path.

See `ai/testing-guidelines.md` §9 for the full doctrine.

## Layout

```
tests/
├── lib/
│   └── assert.sh                 # shared helpers (assert_eq, assert_contains, ...)
├── unit/
│   ├── run.sh                    # entry point: runs all test_*.sh
│   ├── test_parse_trigger.sh     # validates .github/scripts/parse-trigger.sh
│   ├── test_compute_gates.sh     # validates .github/scripts/compute-gates.sh
│   └── fixtures/                 # canonical .trigger-action.json bodies
└── e2e/
    ├── run.sh                    # entry point; needs AWS creds in env
    ├── test_aws_creds.sh         # sts:GetCallerIdentity must work
    ├── test_route53_zone.sh      # a public hosted zone must exist
    └── test_state_backend.sh     # bootstrap-created bucket + lock table
```

## Run locally

Unit tests (no AWS, pure bash + jq):

```bash
tests/unit/run.sh
```

E2e tests (requires AWS env):

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
tests/e2e/run.sh
```

## Run in CI

Either dispatch from the Actions UI:

```
Actions → Terraform Test → Run workflow
  phase  = test
  action = test-unit   # or test-e2e
```

Or, from the agent, write `.trigger-action.json` with that pair and push.
The Agent Trigger workflow picks it up. See `ai/testing-guidelines.md` §8.

## Adding a test

Unit suite — write a new `tests/unit/test_<thing>.sh`:

1. `set -uo pipefail; cd "$(dirname "$0")/../.."`
2. `. tests/lib/assert.sh`
3. Use `_pass`, `_fail`, `assert_eq`, `assert_contains`, `assert_exit_code`
4. End with `assert_summary`
5. Register it in `tests/unit/run.sh`'s `run_suite` calls

E2e suite — same pattern, but the test may read AWS state via `aws` CLI.
Keep e2e tests read-only; mutating tests belong inside the corresponding
phase's `apply` flow, not here.
