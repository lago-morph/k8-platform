# SPEC-D5 — pre-commit + pre-push hooks: replace terraform-validate + unit-tests CI workflows

Brainstorm IDs: A6-022, A6-023 (cross-comments A1→A6-006, A3→A6-005, A3→A6-006, A2→A6-013).

## 1. Summary

Move the two CI workflows that guard local-authoring mistakes —
`terraform-validate.yml` (terraform fmt + validate) and `unit-tests.yml`
(bash unit test suite) — into git hooks that run before the commit and push
respectively, so failures are caught in the developer's terminal rather than
in a GitHub Actions notification minutes later. A pre-commit hook runs
`terraform fmt -check -recursive -diff && terraform init -backend=false &&
terraform validate` against changed Terraform modules; a pre-push hook runs
`tests/unit/run.sh`. Both are installed via `make hooks-install`. The two
existing per-branch-push workflows are deleted. A new slim workflow —
`ci-main-gate.yml` — runs the same two suites on every push to `main`, so
breakage introduced by a contributor who skipped local hooks is still caught
before it poisons the shared branch (per the A3→A6-006 cross-comment
constraint). This spec is part of the Tier D housekeeping cluster.

## 2. Retro pain killed

- **CI-wall-clock tax, every push.** Both workflows run on ubuntu-24.04 with
  provider download (`terraform init`) and yq/helm install steps. The
  validate matrix (two modules) and unit suite together account for roughly
  30 s of CI wall-clock per push on a feature branch. Over a session with
  ~20 pushes that is ~10 min of queued wait time that yields no information
  beyond "you could have checked this locally". Documented in the A6-022
  and A6-023 `justification` fields of `ai/brainstorming/brainstorm.json`.
- **"The lint failed" notification noise.** A formatting nit in a `.tf` file
  causes a GitHub email and a red PR badge. The author must re-read the diff
  to learn it was just whitespace. This is a signal-to-noise issue: CI
  annotations should surface things the local environment cannot check, not
  things `terraform fmt` or `bash tests/unit/run.sh` surface in under five
  seconds.
- **Original guardrail rationale is obsolete.** `unit-tests.yml`'s opening
  comment (`unit-tests.yml` line 6–7) states explicitly that the workflow
  exists because the agent "couldn't run bash unit tests locally — no longer
  true." `terraform-validate.yml`'s comment (line 7) states the same for
  terraform. The A6-022 and A6-023 `justification` fields in
  `ai/brainstorming/brainstorm.json` cite the same obsolescence.
- **Works-on-my-machine gap without minimum CI.** A3→A6-006 cross-comment
  identifies that removing `unit-tests.yml` entirely would create a class of
  "other contributor's push on main passes locally but breaks `run.sh`" bugs
  with no automated catch. The minimum-CI-on-main retention in §9 closes
  this gap.
- **Pre-commit hooks are bypassable; no bypass evidence without CI.** The
  A3→A6-005 cross-comment and A1→A6-006 cross-comment both flag that
  `--no-verify` can skip local hooks with no trace. The minimum-CI-on-main
  workflow doubles as the bypass detector.

## 3. Out of scope

- **Running integration tests as a hook.** Integration tests require a live
  cluster and AWS credentials; they cannot run locally on commit or push in
  any reasonable time budget. Pre-push is for the unit suite only.
- **Running chainsaw tests as a hook.** Same reason — kind cluster spin-up
  is minutes, not seconds.
- **Enforcing hook installation via CI.** Detecting whether a pushed commit
  was produced without running local hooks (e.g. a timestamp-based sentinel
  file) is complexity that does not pay for itself: the minimum-CI-on-main
  workflow already catches the output of bypass, not the act of bypassing.
- **Converting to the `pre-commit` Python framework** (the third-party
  `.pre-commit-config.yaml` tool). The framework requires a separate install
  step and a Python runtime, introduces a new dependency class, and is not
  referenced elsewhere in the repo. Plain shell hooks installed by `make
  hooks-install` are sufficient and consistent with the rest of the bash
  toolchain.
- **Parallelising unit tests under `make -j$(nproc)`.** The A5→A6-004
  cross-comment suggests this as a follow-on; this spec does not pursue it
  because `tests/unit/run.sh` is already fast enough (<5 s locally) and
  parallelism adds complexity to error reporting.
- **Rewriting `tests/unit/run.sh`** into a bats runner (brainstorm ID
  A6-024-area). Different scope; that spec would modify the runner
  independently of hook wiring.

### Considered and rejected

- **Keep `unit-tests.yml` but reduce its triggers** (e.g. path filters).
  Rejected: the only paths that would matter are `tests/` and `scripts/`,
  but the existing workflow has no path filter and adding one creates a
  false-green trap for tests that check files outside those paths. Replacing
  with a pre-push hook and a main-gate is cleaner.
- **Server-side hook that emits `validate-result.json`** (A1→A6-006).
  Rejected for this spec: GitHub does not expose custom server-side hooks in
  the standard repository model. A GitHub Actions check accomplishes the
  same audit-trail goal with less infrastructure.
- **Pre-commit for unit tests and pre-push for validate.** Inverted
  placement. Unit tests can be slow enough (5 s) that running on every
  commit is annoying; validate (including provider download) is also
  unsuitable for pre-commit given cold-cache `terraform init`. Both are
  better placed at pre-push where the cost is amortised over a batch of
  commits.

## 4. Files to change / create

**Create:**

- `/home/user/k8-platform/scripts/hooks/pre-commit` — shell script; runs
  `terraform fmt -check -recursive -diff` against each changed Terraform
  module (git diff --name-only HEAD identifies changed modules).
- `/home/user/k8-platform/scripts/hooks/pre-push` — shell script; runs
  `tests/unit/run.sh` from repo root.
- `/home/user/k8-platform/.github/workflows/ci-main-gate.yml` — slim
  workflow that runs both suites on `push: branches: [main]` and
  `workflow_dispatch`.
- `/home/user/k8-platform/tests/unit/test_hooks_smoke.sh` — unit-level
  smoke test verifying that each installed hook script is executable, has
  the correct shebang, and contains the expected invocation string.

**Modify:**

- `/home/user/k8-platform/Makefile` — add `hooks-install` target (and
  `hooks-uninstall` for symmetry).
- `/home/user/k8-platform/AGENTS.md` — §6.1 table: add a row for the
  pre-push hook; §3 or a new §3.1: note `make hooks-install` as a
  one-time setup step.
- `/home/user/k8-platform/tests/unit/run.sh` — add `run_suite
  tests/unit/test_hooks_smoke.sh` line.

**Delete:**

- `/home/user/k8-platform/.github/workflows/terraform-validate.yml`
- `/home/user/k8-platform/.github/workflows/unit-tests.yml`

Both deletions happen in the same PR as the hook creation and
`ci-main-gate.yml` addition, so no window exists where the old workflows
are gone but the replacement is not yet live.

## 5. Implementation notes

### 5.1 pre-commit hook

`scripts/hooks/pre-commit` — bash, `set -euo pipefail`:

1. Derive changed Terraform modules from `git diff --cached --name-only`
   filtered to `^terraform/(base|management)/`.
2. If no modules are staged, exit 0 immediately (fast-path).
3. For each changed module run `terraform -chdir="$module" fmt -check
   -recursive -diff`. Print `[pre-commit] FAIL: $module` on non-zero exit
   and accumulate into `FAIL=1`.

The hook does NOT run `terraform init` or `terraform validate` at commit
time. Provider downloads take 10–30 s on a cold cache and break commit
workflow. Fmt check only at commit time is < 1 s and catches the majority
of authoring noise. Validate runs at pre-push (§5.2).

### 5.2 pre-push hook

`scripts/hooks/pre-push` — bash, `set -euo pipefail`:

1. Derive changed Terraform modules via `git diff --name-only "$(git
   merge-base HEAD origin/main 2>/dev/null || git rev-list
   --max-parents=0 HEAD)" HEAD` filtered to `^terraform/(base|management)/`.
   The `rev-list` fallback handles fresh clones where `origin/main` is not
   yet fetched.
2. For each changed module: `terraform -chdir="$module" init -backend=false
   -input=false -no-color` (stdout suppressed), then `terraform -chdir=
   "$module" validate -no-color`. Accumulate failures into `FAIL=1`.
3. Run `bash tests/unit/run.sh`. Accumulate failure.
4. `exit "$FAIL"` — non-zero blocks the push.

Bypass remains possible via `git push --no-verify`; the minimum-CI-on-main
workflow (§9) is the backstop for that case.

### 5.3 Makefile hooks-install target

`hooks-install` copies via `install -m 755` (not symlinks — symlinks in
`.git/` are fragile across worktrees and Windows checkouts):

```
install -m 755 scripts/hooks/pre-commit  .git/hooks/pre-commit
install -m 755 scripts/hooks/pre-push    .git/hooks/pre-push
```

Add a symmetric `hooks-uninstall` target for CI reproducibility testing.
Both targets are `.PHONY`.

### 5.4 ci-main-gate.yml (minimum CI retention)

See §9 for full rationale. Trigger: `push: branches: [main]` and
`workflow_dispatch`. Single job `gate`, `ubuntu-24.04`, `timeout-minutes: 15`.
Steps (sequential, no matrix): checkout; setup-terraform v3 `~1.6`; install
yq v4.44.3 (same version as the deleted `unit-tests.yml`); setup-helm v3.16.4;
`terraform init + fmt -check + validate` for `terraform/base`; same for
`terraform/management`; `bash tests/unit/run.sh`. No `continue-on-error`
on any step. Wall-clock: 3–6 min on cold cache.

### 5.5 Performance expectations

- `pre-commit` (fmt only, warm cache): < 1 s.
- `pre-push` (init + validate, cold provider cache): 15–30 s. Warm: < 5 s.
- `pre-push` (unit suite, no cluster needed): < 10 s locally.
- `ci-main-gate.yml`: 3–6 min total (provider download dominates).

Net CI wall-clock saving on feature branches: ~30 s per push (eliminated
`terraform-validate.yml` matrix + `unit-tests.yml` runner overhead).

## 6. Tests required

Per AGENTS.md §6.1 and §6.2:

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_hooks_smoke.sh` | Both `scripts/hooks/pre-commit` and `scripts/hooks/pre-push` are executable (`-x`), have a bash shebang, and contain the expected command strings (`terraform fmt`, `tests/unit/run.sh`). |
| Unit | `tests/unit/test_hooks_smoke.sh` | `make hooks-install` copies hooks into `.git/hooks/` and marks them executable. `make hooks-uninstall` removes them. (Run against a temp git repo fixture to avoid mutating the real `.git/hooks/`.) |
| Unit | `tests/unit/test_hooks_smoke.sh` | The pre-commit hook exits 0 when no `.tf` files are in the staged diff (empty-diff fast-path). |
| Unit | `tests/unit/test_hooks_smoke.sh` | The pre-push hook exits non-zero when a known-failing unit test fixture is present (meta-test: temporarily inject a failing test, confirm hook blocks). |

The §6.4 adversarial-review concern: the `changed_tf` calculation in
`pre-push` uses `git merge-base HEAD origin/main`. On a fresh checkout
without `origin/main` yet fetched this will error; the fallback
`git rev-list --max-parents=0 HEAD` (initial commit) is the safety net.
A reviewer should verify that fallback actually works in a fresh clone.

## 7. Testing suggestions

### Unit

- `tests/unit/test_hooks_smoke.sh` — executable flag, shebang, invocation
  string assertions (see §6 for the full list). Each case is < 1 s.
- A fixture that stages a badly formatted `.tf` file and runs the pre-commit
  hook against it via `GIT_DIR=<tmpdir>` — asserts exit 1 and the output
  contains "FAIL" and the module path. This is the load-bearing meta-test
  proving the hook actually fires on real drift.
- A fixture that stages a correctly formatted `.tf` file — asserts exit 0.

### Integration

Integration tests for hooks require a real terraform binary and a git
repository. Not applicable to the `tests/integration/NN_*.sh` cluster-level
suite. If a future contributor adds an integration test harness that can run
in-repo without a cluster, the following cases would be appropriate:

- Run `make hooks-install` in a fresh clone, then `git commit --allow-empty`
  with a staged `.tf` format violation — assert the commit is blocked.
- Run `make hooks-install`, then `git push --dry-run` with a unit test
  failure injected — assert push is blocked.

These are classified as **not currently applicable** because the repo's
integration suite is cluster-bound (`tests/integration/run.sh` requires AWS
and EKS). They are documented here so a future spec that adds a standalone
integration harness knows to include them.

### E2E

Not applicable. The hooks and `ci-main-gate.yml` do not interact with the
EKS cluster, Crossplane, or any AWS resource. No chainsaw scenario is
relevant. A future E2E pass could include a `tests/e2e/hooks/` scenario that
spins up a kind cluster and runs the full pre-push hook against a branch with
deliberate Terraform drift, but the value does not justify the complexity at
this tier.

## 8. Documentation updates

- `AGENTS.md` §3 — add a one-sentence note under branch policy:
  "Run `make hooks-install` once per clone to install the pre-commit and
  pre-push hooks described in SPEC-D5."
- `AGENTS.md` §6.1 table — add a row:
  `| Pre-push hook | always (local) | scripts/hooks/pre-push |`
- `ai/testing-guidelines.md` — add a subsection noting that the unit suite
  is enforced both locally (pre-push hook) and on main merges
  (`ci-main-gate.yml`), and that `make hooks-install` is the onboarding step.
- `README.md` (repo root) — add a "Local setup" section with
  `make hooks-install` as a one-liner after `git clone`.

## 9. Workflow / auto-invocation wiring

### Why keep any CI at all (the A3→A6-006 constraint)

Removing both push workflows entirely would expose a "works on my machine"
regression class: a contributor who clones the repo, skips `make
hooks-install`, makes a change that breaks `terraform validate` or the unit
suite, and pushes directly to `main` would have no automated catch. The
A3→A6-006 cross-comment documents exactly this concern. The `ci-main-gate.yml`
workflow is the minimum retention: it runs only on `push: branches: [main]`
(not on every feature branch push) and on `workflow_dispatch`.

### What is removed

- `terraform-validate.yml`: was triggered on `push: branches-ignore: [main]
  paths: terraform/**`. Deleted entirely. Pre-commit hook replaces the fmt
  check at commit time; pre-push hook replaces validate at push time.
- `unit-tests.yml`: was triggered on `push: branches-ignore: [main]`.
  Deleted entirely. Pre-push hook replaces all steps except the CI
  installation steps (yq, helm), which are implicit in the developer
  environment.

### Auto-invocation chain (post-spec)

```
git commit  -->  .git/hooks/pre-commit  -->  terraform fmt -check (staged modules)
git push    -->  .git/hooks/pre-push    -->  terraform init + validate + unit suite
push to main --> ci-main-gate.yml       -->  both suites (bypass backstop)
```

No human action is required after `make hooks-install`. The hook scripts in
`scripts/hooks/` are version-controlled and updated via normal PR flow;
contributors re-run `make hooks-install` when they pull changes to the hook
scripts (or the Makefile target can overwrite on every pull via a
`post-merge` hook, which is a follow-on if needed).

## 10. Discoverability

1. **Mechanical enforcement** — a push to `main` that fails either suite
   will fail `ci-main-gate.yml` and block the merge if branch protection is
   enabled. On feature branches, the pre-push hook blocks the push in the
   terminal; the contributor cannot accidentally push a broken state without
   seeing the error.
2. **Documentation pointer** — `AGENTS.md` §3 (updated per §8) will instruct
   every future agent to run `make hooks-install` on first clone. The §6.1
   table row will direct agents reading the test-layer policy to
   `scripts/hooks/pre-push`.
3. **Adversarial-review trigger** — the §6.4 adversarial-review checklist
   item "does a new authoring-time guardrail have a test that proves it
   actually fires?" will surface `test_hooks_smoke.sh`'s exit-1 meta-test as
   the required evidence before the PR merges.

## 11. Verification checklist

- [ ] `ls -la /home/user/k8-platform/scripts/hooks/pre-commit` shows mode
  `-rwxr-xr-x` (executable).
- [ ] `ls -la /home/user/k8-platform/scripts/hooks/pre-push` shows mode
  `-rwxr-xr-x`.
- [ ] `make hooks-install` exits 0 and `ls .git/hooks/pre-commit .git/hooks/pre-push`
  shows both files present and executable.
- [ ] Manually stage a `.tf` file with a trailing space (format violation),
  run `.git/hooks/pre-commit` directly — confirm exit 1 and output contains
  `FAIL` and the module name.
- [ ] Revert the format violation, re-run `.git/hooks/pre-commit` — confirm
  exit 0.
- [ ] `bash tests/unit/test_hooks_smoke.sh` exits 0.
- [ ] `bash tests/unit/run.sh` exits 0 (new smoke test is included in the suite).
- [ ] `.github/workflows/terraform-validate.yml` does not exist in the repo.
- [ ] `.github/workflows/unit-tests.yml` does not exist in the repo.
- [ ] `.github/workflows/ci-main-gate.yml` exists and
  `yq '.on.push.branches[0]' .github/workflows/ci-main-gate.yml` returns
  `main`.
- [ ] `make hooks-uninstall` exits 0 and `.git/hooks/pre-commit` and
  `.git/hooks/pre-push` no longer exist.

## 12. Rollout notes

**Backward compatibility.** Deleting `unit-tests.yml` and
`terraform-validate.yml` removes CI checks that currently pass on open
feature branches. Any open PR that relied on those workflows for a green
badge will lose the badge; the PR should pass the minimum CI gate on main
after merge. No existing code is broken; the checks move to local-hook form
only.

**Audit-before-merge.** The same PR that deletes the two workflows must also
create `ci-main-gate.yml`, the hook scripts, the Makefile targets, and the
smoke test — so CI on main is never zero-coverage. The branch protection rule
(if active) should be updated before the PR merges to require
`ci-main-gate.yml` instead of the two deleted workflows.

**Sequencing with in-flight branches.** If another branch has
`terraform-validate.yml` or `unit-tests.yml` modifications in flight (e.g.
a SPEC-B1 rollout that adds a step to `unit-tests.yml`), that branch must be
rebased onto this spec's branch before its PR merges, or the addition will
be lost when the workflow is deleted here. Coordinate via the
`CLUSTERING-REVIEW.md` branch-sequencing table.

**Sandbox constraints.** This spec is orthogonal to Pluralsight sandbox
constraints. No EC2 instances, no Bedrock, no AWS-specific resources are
involved.

**Contributor onboarding.** Any contributor cloning the repo after this spec
merges will not have the hooks installed by default (git does not install
hooks on clone). The `README.md` update (§8) and `AGENTS.md` §3 update are
the onboarding touchpoints. A future `post-checkout` or `post-clone` hook
could automate this, but that is a separate concern.

## 13. Estimated effort

**S** — small (≤ 1 hr).

The hook scripts are ~30 LOC each (bash with no novel patterns). The Makefile
target is 6 LOC. `ci-main-gate.yml` is a straightforward reduction of the
two deleted workflows combined into one file (~50 LOC). The smoke test is
~40 LOC following the existing `tests/unit/test_*.sh` pattern. The rollout
audit is mechanical: confirm the two workflow files are deleted, the new
file exists, CI passes on main. No existing files outside the four listed
in §4 need modification for correctness (the AGENTS.md and README changes
are documentation only). Estimated breakdown: hook scripts + Makefile 15 min,
`ci-main-gate.yml` 10 min, smoke test 15 min, docs 10 min, rollout
coordination + CI verification 10 min. Total: ~60 min.
