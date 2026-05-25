# SPEC-C5 — `tests/integration/99_no_drift.sh`: final integration test that fails on Terraform drift

## 1. Summary

Add a final integration test (`tests/integration/99_no_drift.sh`) that runs
`terraform plan -detailed-exitcode -refresh=true` against every Terraform
module backing the live cluster (`terraform/base/`, `terraform/management/`)
and fails the integration suite on any drift. Numbered `99_` so the
auto-discovery loop in `tests/integration/run.sh` runs it last, after the
other ten-plus integration tests have themselves mutated cluster state.
Complementary to SPEC-C1 (which gates drift at the workflow's apply step) —
SPEC-C5 catches slow drift that surfaces between apply and the §6.3
full-bundle verify, particularly drift introduced by the other integration
tests themselves or by reconciliation loops (Crossplane, ArgoCD, ESO).

## 2. Retro pain killed

**Post-apply state drift bug class.** Even when `terraform apply` lands
green, the verify phase routinely surfaces resources that have diverged
from declared state. Three observed sub-classes:

- **Reconciler-introduced drift.** ESO, Crossplane providers, and
  ArgoCD pull in IAM trust policy updates, tag mutations, and Helm
  release re-renders. The Terraform-managed resource still exists, but
  attributes the module declares have been overwritten.
- **Test-introduced drift.** The earlier integration tests (e.g.
  `08_irsa_sts_round_trip.sh`, `11_platform_secret_e2e.sh`) create and
  delete claims that round-trip through provider-managed cloud
  resources. Asymmetric cleanup leaves dangling tags, scoped policies,
  or KMS key aliases the Terraform module owns.
- **Eventual-consistency drift.** AWS APIs propagate tags / policy
  changes minutes after `apply` returns. A plan run immediately after
  apply is clean; a plan run thirty minutes later is not.

**Correlation with SPEC-C1's PR #67 evidence.** PR #67 introduced
`terraform plan -detailed-exitcode` in the workflow's apply step (SPEC-C1)
and caught drift introduced by a Helm release whose chart version pin had
been bumped without a corresponding apply. That defense fires *only at
apply time*. The PR #67 retro explicitly flagged that the same drift
class re-appears between apply and the next verify, with nothing in CI
catching it; SPEC-C5 is the second-layer defense the retro called for.
The two checks share the `-detailed-exitcode` mechanism but fire at
different lifecycle moments and therefore catch different bugs.

## 3. Out of scope

- **Kubernetes resource drift.** ArgoCD already detects and surfaces
  drift against its declared manifests (`OutOfSync` Applications).
  SPEC-C5 does not duplicate that.
- **Crossplane Managed Resource drift.** Crossplane providers
  continuously reconcile MRs against their declared `forProvider` spec
  and report drift via `Synced=False`. The
  `crossplane-claim-verify` skill is the agent-facing surface; SPEC-C5
  does not re-check MR state.
- **Drift caused by non-Terraform-managed resources.** If a resource
  exists in AWS but no Terraform module declares it, that is not drift
  — that is unmanaged state. A separate AWS-account-sweep tool would
  cover that; SPEC-C5 only plans against the modules in
  `terraform/base/` and `terraform/management/`.
- **Cross-account drift.** The test only runs against the AWS account
  the integration suite is currently pointed at (per `aws sts
  get-caller-identity`).
- **Auto-remediation.** The test reports drift; it does not apply.
  Remediation is a human / agent decision.

## 4. Files to create

Create:

- `tests/integration/99_no_drift.sh` — the new test. Shebang
  `#!/usr/bin/env bash`, `set -euo pipefail`. Sources
  `tests/integration/lib/` helpers where present (precondition checks,
  log truncation). Runs `terraform init` (offline mode preferred — see
  §5) then `terraform plan -detailed-exitcode -refresh=true -no-color`
  against each module in turn. Exit 2 from plan → test fails with the
  plan diff as evidence. Exit 0 → pass. Exit 1 → infrastructure error
  (treat as fail, not skip).

Modify (documentation/wiring only; no code changes elsewhere):

- `ai/testing-guidelines.md` — §6.3 full-bundle list updated to name
  the new test explicitly (see §7).

No new shared library files needed. The test is single-file and
self-contained per the existing integration-test convention.

## 5. Implementation notes

### State acquisition

The test must hit the **same backend** the workflow uses, otherwise
`terraform plan` will see an empty state and propose creating
everything (false-positive drift of catastrophic shape). Strategy:

1. **Read backend config from the environment** the workflow exports
   (`TF_BACKEND_BUCKET`, `TF_BACKEND_REGION`, `TF_BACKEND_DYNAMODB_TABLE`).
   These are set during the bootstrap step of `terraform-test.yml`
   (lines 135-138). When the integration suite is invoked from CI
   they are already in env.
2. **When run locally**, the test re-derives them via the same
   conventions the workflow uses: `BUCKET=k8-platform-tfstate-<account-id>`,
   `REGION=$(aws configure get region)`, `TABLE=k8-platform-tflock`.
   The derivation logic lives in the workflow's bootstrap step; the
   test calls a small helper that mirrors it. If the helper cannot
   derive a backend (no AWS creds, etc.), the test SKIPs (exit 2)
   per the integration-suite convention — drift cannot be assessed
   without state.
3. **`terraform init`** runs with `-backend-config=` flags supplied
   the same way the workflow does. Preferred form:
   `terraform init -input=false -reconfigure -backend-config=...`.
   If `.terraform/` is already initialized to the right backend
   (cached from an earlier step in the same CI job), `init` is a
   no-op-fast.

### Module discovery

Hardcode the list — the modules are stable and named:

```
MODULES=(
  "terraform/base"
  "terraform/management"
)
```

A `find terraform -name 'main.tf' -mindepth 2 -maxdepth 2`-based
auto-discovery is tempting but rejected: it picks up vendored
submodules and `examples/`, neither of which the workflow plans
against. Explicit list matches the workflow's behavior. If a future
module lands (e.g. `terraform/workload-cluster/`), this list and the
workflow are both updated in the same PR.

### Tolerated drift list (allowlist)

Some plan deltas are not real drift — they are inherent to the way
providers render state. Allowlist them by post-processing the plan
output and filtering matching lines before deciding pass/fail:

- **Helm release re-render timestamps.** The `helm_release` resource
  re-computes `metadata[0].last_applied` (or equivalent) on every
  refresh. Filter plan diffs whose only change is in
  `metadata[*].annotations["meta.helm.sh/last-applied"]` or
  comparable timestamp-only attributes.
- **`aws_*` resources where the only diff is `tags_all`** populated
  from default provider tags merged in. If the underlying `tags`
  block is unchanged, the diff is provider-introduced noise.
- **Kubernetes provider `data_source` reads** that re-resolve at
  refresh time (these don't produce plan changes; they show as
  read-only fetches and should be ignored).

Mechanism: run `terraform show -json <planfile>` and walk the
`resource_changes[].change.actions` array. A change is "real" if any
of (`create`, `delete`, `replace`) appears, OR if `update` appears
with a non-allowlisted attribute. Allowlisted-only `update`s are
NOTICE-logged but do not fail.

The allowlist is a literal list of `(resource_type, attribute_path)`
pairs in the test, with one-line comments citing why each entry is
allowlisted. Adding to the allowlist requires a PR comment naming the
provider behavior responsible — the bar is "provider can't be made
to not emit this", not "we don't feel like fixing it".

### ≤5 KB output budget

Default `terraform plan` output is verbose and can easily exceed
5 KB per module. The test:

1. Saves the full plan to `${RUNNER_TEMP:-/tmp}/no_drift_<module>.tfplan`
   and `terraform show -no-color` of it to a sibling `.txt`.
2. On drift, prints a **summary**: number of resources by action
   class, and for each non-allowlisted change one line of the form
   `<action> <resource_address>: <changed-attrs>`. Truncate to the
   first 30 changes; emit a `(N more changes — see <path>)` footer.
3. Always emits the full plan path so the operator can `cat` it.
4. On pass, prints one line: `no drift in <module>`.

### Exit codes

- `0` — every module's plan returned exit 0, or returned exit 2 with
  all changes inside the allowlist.
- `1` — drift detected, OR `terraform init`/`plan` errored.
- `2` — precondition missing (no AWS creds, no live cluster, no
  backend). Per the integration-suite convention this is SKIP, not
  FAIL.

### Ordering inside `run.sh`

The `[0-9][0-9]_*.sh | sort` glob in `tests/integration/run.sh`
naturally places `99_no_drift.sh` last. The other integration tests
(01-11) all complete — pass or fail — before this one runs. That is
intentional: drift introduced by them is the bug class this test
defends.

### Refresh strategy

Use `-refresh=true` (the default). The PR #67 retro called out that
`-refresh=false` plans hide drift that `apply` then catches at the
worst possible time. The plan duration cost (~30 s per module
against a populated state) is acceptable at the verify-time cadence.

## 6. Tests required

Per AGENTS.md §6.1 (test-alongside-feature) and §6.2 (TDD discipline):

| Layer | File | Assertion shape |
|---|---|---|
| Unit (meta) | `tests/unit/test_no_drift_meta.sh` (new) | Run the script's allowlist filter against a synthetic `terraform show -json` fixture with only timestamp-attribute changes — assert the filter returns "no real drift". |
| Unit (meta) | same | Run filter against a fixture with a tag mutation outside the allowlist — assert "real drift detected". |
| Unit (regression) | same | Fixture reproducing a Helm-release timestamp-only delta (the §5 noise case) — assert the test does not fail on it. Mirrors the PR #67 retro pattern. |
| Unit (regression) | same | Fixture reproducing an actual IRSA trust policy mutation — assert the test fails with the resource address named. |
| Integration (self) | `tests/integration/99_no_drift.sh` | Real plan against `terraform/base/` returns exit 0 against the freshly-applied state. |
| Integration (self) | same | Real plan against `terraform/management/` returns exit 0. |
| Integration (meta) | new helper in `tests/integration/lib/` (optional) | Negative-path test: temporarily tweak an AWS tag out-of-band, re-run the test, assert it now fails and names the resource. Manual-only — needs a teardown step to restore. Document as an operator-run smoke test, not a CI step. |

§6.4 adversarial-reviewer trigger: before authoring, spawn one
general-purpose subagent with the brief — load-bearing surfaces are
the allowlist regexes and the `terraform show -json` traversal. A
reviewer will likely surface drift shapes we haven't seen (e.g. EKS
`vpc_config[0].cluster_security_group_id` re-derived after upgrade;
ACM certificate `validation_record_fqdns` re-computed on Route53
record drift).

## 7. Documentation updates

- `ai/testing-guidelines.md` §6.3 — extend the full-bundle list to
  name the new test explicitly:

  > 3. `tests/integration/run.sh` — full integration suite against
  >    the live cluster, **including `99_no_drift.sh` which fails on
  >    any post-apply Terraform drift**.

  Without this explicit mention an agent reading §6.3 might assume
  the bundle is unchanged.

- `tests/integration/README.md` — add a row to the test catalog naming
  `99_no_drift.sh`, its assertion ("no Terraform drift since apply"),
  and its skip condition ("no AWS creds / backend").
- `AGENTS.md` — no change. The §6.1 integration-test row already
  covers "every end-to-end flow"; drift detection is one such flow.
- `ai/handoff.md` — no change. Lint catalogs don't belong there
  (standing convention).
- No new ADR. The decision to plan-on-verify is a direct extension
  of SPEC-C1's plan-on-apply, not a new architectural axis.

## 8. Workflow / auto-invocation wiring

No new workflow files. Existing wiring fires the test automatically:

- **`tests/integration/run.sh`** auto-discovers any `NN_*.sh` script
  via `ls -1 [0-9][0-9]_*.sh | sort`. Dropping `99_no_drift.sh` into
  the directory is sufficient — no code change to `run.sh`.
- **`.github/workflows/terraform-test.yml`** invokes the integration
  suite in its `[management] e2e-verify` step (and elsewhere); the
  new test runs as part of that.
- **Phase verify per §6.3.** When the agent runs the full test
  bundle after `apply-and-verify`, `tests/integration/run.sh` is
  step 3 of the bundle. The new test fires unconditionally as the
  last item.

`continue-on-error` is **never** set on this step. Drift must fail
loud. If the rollout phase (§11) reveals pre-existing drift, the fix
is to remediate the drift, not to suppress the test.

## 9. Discoverability for future agents

Three forcing functions, none requiring an agent to remember anything:

1. **Failing test in the integration suite is mandatory output.**
   Any session that runs the §6.3 full bundle sees the test's
   pass/fail line in `run.sh`'s summary. A red `99_no_drift.sh` is
   front-and-center — the suite cannot be reported "green" with this
   test failing.
2. **The test name is self-documenting.** `99_no_drift.sh` is the
   clearest possible signal in the integration directory listing.
   Any agent scanning `ls tests/integration/` learns about it
   immediately.
3. **`ai/testing-guidelines.md §6.3` explicitly names it.** Future
   agents reading that section (mandatory per AGENTS.md §1) cannot
   miss the dependency.

No new skill required. No new doc-link at session start.

## 10. Verification checklist

- [ ] `bash tests/integration/99_no_drift.sh` exits 0 against a
  freshly-applied phase 0+1 environment.
- [ ] `bash tests/integration/run.sh` includes the new test in its
  summary output and overall exits 0.
- [ ] Manually mutate an AWS tag on a Terraform-managed resource
  (e.g. `aws ec2 create-tags` on the EKS cluster's VPC). Re-run the
  test, confirm exit 1 and the plan diff names the resource and the
  changed attribute. Revert the tag, re-run, confirm green.
- [ ] Manually mutate a `helm_release` chart version pin in
  `terraform/management/` (don't apply). Run the test. Confirm it
  fails with the release name in the diff. Revert.
- [ ] Confirm allowlist works: trigger a Helm re-render (delete and
  re-create the release out-of-band so the `last-applied` annotation
  changes). Run the test, confirm it passes with a NOTICE line.
- [ ] Plan output size on a clean run is ≤5 KB per module.
- [ ] `tests/unit/test_no_drift_meta.sh` exists, all assertions pass.
- [ ] `ai/testing-guidelines.md` §6.3 mentions the new test by name.

## 11. Rollout notes

**The test will fail against the current repo on day one if pre-existing
drift exists.** Before merging, complete:

1. **Apply phase 0 + phase 1 cleanly** via the workflow. Confirm
   both apply steps green.
2. **Audit pass.** Run `terraform plan -detailed-exitcode
   -refresh=true` against both modules manually. Capture every
   non-allowlisted diff. Expect candidates:
   - Helm release timestamp annotations — allowlist material.
   - `tags_all` deltas from provider default tags — allowlist material.
   - **Anything else is real drift and must be remediated, not
     allowlisted.** Specifically: IAM policy doc changes, security
     group rule changes, ACM cert SAN changes, EKS version drift —
     these are bugs in the modules and the fix is `terraform apply`
     (or fix the module first, then apply).
3. **Fix pass.** For each real-drift item, either:
   - `terraform apply` to align live state to declared state, OR
   - Update the module to declare what the live state actually is
     (when the live state is correct and the module is stale), then
     `terraform apply`.
4. **Re-run plan.** Confirm exit 0 on both modules.
5. **Land the test.** Push the branch, confirm the integration suite
   green including the new test, then open the PR.

A hostile test — one that fires the day it lands against an unaudited
environment — burns agent time on every subsequent session. The
audit-first discipline ensures the first run is green.

Stack the PRs per AGENTS.md §3 if the fix pass is large:

- PR 1 (parent): the test + fixtures + allowlist, NOT yet wired into
  the workflow / `run.sh` (file present but renamed to `_99_no_drift.sh.draft`
  or behind an env-gate). Allows review of the logic.
- PR 2 (child off PR 1): the drift remediation commits (one commit
  per real-drift fix, per AGENTS.md §9 commit standards).
- PR 3 (child off PR 2): rename / un-gate the test so `run.sh` picks
  it up. Land only after PR 2's drift remediation has been applied
  to the live environment.

PR 3's CI gates on the test being green, which proves the audit and
fix passes were complete.

## 12. Estimated effort

**M** — medium.

Justification: the test logic itself is small (~120 LOC bash plus a
`jq` or `python3` snippet for the `terraform show -json` traversal).
The allowlist requires care — overly tight and the test is noisy;
overly loose and it misses real bugs. The audit-and-fix rollout is
the bulk: pre-existing drift in either module costs ~1 hour per
item to investigate and remediate, and the number of items is
unknown until the audit runs. Adversarial-reviewer round adds ~1
hour. Total estimate: 6–10 hours across the stacked PRs, comparable
to SPEC-B1.
