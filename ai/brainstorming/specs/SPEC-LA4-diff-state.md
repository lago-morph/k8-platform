# SPEC-LA4 — `scripts/diff-state.sh phase=N`: on-demand terraform-plan-vs-cluster drift highlighter

Status: DRAFT | Brainstorm ID: A1-038 | Tier: A (LA4) | Branch: `feat/diff-state-script`

---

## 1. Summary

Add `scripts/diff-state.sh` — a single operator-invocable script that
accepts a `phase=N` argument (`base` or `management`), runs
`terraform plan -detailed-exitcode -refresh=true -lock=false` against
that module's remote backend, and emits a structured drift report
naming every resource whose live state diverges from declared config.
The script is the on-demand runtime complement to SPEC-B3's
manifest-hash lint (authoring-time) and directly addresses the
"Apply complete: 0 added" silent-no-op bug class (`ai/handoff.md:144`,
PR #67). The smallest concrete artifacts are one executable at
`/home/user/k8-platform/scripts/diff-state.sh` and one unit test at
`/home/user/k8-platform/tests/unit/test_diff_state.sh`. No CI workflow
changes are required; the script is invoked manually or from an agent
task, not from automated pipelines.

---

## 2. Retro pain killed

- **PR #67 — silent no-op apply** (`ai/handoff.md:170`): `triggers_replace`
  on `terraform_data.crossplane_aws_provider` omitted a manifest-body hash.
  `terraform apply` reported "0 added, 0 changed, 0 destroyed" while the
  intended `DeploymentRuntimeConfig` edit never reached the cluster. No
  single command existed to answer "did that apply actually change anything?"
  in the running cluster.

- **PR #66 — SA-name edit not applied** (`ai/handoff.md:171`): the
  `upbound-provider-family-aws` SA-name pin was a manifest change that did
  not flip `triggers_replace`. A `diff-state.sh phase=management` run
  immediately after PR #66's apply would have named the affected resource
  address and saved the PR #67 debug session.

- **Three-session green-but-wrong applies** (`ai/handoff.md:144`):
  *"Zero changes after a manifest edit = `triggers_replace` missing a hash"*
  is currently a manual critical behavioral rule. `diff-state.sh` makes
  the check mechanical — one command, deterministic exit code.

- **Post-apply verify ambiguity** (`ai/testing-guidelines.md §3`):
  an agent restarting after a prior session has no fast way to confirm
  Terraform state still matches config before starting work.
  `diff-state.sh phase=management` is that fast check (~30 s, no
  AWS-console navigation).

---

## 3. Out of scope

- **SPEC-A5** (`terraform-ci-watch` Phase 3.5 intent-vs-reality diff).
  SPEC-A5 is skill-embedded, CI-triggered, and compares pre-apply vs
  post-apply plan artifacts from workflow runs. SPEC-LA4 is a standalone
  script with no knowledge of run IDs or artifact URLs. SPEC-A5 fires
  automatically inside CI; SPEC-LA4 fires on demand outside CI.

- **SPEC-C1** (inline post-apply plan inside `terraform-test.yml`).
  SPEC-C1 wires the drift check into every `apply-and-verify` workflow
  run. SPEC-LA4 is the out-of-band companion for sessions where the
  workflow was not dispatched.

- **SPEC-C5** (`tests/integration/99_no_drift.sh`). That test is part
  of the full integration suite, includes a provider-noise allowlist,
  and gates on `run.sh` pass/fail. SPEC-LA4 is not a test; it has no
  allowlist and no presence in `run.sh`. Use `diff-state.sh` for fast
  spot-checks; `99_no_drift.sh` for authoritative suite-level
  verification.

- **Auto-remediation.** The script reports drift and exits; it never applies.

- **Kubernetes-side drift.** ArgoCD `OutOfSync` and `crossplane-claim-verify`
  cover the cluster-object layer. This script stops at Terraform state-vs-config.

- **CloudWatch drift logging** (cross-review A3→A1-006). Base script emits
  to stdout only; the logging extension is a follow-on PR.

### Considered and rejected

- **Single invocation covering both modules.** Rejected: independent
  backends, different cadences, slower combined `terraform init`. Run
  both sequentially: `phase=base && phase=management`.

- **Continuous watch mode** (A5→A1-013 cross-review). Rejected: tight
  loops risk lock contention with concurrent CI dispatches. Deferred.

---

## 4. Files to change / create

Create:

- `/home/user/k8-platform/scripts/diff-state.sh` — executable script.
  Accepts `phase=base` or `phase=management`; rejects all other inputs
  with usage + exit 1.

- `/home/user/k8-platform/tests/unit/test_diff_state.sh` — unit tests
  (stubs for `terraform`, `aws`). No AWS creds required.

Modify:

- `/home/user/k8-platform/scripts/README.md` — add one row for
  `diff-state.sh` in the script inventory table.

- `/home/user/k8-platform/tests/unit/run.sh` — ensure `test_diff_state.sh`
  is included (if not already auto-discovered by glob).

- `/home/user/k8-platform/ai/testing-guidelines.md §3` — add
  `diff-state.sh phase=<module>` as the recommended spot-check after
  any `apply-and-verify` that touches a `terraform_data` resource.

---

## 5. Implementation notes

### 5.1 Phase-scoping mechanism

```bash
#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: $0 phase=<base|management>" >&2; exit 1; }
[[ $# -eq 1 ]] || usage
[[ "$1" =~ ^phase=(base|management)$ ]] || usage
PHASE="${1#phase=}"
MODULE_DIR="$(git rev-parse --show-toplevel)/terraform/${PHASE}"
```

`git rev-parse --show-toplevel` roots the path at the repo root and makes
the script safe to invoke from any working directory. The `PHASE` value
maps 1:1 to a directory under `terraform/`. Adding a new module (e.g.
`terraform/workload-cluster/`) requires only extending the regex and
creating the directory — no structural changes.

### 5.2 Backend derivation

The script re-derives the S3/DynamoDB backend at runtime using the same
convention as `terraform-test.yml`:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_BACKEND_BUCKET="k8-platform-tfstate-${ACCOUNT_ID}"
TF_BACKEND_REGION="${AWS_REGION:-$(aws configure get region)}"
TF_BACKEND_TABLE="k8-platform-tfstate-lock"
KEY="${PHASE}/terraform.tfstate"
```

`terraform init -reconfigure` with these values ensures a stale
`.terraform/` from a prior run does not shadow the correct backend.
If already initialized to the right backend, `init` is a fast no-op.

### 5.3 Plan invocation

```bash
cd "$MODULE_DIR"
terraform init -input=false -reconfigure \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="region=${TF_BACKEND_REGION}" \
  -backend-config="dynamodb_table=${TF_BACKEND_TABLE}" \
  -backend-config="key=${KEY}" \
  -no-color 2>&1 | grep -E "^(Initializing|Error)" || true

PLAN_FILE="${TMPDIR:-/tmp}/diff-state-${PHASE}.tfplan"
set +e
terraform plan -detailed-exitcode -refresh=true \
  -no-color -lock=false -out="$PLAN_FILE" \
  2>&1 | tee "${TMPDIR:-/tmp}/diff-state-${PHASE}-raw.txt"
TF_EXIT=$?
set -e
```

`-lock=false` is intentional: this is a read-only diagnostic. Taking the
state lock for a read would block concurrent CI dispatches. This differs
from SPEC-C1's inline post-apply plan, which runs inside the apply job
with the lock already held and uses `set +e` around the plan step for the
same reason.

`-refresh=true` is required. Without it the plan may read stale cached
provider-computed attributes (e.g. EKS `vpc_config` fields) and produce
a false-clean report — the bug the script exists to prevent.

### 5.4 Exit-code contract and output format

| `terraform plan` exit | Meaning | `diff-state.sh` exit | Output header |
|---|---|---|---|
| `0` | No drift | `0` | `[CLEAN] No drift in terraform/${PHASE}` |
| `1` | Plan error | `1` | `[ERROR] terraform plan failed — see above` |
| `2` | Drift | `2` | `[DRIFT] Drift detected in terraform/${PHASE}` |
| precondition fail | No creds / no bucket | `3` | `[SKIP] Cannot assess drift — precondition missing` (stderr) |

On exit `2`, emit a structured table via `terraform show -json`:

```
[DRIFT] Drift detected in terraform/management
  replace       terraform_data.crossplane_aws_provider
  update        helm_release.crossplane
  ... (N more resources — full plan: /tmp/diff-state-management.tfplan)
```

Output budget: ≤5 KB; truncate at 30 rows. Matches SPEC-A5's budget
for consistent agent parsing.

On a clean exit `0` for `phase=management`, the script appends to stderr:

```
[INFO] Plan clean. If a manifest edit did not reach the cluster,
       check triggers_replace in terraform/management/helm.tf for
       sha256 coverage. See ai/handoff.md:144, PR #67.
```

This hint fires only for `phase=management` (the module with
`terraform_data` resources). Printed to stderr; suppressible with `2>/dev/null`.

### 5.5 Precondition gate

Before `terraform init`, the script validates in order:

1. `command -v terraform` — exit 1 if absent.
2. `aws sts get-caller-identity` exits 0 — exit 3 if no valid creds.
3. `aws s3api head-bucket --bucket "$TF_BACKEND_BUCKET"` exits 0 —
   exit 3 if bucket not found (fresh account, phase never applied).
4. `command -v python3` — if absent, skip the JSON structured table
   and emit raw plan text instead. Still exits 2 on drift.

Exit 3 (SKIP) matches SPEC-C5's convention; callers treat it
distinctly from a plan failure.

---

## 6. Tests required

Per AGENTS.md §6.1 and §6.4.

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_diff_state.sh` | `phase=base` and `phase=management` accepted; `phase=foo`, bare `base`, and no-arg all exit 1 with usage on stderr. |
| Unit | same | Stub `terraform` → exit 0: assert `diff-state.sh phase=management` exits 0, stdout contains `[CLEAN]`. |
| Unit | same | Stub `terraform` → exit 2; stub `terraform show -json` → two-resource fixture: assert exit 2, stdout contains `[DRIFT]` and both resource addresses. |
| Unit | same | Stub `terraform` → exit 1: assert `diff-state.sh` exits 1 and stdout contains `[ERROR]`. |
| Unit | same | Stub `aws sts get-caller-identity` to fail: assert exit 3 and `[SKIP]` on stderr. |
| Unit | same | 40-resource fixture: assert output ≤5 KB and truncation footer present. |
| Unit lint | same | `grep -c 'set -euo pipefail' scripts/diff-state.sh` ≥ 1; `grep -c 'lock=false' scripts/diff-state.sh` ≥ 1. |

Stubs live in `tests/unit/stubs/diff-state/` (executable wrappers on
`$PATH`). No AWS credentials required.

Per AGENTS.md §6.4, an adversarial subagent review MUST be dispatched
before the stub fixtures are finalized. Key probes: "What if
`terraform init -reconfigure` exits 1 on a lock-file mismatch?" and
"What if the state key is missing (phase never applied)?"

---

## 7. Testing suggestions (unit / integration / e2e)

**Unit** — fast, no live cluster. Add to `tests/unit/test_diff_state.sh`:

1. Stub returns a fixture with `terraform_data.crossplane_aws_provider`
   action `replace`; assert the address appears in the output table.
2. Stub returns a fixture with only a timestamp annotation change
   (Helm noise); assert the script exits 2 (no allowlist at this
   layer — noise filtering is SPEC-C5's domain) and logs the address.
3. Idempotency: run twice back-to-back against the same stub; assert
   both exits and outputs are byte-identical.
4. `phase=management` on a clean exit: assert the `triggers_replace`
   hint appears on stderr.

**Integration** — requires phases 0 and 1 applied. Manual or run as
part of the post-apply verify flow:

1. After `apply-and-verify phase=base`: `bash scripts/diff-state.sh
   phase=base` exits 0.
2. After `apply-and-verify phase=management`: `bash scripts/diff-state.sh
   phase=management` exits 0.
3. Negative path (manual, opt-in): out-of-band AWS tag mutation on a
   Terraform-managed resource (`aws eks tag-resource`). Run `diff-state.sh
   phase=base`. Assert exit 2 and the EKS resource address appears.
   Revert and confirm exit 0.
4. Negative path (manual, opt-in): edit a manifest local in
   `terraform/management/helm.tf` without applying. Run
   `diff-state.sh phase=management`. Assert exit 0 — the script
   reports state-vs-config, not working-tree-vs-config. Revert.

Cases 3 and 4 are operator-run smoke tests (require deliberate
environment mutation). Document in `scripts/README.md`.

**E2E** — not applicable. No Crossplane XRD/Composition surface and no
chainsaw scenario. The functional equivalent at E2E layer is SPEC-C5's
`99_no_drift.sh` (full integration suite). The deliberate scope limit —
no allowlist, no module sequencing — keeps the script fast and focused.

---

## 8. Documentation updates

- `/home/user/k8-platform/scripts/README.md` — one row: `diff-state.sh`,
  `phase=base|management`, "Compare Terraform state to declared config;
  exit 2 on drift. Fast post-apply spot-check."
- `/home/user/k8-platform/ai/testing-guidelines.md §3` — after the
  `apply-and-verify` step, add: *"Run `scripts/diff-state.sh
  phase=<module>` to confirm the apply changed state. Exit 0 = clean;
  exit 2 = drift (usually a `triggers_replace` gap — see PR #67)."*
- `/home/user/k8-platform/ai/handoff.md` — `terraform apply on management`
  critical rule row: append *"Confirm with `scripts/diff-state.sh`."*
- `AGENTS.md` — no change. §5 and §6 already cover the layers.

---

## 9. Workflow / auto-invocation wiring

`diff-state.sh` is **manually invoked only**. This is deliberate:

- AWS credentials are not available in the pre-commit environment.
- SPEC-C1 and SPEC-C5 cover the automated CI and integration-suite layers.
  A third automated invocation adds lock-contention risk with no new coverage.
- The use case is deliberate: agent picks up a session, suspects stale
  state, runs `diff-state.sh` before starting work.

The `terraform-ci-watch` Phase 3.5 (SPEC-A5) is the automated CI
equivalent. The only "auto-prompt" is the `ai/testing-guidelines.md §3`
addition.

---

## 10. Discoverability

1. **Mechanical enforcement** — `tests/unit/test_diff_state.sh` enforces
   the exit-code contract. If a future edit changes it, the test fails
   and `tests/unit/run.sh` (mandatory before phase sign-off, AGENTS.md §6.3)
   goes red.

2. **Documentation pointer** — `ai/testing-guidelines.md §3` names the
   command in the phase-loop. Any agent reading that section
   (mandatory per AGENTS.md §1) encounters it.

3. **Adversarial-review trigger** — when `diff-state.sh` is used as a
   precondition assertion in an integration test, AGENTS.md §6.4 fires
   before the test is finalized.

---

## 11. Verification checklist

- [ ] `bash tests/unit/test_diff_state.sh` exits 0 with 7 PASS lines.
- [ ] `bash tests/unit/run.sh` includes `test_diff_state.sh` and exits 0.
- [ ] `scripts/diff-state.sh phase=foo` exits 1 and stderr contains
      `phase=<base|management>`.
- [ ] `grep -c 'set -euo pipefail' /home/user/k8-platform/scripts/diff-state.sh`
      returns 1.
- [ ] `grep -c 'lock=false' /home/user/k8-platform/scripts/diff-state.sh`
      returns 1.
- [ ] On phases 0 and 1 applied: `bash scripts/diff-state.sh phase=base`
      exits 0 and stdout contains `[CLEAN]`.
- [ ] Same environment: `bash scripts/diff-state.sh phase=management`
      exits 0 and stdout contains `[CLEAN]`.
- [ ] `grep -c 'diff-state.sh' /home/user/k8-platform/scripts/README.md`
      returns ≥ 1.
- [ ] `grep -c 'diff-state.sh' /home/user/k8-platform/ai/testing-guidelines.md`
      returns ≥ 1.
- [ ] Wall-clock on a clean live environment: completes in ≤90 s for
      `phase=management`. If >120 s, investigate provider refresh overhead.

---

## 12. Rollout notes

- **Backward-compat:** additive only. No existing script, no existing
  CI step, nothing to break.
- **Audit-before-merge:** unit test uses stubs; no live cluster needed.
  Land the script and test in one PR. Integration smoke tests (§7
  Integration 3 and 4) are manual; document in `scripts/README.md`.
- **Sandbox compliance:** read-only AWS only (`sts get-caller-identity`,
  `s3api head-bucket`, `terraform plan -lock=false`). No resources
  created, no state written. Fits Pluralsight sandbox limits.
- **Stacking:** no dependency on any in-flight spec. When SPEC-B3 also
  lands, the two close authoring-time and runtime layers together.
- **Coordination:** no conflict with SPEC-C1 or SPEC-C5; those touch
  `.github/workflows/` and `tests/integration/`, this spec touches only
  `scripts/` and `tests/unit/`.

---

## 13. Estimated effort

**M** — medium.

Script authoring (~45 min): backend-derivation logic mirroring
`terraform-test.yml`, `terraform show -json` Python parse fragment,
and precondition gate. Unit test authoring (~45 min): stub setup
and exit-code contract verification; adversarial subagent review
(AGENTS.md §6.4) adds ~30 min. Documentation edits (~20 min):
three files, each one line. Live smoke test (~30 min): clean-exit
and negative-path validation against phases 0/1. Review (~20 min).

Total: ~2.5–3 focused hours. Pays for itself the first time an agent
needs to ask "did that apply actually land?" and gets the answer in
30 seconds.
