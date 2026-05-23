# Spec: `ci-on-every-push`

## Intent

Workflows configured as `workflow_dispatch`-only let broken code sit on main between manual dispatches, undetected. This session found a `$SELECTOR` typo in `scripts/diag-component.sh` that had been on `main` for an unknown number of sessions — caught by audit, not by CI, because the only workflow that exercised the unit suite ran on dispatch and the script was rarely touched. After fixing the typo, the obvious follow-up was a workflow that runs unit tests on every push to a non-main branch (PR #47), and a parallel one for `terraform fmt + validate` (PR #48). The fmt workflow's first run on the next push immediately surfaced pre-existing alignment drift in `terraform/base/vpc.tf` and four management files.

The lesson: per-language quick checks should fire on **every push to a feature branch**, not on manual dispatch. The cost is low (a few seconds of GH-hosted runner per push); the value is high (broken-on-main has a finite half-life).

This skill is the scaffolding template + a checklist for what such a workflow needs.

## Trigger

**Direct phrases**: "add a CI workflow for X on every push", "we should run the unit tests in CI", "I want quick checks on every push".

**Proactive trigger**: when a session involves authoring or fixing unit tests / lint rules / formatters for a project whose only CI is workflow_dispatch-only, suggest this skill.

**Negative trigger**: workflows that need AWS / GCP / Azure credentials or take >10 minutes — those belong in workflow_dispatch (cost, secret-exposure, runner-time).

## Inputs

- Programming language / toolchain target (Python, bash, terraform, helm, kubectl, …).
- The path glob(s) to filter on (the workflow shouldn't fire on every PR).
- The test/lint command(s) to run.
- Any known pre-existing failures that should be tolerated with `continue-on-error: true` for now.

## Outputs

- A new `.github/workflows/<name>.yml` file.
- Filename matches a single concern (e.g. `unit-tests.yml`, `terraform-validate.yml`).

## Workflow

1. Pick the workflow file path. Single-concern names: `<thing>-<verb>.yml` or `<thing>.yml` for short. Avoid bundling multiple concerns into one workflow.
2. Author with this shape:
   ```yaml
   name: <Human name>
   on:
     push:
       branches-ignore:
         - main
       paths:
         - "<the language's source dir>/**"
         - ".github/workflows/<self>.yml"   # self-trigger when the workflow is edited
     workflow_dispatch:   # always include for manual reruns
   concurrency:
     group: <name>-${{ github.ref }}
     cancel-in-progress: true
   permissions:
     contents: read
   jobs:
     <job>:
       runs-on: ubuntu-24.04
       timeout-minutes: 10
       steps:
         - uses: actions/checkout@v4
         - <toolchain-install steps>
         - <one step per test file or sub-command>  # NOT one monolithic run.sh step
   ```
3. **One step per test or sub-command**. The GH Actions UI shows each step's status separately; bundling into one `run.sh` step hides which test failed.
4. **Known-broken tests get `continue-on-error: true`** with a comment explaining why and a TODO. Don't disable them entirely (that loses signal); don't gate the workflow on them (that breaks every PR until fixed).
5. **Phase / forward-compatibility guards** for tests that only exist on certain branches:
   ```yaml
   - name: test_x
     run: |
       if [ -f tests/unit/test_x.sh ]; then
         bash tests/unit/test_x.sh
       else
         echo "(test_x.sh not on this branch — skipped)"
       fi
   ```
6. **Self-trigger via path filter**: include the workflow file itself in `paths`. A typo in the path filter is silent otherwise.
7. **Tight concurrency**: `cancel-in-progress: true` keyed on `github.ref` — a force-push or rapid pushes to the same branch don't queue multiple wasted runs.
8. **Minimal permissions**: `contents: read` is enough for most lint/test workflows. No need for `pull-requests: write` unless the workflow posts comments.

## Concrete examples

### Example 1 — unit tests workflow (this session's PR #47)

`tests/unit/run.sh` is monolithic. Workflow runs each test file as its own step:

```yaml
- name: test_compute_gates
  run: bash tests/unit/test_compute_gates.sh
- name: test_irsa_helm_linkage
  run: bash tests/unit/test_irsa_helm_linkage.sh
# ... etc
- name: test_helm_render (continue-on-error — pre-existing argocd assertions broken)
  run: bash tests/unit/test_helm_render.sh
  continue-on-error: true
# Phase-2a guards
- name: test_chainsaw_kind_config
  run: |
    if [ -f tests/unit/test_chainsaw_kind_config.sh ]; then
      bash tests/unit/test_chainsaw_kind_config.sh
    else
      echo "(test_chainsaw_kind_config.sh not on this branch — skipped)"
    fi
```

### Example 2 — terraform validate workflow (this session's PR #48)

Matrix over modules, fail-fast=false so a fmt drift in one doesn't suppress the other module's signal:

```yaml
strategy:
  fail-fast: false
  matrix:
    module: [base, management]
defaults:
  run:
    working-directory: terraform/${{ matrix.module }}
steps:
  - uses: actions/checkout@v4
  - uses: hashicorp/setup-terraform@v3
    with:
      terraform_version: "~1.6"
      terraform_wrapper: false
  - name: terraform fmt -check -diff
    run: terraform fmt -check -recursive -diff
  - name: terraform init (no backend, no AWS)
    run: terraform init -backend=false -input=false
  - name: terraform validate
    run: terraform validate -no-color
```

`terraform init -backend=false` is the key — no AWS creds needed; just downloads providers from public registry.

## Anti-patterns

- **Don't run on `main` pushes** — `branches-ignore: [main]` saves runner time and avoids confusing red checks on main itself. (Main shouldn't have broken code; if it does, you have a bigger problem than a CI check.)
- **Don't omit the path filter**. Every push to every file fires every workflow ⇒ noisy and slow. Path filters are how you keep the unit-test workflow from firing on docs-only PRs.
- **Don't omit the self-trigger** (the workflow file in its own paths). A typo in the path filter is invisible otherwise.
- **Don't bundle into one `run.sh` step**. Per-step granularity is the UI affordance that makes failures diagnosable.
- **Don't outright disable a broken test**. `continue-on-error: true` keeps the signal in the run summary (yellow ⓘ) and forces a follow-up fix; deleting the test loses the contract.
- **Don't add secrets unless you need them**. Lint/format/static-analysis checks should run without any. If you need creds, you're probably in `workflow_dispatch` territory, not push.

## Acceptance criteria

1. Workflow YAML parses (`python3 -c "import yaml; yaml.safe_load(open('<path>'))"`).
2. Workflow fires on a feature-branch push that touches the path filter; doesn't fire on a docs-only push.
3. Each test/check is its own step.
4. Known-broken tests are tolerated with `continue-on-error: true` and an inline TODO.
5. Workflow file path appears in its own `paths` filter.

## Files this skill creates / modifies

- `.github/workflows/<name>.yml` — new workflow file.
- Optionally: a short note in `ai/handoff.md` or wherever known-broken-tolerated tests are tracked.
