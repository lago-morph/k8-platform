# SPEC-LB5 — `tests/regression/pr67/test_manifest_hash_drift.sh`: runtime regression proving Terraform detects manifest body drift when `triggers_replace` hash is stale

Status: DRAFT (spec only — no implementation in this PR)
Tier: B (regression corpus + static lints)
Brainstorm ID: P→A2-007
Pairs with: SPEC-B3 (static lint, author-time)

---

## 1. Summary

Add a runtime regression test that reproduces the PR #67 silent no-op
class: apply a `terraform_data` fixture whose `triggers_replace` hashes
`local.manifest_body`, then mutate the manifest body without updating
the hash, run `terraform plan -detailed-exitcode`, and assert exit code
`2` (drift detected). The test lives at
`tests/regression/pr67/test_manifest_hash_drift.sh` backed by a
self-contained fixture under `tests/regression/pr67/fixture/` using
`-backend=false` local state — no AWS credentials required. It is a
Tier B item from `ai/brainstorming/specs/larger-list-preferences.md`
§B5 and provides the **runtime** half of a two-layer defense: SPEC-B3
fails at author time when the hash is absent; SPEC-LB5 fails at plan
time when the hash is present but stale.

---

## 2. Retro pain killed

- **PR #67 — `terraform_data.crossplane_aws_provider` silent no-op.**
  `retrospective/2026-05-25-70.md` Phase 2 records that PR #66's
  `DeploymentRuntimeConfig` body change never reached the cluster because
  `triggers_replace` only listed the IRSA arn and provider version.
  Terraform apply run 26354235231 reported `Apply complete! Resources:
  0 added, 0 changed, 0 destroyed`. IRSA trust subject mismatch stalled
  every ASM Secret MR at `Ready=False` for the entire session.

- **Same bug class recurred in PR #68.** The retro records that the
  `kubectl delete deploy` command-body change (outside the manifest local)
  also no-op'd until a `"provisioner-command-v2"` sentinel was added.
  Two independent instances in one session is a pattern.

- **No existing test would have caught it.** The retro notes only
  `tests/unit/test_kyverno_policy_lint.sh` was extended in the session.
  No test at any layer checked that `triggers_replace` actually caused
  Terraform to propose a replace on a manifest-body edit.

- **`AGENTS.md §8.1` lesson cost multi-session context.** Per the retro's
  Part 3 Suggestion 1, the misread cost at least three extra dispatch
  cycles and burned context-window budget re-derived the following
  session. The lesson was promoted to an `AGENTS.md` rule precisely
  because it recurred.

---

## 3. Out of scope

- **SPEC-B3 (static lint, author-time).** SPEC-B3 checks that
  `sha256(local.*_manifest)` is present in `triggers_replace` by parsing
  committed HCL before any apply. SPEC-LB5 checks that when the hash is
  present but stale, `terraform plan` exits 2. The two cover distinct
  failure modes at distinct lifecycle moments — they are defense in depth,
  not redundant. *Considered and rejected: merging LB5 into B3.* B3 is a
  pure-bash HCL lint; it never invokes `terraform` and cannot test state.

- **SPEC-C1 (post-apply drift step in CI).** SPEC-C1 adds a
  `terraform plan -detailed-exitcode` step inside `.github/workflows/
  terraform-test.yml` against the live module. SPEC-LB5 targets a
  synthetic fixture with no AWS dependency and runs at unit CI speed.
  The two share the `-detailed-exitcode` mechanism but fire against
  entirely different contexts.

- **SPEC-C5 (integration drift check).** SPEC-C5's `99_no_drift.sh`
  plans against both live modules at the end of the integration suite.
  SPEC-LB5 uses a local fixture; no overlap.

- **General `triggers_replace` completeness.** SPEC-LB5 proves the
  mechanism works; it does not enumerate every possible gap (command-body
  sentinels, file hashes, module-output references). Those are covered by
  SPEC-B3 and AGENTS.md §10.

- **AWS API calls.** The fixture is credential-free by design (`-backend=false`,
  local `terraform_data` writing to `/tmp`). Adding AWS coverage would
  require a live cluster and is out of scope.

---

## 4. Files to change / create

Create:

- `/home/user/k8-platform/tests/regression/pr67/fixture/main.tf` —
  minimal fixture: one `terraform_data` whose `triggers_replace` hashes
  `local.manifest_body`, one `local-exec` that writes the body to `/tmp`.
- `/home/user/k8-platform/tests/regression/pr67/fixture/.terraform.lock.hcl`
  — committed provider lock so `terraform init -upgrade=false` is
  reproducible offline.
- `/home/user/k8-platform/tests/regression/pr67/test_manifest_hash_drift.sh`
  — test script: `mktemp` state dir, `trap` cleanup, two scenarios
  (clean-apply baseline, mutated-body drift assertion).

Modify:

- `/home/user/k8-platform/tests/unit/run.sh` — append one
  `run_suite tests/regression/pr67/test_manifest_hash_drift.sh` line.
  No workflow edit needed: `unit-tests.yml` already calls `run.sh`.

---

## 5. Implementation notes

### Fixture shape

```hcl
# tests/regression/pr67/fixture/main.tf
locals {
  manifest_body = <<-MANIFEST
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: pr67-fixture
    data:
      key: original-value
  MANIFEST
}

resource "terraform_data" "pr67_fixture" {
  # Hash covers the manifest body. Stale hash → plan exit 2.
  triggers_replace = [sha256(local.manifest_body)]

  provisioner "local-exec" {
    command = "printf '%s' '${local.manifest_body}' > /tmp/pr67-fixture-manifest.yaml"
  }
}
```

### Mutation pattern (Scenario B — the PR #67 regression)

1. Seed state: `terraform apply -auto-approve -state=${STATE_DIR}/terraform.tfstate`.
2. Write a temporary override file that redefines `local.manifest_body`
   with `key: mutated-value` but hard-codes a stale placeholder in
   `triggers_replace`:

```hcl
# mutation_override.tf.tmp — written by test, deleted on EXIT
locals {
  manifest_body = <<-MANIFEST
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: pr67-fixture
    data:
      key: mutated-value
  MANIFEST
}
resource "terraform_data" "pr67_fixture" {
  triggers_replace = ["sha256-stale-placeholder"]
}
```

3. Run `terraform plan -detailed-exitcode -no-color
   -state=${STATE_DIR}/terraform.tfstate`. Assert exit code `2`.
4. Parse plan output: assert `pr67_fixture` appears in a `must be
   replaced` or `forces replacement` context. This confirms the correct
   resource is flagged, not an unrelated data-source refresh.

If step 3 returns exit `0`, the `triggers_replace` / `sha256` contract
is broken — future manifest-body edits will silently no-op exactly as
PR #66 did.

### Why this proves the bug class

`terraform plan -detailed-exitcode` exits `2` when `triggers_replace`
changes. With the override, `triggers_replace` changed from
`sha256(<original body>)` to `"sha256-stale-placeholder"`. Terraform
sees the stored hash differs from the new config value and proposes a
replace. This is the same mechanism that PR #67's fix
(`sha256(local.crossplane_aws_provider_manifest)` at `helm.tf:218`)
relies on.

### State isolation

```bash
STATE_DIR=$(mktemp -d)
trap 'rm -rf "$STATE_DIR"' EXIT
terraform -chdir=tests/regression/pr67/fixture \
  init -input=false -backend=false -upgrade=false
```

`-backend=false` eliminates all remote-state and locking dependencies.
The test is credential-free, parallelism-safe, and cleans up on EXIT.

### Output format

```
── PR #67 manifest hash drift regression ──────────────────────
  PASS  [scenario-a] clean apply: second plan exits 0
  PASS  [scenario-b] mutated body without rehash: plan exits 2
  PASS  [scenario-b] plan names pr67_fixture as requiring replacement

SUMMARY: 3 passed, 0 failed
```

On assertion failure, the full plan stdout/stderr is printed inline.
Expected wall-clock: <30 s total.

---

## 6. Tests required

Per AGENTS.md §6.1 and §6.2 (TDD on bug fixes):

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/regression/pr67/test_manifest_hash_drift.sh` | Scenario A: second plan on clean state exits 0. |
| Unit | same | Scenario B: mutated manifest with stale hash causes plan exit 2. |
| Unit | same | Scenario B plan output contains `pr67_fixture` in a replacement context. |
| Unit (meta) | same | Lock file present: `grep provider tests/regression/pr67/fixture/.terraform.lock.hcl` returns ≥ 1 line. |

Per AGENTS.md §6.4: spawn one adversarial-reviewer subagent before
authoring the test. The brief must include the Scenario B design and ask:
*"Can `-backend=false` + stale-placeholder produce exit 2 for a reason
unrelated to `triggers_replace`? Does this faithfully reproduce PR #67's
mechanism? What if Terraform's `triggers_replace` evaluation changes in
a future version?"* Adopt every concrete suggestion or document a
one-line dismissal in the PR.

---

## 7. Testing suggestions (unit / integration / e2e)

### Unit

1. **Scenario A (baseline)** — clean apply, second plan exits 0. Proves
   the fixture itself is internally consistent before any mutation.
2. **Scenario B (regression)** — mutated body with stale hash, plan exits
   2. The direct PR #67 reproduction. `tests/regression/pr67/
   test_manifest_hash_drift.sh`.
3. **Boundary: hash-only change (no body mutation)** — update
   `triggers_replace` to a new hash value without changing the manifest
   body. Plan should exit 2 (replace proposed) because `triggers_replace`
   changed. Documents that Terraform reacts to the hash value itself, not
   to downstream file content.
4. **Provider lock integrity** — meta-test: `grep provider
   tests/regression/pr67/fixture/.terraform.lock.hcl` returns a line,
   confirming the lock is committed and `init` is reproducible offline.

### Integration

Not applicable. The PR #67 bug lives entirely in Terraform plan/apply
mechanics with no AWS API or cluster-state surface. The `-backend=false`
fixture replicates the mechanism faithfully at unit speed. Adding an
integration-layer test that duplicates Scenario B against
`terraform/management/` requires a live cluster and ~15 min of apply
overhead to exercise the same single exit-code assertion — zero marginal
coverage at high marginal cost. SPEC-C1 covers this layer.

### E2E

Not applicable. SPEC-B3 gates the PR #67 class at HCL author time;
SPEC-LB5 gates the underlying Terraform mechanism at unit time; SPEC-C1
gates it at every live `apply-and-verify`. There is no end-to-end scenario
this spec leaves uncovered that a future e2e test could add value to.
If a new manifestation of the bug class emerges (e.g. a Crossplane-managed
local that bypasses the lint), the correct response is an additional
fixture in `tests/regression/pr67/`, not an e2e scenario.

---

## 8. Documentation updates

- `ai/testing-guidelines.md` — add a bullet under the unit-test section
  naming `tests/regression/pr67/` as a regression corpus directory:
  *"Terraform `triggers_replace` regression fixtures use `-backend=false`
  local state; no AWS credentials required."*
- `ai/TESTING-PLAN.md` (bug-class registry) — add row:
  `"Manifest body edit without hash update (PR #67)" | "tests/regression/
  pr67/test_manifest_hash_drift.sh Scenario B + SPEC-B3 lint" |
  "plan exits 2; lint fails at author time"`.
- `tests/regression/pr67/test_manifest_hash_drift.sh` header comment —
  cite PR #67, run 26354235231, and `helm.tf:218` fix.
- `AGENTS.md` — no change. §6.1 already covers `tests/unit/`; the
  regression directory extends naturally. §6.2 already cites the PR #67
  class as a TDD exemplar.

---

## 9. Workflow / auto-invocation wiring

One `run_suite tests/regression/pr67/test_manifest_hash_drift.sh` line
added to `tests/unit/run.sh` wires the test into every push via the
existing `unit-tests.yml` workflow. No new workflow files, no new
secrets, no new permissions. `terraform` is already on the CI PATH
(required by `terraform-validate.yml`). The test is fast (<30 s) and
credential-free; it is safe at the unit CI cadence.

---

## 10. Discoverability

1. **Mechanical enforcement.** The `run_suite` line in `tests/unit/run.sh`
   causes `unit-tests.yml` to go red if the test file is deleted or
   the fixture is broken. CI cannot go green with the regression absent.

2. **Documentation pointer.** `ai/TESTING-PLAN.md`'s new bug-class row
   names the file path. Agents reading the testing plan (mandatory per
   AGENTS.md §1) encounter the test when investigating the PR #67 class.

3. **Adversarial-review trigger.** AGENTS.md §6.4 requires a subagent
   review before drafting any new test. The brief for future
   `terraform_data` regression tests should include: *"Does
   `tests/regression/pr67/` already cover this mutation pattern? Extend
   the existing fixture rather than duplicating."* This makes SPEC-LB5
   the canonical reference for the PR #67 class.

---

## 11. Verification checklist

- [ ] `bash tests/regression/pr67/test_manifest_hash_drift.sh` exits 0
      with `SUMMARY: 3 passed, 0 failed`.
- [ ] `bash tests/unit/run.sh` includes the new test in its banner and
      exits 0.
- [ ] `terraform -chdir=tests/regression/pr67/fixture init -backend=false
      -upgrade=false` succeeds with no network access (uses committed lock).
- [ ] `grep provider tests/regression/pr67/fixture/.terraform.lock.hcl`
      returns ≥ 1 line.
- [ ] Mutation smoke: temporarily hard-code `triggers_replace = ["stale"]`
      in the fixture's `main.tf` and re-seed state; `terraform plan
      -detailed-exitcode` exits 2 (replace proposed). Restore.
- [ ] `grep -c "run_suite.*pr67" tests/unit/run.sh` returns `1`.
- [ ] `grep -c "26354235231" tests/regression/pr67/test_manifest_hash_drift.sh`
      returns ≥ 1 (run ID grounds the test in the original event).
- [ ] Adversarial-reviewer subagent findings logged in PR description.

---

## 12. Rollout notes

- **Backward-compat.** Additive only. Cannot break any existing apply,
  cluster state, or live resource. The only new CI requirement is
  `terraform` on PATH, already satisfied.
- **Audit-before-merge.** No `terraform/` edits needed. The PR #67 fix
  at `terraform/management/helm.tf:218` already complies; confirm with
  `grep -n "sha256(local\." terraform/management/helm.tf`.
- **Provider cache on cold runners.** The committed lock file makes
  `terraform init` reproducible. A cold runner downloads the provider
  once (~5 MB for `hashicorp/local` or `hashicorp/null`); add
  `actions/cache` for `.terraform/` only if latency becomes an issue —
  not a gate on landing this spec.
- **Pluralsight sandbox constraints.** Irrelevant — no AWS calls.
- **Coordination with SPEC-B3.** Both specs add a `run_suite` line to
  `tests/unit/run.sh`. Resolve the merge conflict by appending both
  lines in the later-merging PR. No other shared files.

---

## 13. Estimated effort

**S** (≤1 hour).

- Fixture authoring (`main.tf`, lock file): ~15 min. One `terraform_data`
  block, `terraform init` to generate the lock.
- Test script: ~20 min. Two scenarios, ~15 bash lines each; shared
  `mktemp`/`trap` boilerplate borrowed from existing unit tests.
- `tests/unit/run.sh` edit: <1 min.
- Rollout audit (verify `helm.tf` compliance): ~5 min.
- Adversarial-reviewer subagent + adoption: ~20 min (small addition;
  single subagent per AGENTS.md §6.4).
- Documentation edits (§8): ~10 min.

Total: approximately 70–80 minutes. The adversarial review is the largest
component; the fixture's `-backend=false` design is non-obvious and the
reviewer will likely sharpen the Scenario B assertion.
