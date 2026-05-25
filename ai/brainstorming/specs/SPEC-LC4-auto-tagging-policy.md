# SPEC-LC4 — Auto-tagging policy: `default_tags` in every `provider "aws"` block

**Tier:** C  **Brainstorm IDs:** A1-054, A1-006 (indirect)  **Cluster:** 5 prerequisite (PR-5.0)

---

## 1. Summary

Add `k8platform-phase` and `k8platform-component` to the `default_tags` block
in every `provider "aws"` block under `terraform/`. Currently both modules carry
`Project`, `ManagedBy`, and `Environment` (and `management/` additionally carries
`Cluster`). This spec extends those maps with two keys that scope resources to the
phase and component that created them. On the next `terraform apply` against an
already-live module the AWS provider issues `tag:TagResources` calls in-place on
every existing resource — no recreation, no downtime. The smallest concrete
artifact is two HCL edits (one per `versions.tf`), one unit-test shell script, and
one integration-test shell script. This spec is also the standalone prerequisite for
SPEC-C3 (tag-assertion sub-step in `terraform-ci-watch`) and for SPEC-C5's
drift-detection to operate against a well-tagged baseline. It is part of
`CLUSTERING-REVIEW.md` Cluster 5 as **Prerequisite PR-5.0**.

---

## 2. Retro pain killed

- **Cross-session orphan attribution.** Per `AGENTS.md §8.1`, the AWS account
  is rotated between sessions. When a teardown is partial the next session inherits
  leftover resources with no machine-readable phase attribution — `aws iam list-roles`
  returns a soup of phase-0, phase-1, and ad-hoc roles. A `--tag-filters
  Key=k8platform-phase,Values=1` query makes scoped cleanup a one-liner.

- **Phase-2 IRSA cascade orphan cost (`retrospective/2026-05-25-70.md`, PRs #66–#68).**
  Multiple IAM roles were created and re-created across five iterations as the IRSA
  trust relationship was debugged. When the account rotated mid-cascade the next
  session could not tell which roles were "phase-1 management" vs "phase-2 ad-hoc
  iteration". Two sub-sessions were spent triaging before actual bug work resumed.
  Phase-scoped tags would have narrowed the triage to `k8platform-phase=2` resources
  immediately.

- **"Name = k8-platform-\<x\>" naming hacks.** Brainstorm A1-054 comment A6→A1-008
  explicitly calls out that per-resource `Name` prefixes exist as a "poor-man's tag"
  because AWS tags were not query-reliable. With `k8platform-phase` in `default_tags`,
  the Name prefix becomes redundant as a filter mechanism — it is queryable by tag.

- **`AGENTS.md §5.1` teardown ambiguity.** "Tear down phase X" relies on the
  operator knowing which resources a phase introduced; no machine-readable
  attribution means cross-referencing commit history at teardown time. A
  `--tag-filters Key=k8platform-phase,Values=N` pre-flight query closes that gap.

- **Missing CloudWatch / Cost Explorer phase-scope.** Brainstorm A1-006 targets a
  Logs Insights saved query for IRSA failures scoped per phase. That query cannot
  filter by phase without a phase tag on the log group or the resource that emitted
  the log. `k8platform-phase` in `default_tags` is the prerequisite that makes those
  per-phase CloudWatch queries feasible.

---

## 3. Out of scope

- **SPEC-C3 (tag-assertion sub-step in `terraform-ci-watch`).** That skill
  enhancement depends on this spec but is not authored here. SPEC-C3 is the consumer
  of the tags this spec creates; this spec only adds the tags to Terraform.

- **SPEC-C5 (integration drift check).** SPEC-C5 benefits from a stable tagged
  baseline but is its own spec. No SPEC-C5 code is written here.

- **Crossplane Managed Resource tagging.** Crossplane-composed AWS resources follow
  a different tagging path — `spec.forProvider.tags` inside each Composition. That
  is a separate spec. This spec stops at the Terraform/provider boundary.

- **Cost-allocation or billing tags.** Tags required for AWS Cost Explorer (`Owner`,
  `CostCenter`, `Environment`) are outside scope. The Pluralsight sandbox does not
  surface a billing console, and those tags are a separate governance concern.

- **SPEC-A1 chain-walk tag enrichment.** A SPEC-A1 concern; this spec stops at the
  Terraform provider boundary.

- **Tag value validation.** A future spec could assert `k8platform-phase ∈ {0..6}`.
  This spec only asserts both keys exist with non-empty literal values.

### Considered and rejected

- **Per-resource `tags = {}` blocks instead of `default_tags`.** Rejected because
  `default_tags` is applied by the provider to every taggable resource the module
  manages, without per-resource repetition. A per-resource approach would require
  editing every `aws_*` resource declaration in both modules (30+ blocks) and would
  drift every time a new resource is added without the tags. `default_tags` is the
  authoritative AWS provider mechanism for this pattern.

- **A Terraform variable for the phase value.** Rejected because the phase is a
  structural property of the module's directory, not a deployment-time decision.
  A caller could pass `k8platform-phase = "99"` and the tag would silently lie.
  Hardcoding the literal string in the HCL is the correct choice; the lint test
  (`§6`) enforces the key is present as a literal.

- **Deriving the phase at runtime from the state file path.** Rejected because state
  file path conventions are configurable and not guaranteed stable across accounts or
  CI runs. The literal in HCL is zero-dependency.

---

## 4. Files to change / create

### Modify

| Path | What changes |
|---|---|
| `/home/user/k8-platform/terraform/base/versions.tf` | Add `k8platform-phase = "0"` and `k8platform-component = "base"` to the existing `default_tags { tags = { ... } }` block. Existing keys (`Project`, `ManagedBy`, `Environment`) stay unchanged. |
| `/home/user/k8-platform/terraform/management/versions.tf` | Add `k8platform-phase = "1"` and `k8platform-component = "management"` to the existing `default_tags { tags = { ... } }` block. Existing keys (`Project`, `ManagedBy`, `Cluster`, `Environment`) stay unchanged. |
| `/home/user/k8-platform/AGENTS.md` | §10 Terraform conventions — add one bullet: `Every provider "aws" block declares default_tags with at minimum k8platform-phase and k8platform-component keys; the unit test test_terraform_default_tags.sh enforces this.` |
| `/home/user/k8-platform/ai/testing-guidelines.md` | Testing-loops section — add one paragraph noting that `test_terraform_default_tags.sh` (unit) and `12_terraform_tag_attribution.sh` (integration) enforce the tag-presence contract, and citing this spec and SPEC-C3. |

### Create

| Path | What changes |
|---|---|
| `/home/user/k8-platform/tests/unit/test_terraform_default_tags.sh` | NEW. Asserts every `provider "aws"` block in `terraform/**/*.tf` declares a `default_tags` block whose `tags = { ... }` map contains literal keys `k8platform-phase` and `k8platform-component` with non-empty values. No AWS calls; runs in < 2 s. |
| `/home/user/k8-platform/tests/integration/12_terraform_tag_attribution.sh` | NEW. After `apply-and-verify` on phase 0 or 1, queries `aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=k8-platform` and asserts every returned tag-capable resource carries both `k8platform-phase` and `k8platform-component`. Mirrors SPEC-C3's runtime check at integration-suite level. |

---

## 5. Implementation notes

### HCL fragment — `terraform/base/versions.tf`

The existing `default_tags` block at line 25 becomes:

```hcl
default_tags {
  tags = {
    Project           = "k8-platform"
    ManagedBy         = "terraform"
    Environment       = var.environment
    k8platform-phase  = "0"
    k8platform-component = "base"
  }
}
```

Key naming uses hyphens (`k8platform-phase`, not `k8platform_phase`) consistent with
the existing `Project` key and to make `--tag-filters Key=k8platform-phase,Values=0`
unambiguous in CLI invocations.

### HCL fragment — `terraform/management/versions.tf`

```hcl
default_tags {
  tags = {
    Project              = "k8-platform"
    ManagedBy            = "terraform"
    Cluster              = "management"
    Environment          = var.environment
    k8platform-phase     = "1"
    k8platform-component = "management"
  }
}
```

### Tag value derivation

The phase value is a hardcoded string literal in the HCL file, not a variable.
This is intentional (see §3 "Considered and rejected"). The component value mirrors
the module directory name (`base`, `management`). For future modules the pattern is
`k8platform-phase = "<N>"` where N is the digit from the `ai/handoff.md` phase
table, and `k8platform-component = "<module-dir-name>"`.

If a `provider "aws" { alias = "..." }` block is added for multi-region work
(anticipated in phase 3 multi-cluster) it receives the same `default_tags` map as
the primary provider. The lint test in `§6` checks all `provider "aws"` occurrences,
including aliased ones, so forgetting an aliased block fails CI immediately.

### Unit-test implementation shape

`tests/unit/test_terraform_default_tags.sh`: `find terraform -name '*.tf'`, for
each file containing `provider "aws"` assert the literal strings `k8platform-phase`
and `k8platform-component` are present; exit 1 with the filename if not. The
`grep` approach is sufficient because tag values are static string literals. If
`hcl2json` is on the runner a structural parse may be used as an enhancement;
the grep is the required minimum. Auto-discovered by `tests/unit/run.sh` via
`test_*.sh` glob.

### Integration-test implementation shape

`tests/integration/12_terraform_tag_attribution.sh` calls
`aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=k8-platform" --region "$AWS_REGION" --output json`,
iterates returned resources (minus allowlist), and asserts both `k8platform-phase`
and `k8platform-component` are present with non-empty values. On first-run the
tagging API has an eventual-consistency window of up to 30 seconds; the test retries
up to 3 times with a 15-second sleep before failing.

**Allowlist of tag-incompatible resource types** (embedded as a bash array in the
test file; extended as new incompatibilities surface):

```bash
TAG_EXEMPT_TYPES=(
  "AWS::Route53::RecordSet"       # records not taggable; zone is
  "AWS::IAM::Policy"              # inline policies not taggable directly
  "AWS::S3::BucketPolicy"         # sub-resource of bucket
  "AWS::Cognito::UserPoolClient"  # app client not taggable
)
```

The allowlist is owned here (the integration test), not in a separate reference
file, because this spec does not write to the skill layer. When SPEC-C3 is
implemented it will import the same list into its `reference/tag-assertion.md`;
that import step is SPEC-C3's responsibility.

### Cross-references

- **SPEC-C3** — consumes these tags; its PR (PR-5) must stack on this PR (PR-5.0).
- **SPEC-C5** — benefits from a clean post-tag baseline so the first drift run does
  not see spurious `~ update` plan lines from tag additions.
- **AGENTS.md §8.1** — ephemeral account rotation is the architectural reason
  tag-based phase attribution matters; without it, orphan triage costs sessions.

---

## 6. Tests required

Per `AGENTS.md §6.1`:

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_terraform_default_tags.sh` | Every `provider "aws"` block in `terraform/**/*.tf` declares `k8platform-phase` and `k8platform-component` as literal keys with non-empty values. No AWS calls; < 2 s. Meta-test: introduce a scratch `provider "aws" {}` block without the keys and confirm the test fails red before reverting. |
| Integration | `tests/integration/12_terraform_tag_attribution.sh` | After `apply-and-verify` on phase 0+1, `resourcegroupstaggingapi get-resources` returns ≥ 1 resource; every non-exempt resource carries both tag keys with non-empty values. Retries 3× with 15 s sleep to tolerate eventual consistency. |

Per `AGENTS.md §6.4`, the test plan above is subject to adversarial-subagent review
before authoring. Known gaps to probe: (a) does the unit test catch an aliased
`provider "aws" { alias = "..." }` block that lacks the tags? (b) does the
integration test skip cleanly (not fail) when AWS creds are absent? (c) does the
retry loop correctly handle an empty first page from the tagging API?

---

## 7. Testing suggestions (unit / integration / e2e)

These are catalogue items for follow-on test maturation, distinct from the gate
tests in §6.

### Unit

- `test_terraform_default_tags.sh` (gate test, §6) — already covers the presence
  check. Follow-on: extend with an `hcl2json`-based structural check that the keys
  appear inside a `default_tags { tags = { ... } }` block specifically, not at an
  arbitrary nesting level.
- A negative fixture: add a `testdata/provider_missing_tags.tf` file with a bare
  `provider "aws" {}` block and confirm the unit test fails when pointed at that
  directory. This proves the lint fires; the fixture is reverted or placed in a
  dedicated `tests/unit/fixtures/` directory and excluded from the main `find` glob.
- A structural assertion that the phase value is a single digit string matching
  `[0-9]` — prevents accidental `k8platform-phase = "phase-0"` typos.

### Integration

- `12_terraform_tag_attribution.sh` (gate test, §6) — covers live tag presence.
  Follow-on: add a phase-value validation assertion (`k8platform-phase` value is
  `"0"` for base-module resources and `"1"` for management-module resources), not
  just non-empty presence. This catches a misconfigured copy-paste where both
  modules receive `phase = "0"`.
- After a `terraform destroy` + `terraform apply` cycle on `terraform/base/`,
  re-run the integration test to confirm the tags survive the destroy/apply cycle
  and are not silently dropped on resource recreation.
- Confirm that resources created by the management module's `helm_release` resources
  (which do not go through the AWS provider `default_tags` path) are excluded
  from the assertion rather than causing false-positive failures.

### E2E

Not applicable. This spec changes Terraform HCL only — no Crossplane XRD, no
Kubernetes resource, no chainsaw scenario. The §6 integration test is the closest
analogue because it runs against the live AWS account. No `tests/chainsaw/` or
`tests/e2e/` artifacts are needed.

---

## 8. Documentation updates

- `/home/user/k8-platform/AGENTS.md` §10 — add one bullet for the `default_tags`
  requirement (see §4 "Modify" table). This ensures future module authors see the
  rule before writing a new `provider "aws"` block.
- `/home/user/k8-platform/ai/testing-guidelines.md` — testing-loops section: one
  paragraph citing `test_terraform_default_tags.sh` and `12_terraform_tag_attribution.sh`
  as the enforcement layer for tag presence, cross-referencing this spec and SPEC-C3.
- `/home/user/k8-platform/ai/handoff.md` — Pending follow-ups: note that PR-5.0
  (this spec) must land and be applied before PR-5 (SPEC-C3 + SPEC-A5 skill work)
  is opened.

---

## 9. Workflow / auto-invocation wiring

This spec has no new workflow files or hooks. The existing
`.github/workflows/unit-tests.yml` picks up `test_terraform_default_tags.sh`
automatically via its `tests/unit/test_*.sh` glob — no workflow edit needed.

The integration test `12_terraform_tag_attribution.sh` is discovered by
`tests/integration/run.sh` via the same numeric-prefix glob already in use.

The terraform-validate workflow (`.github/workflows/terraform-validate.yml`) will
exercise the modified `versions.tf` files on every push, confirming the HCL is
syntactically valid before any apply.

No `terraform-test.yml` dispatch is needed to merge this PR; unit-tests and
terraform-validate (both fast, every push) are sufficient for the merge gate.
The apply-and-verify step that confirms tags reach live resources is a manual
operator step per §12.

---

## 10. Discoverability

1. **Mechanical enforcement.** `tests/unit/test_terraform_default_tags.sh` runs on
   every push via `unit-tests.yml`. A new `provider "aws"` block that lacks
   `k8platform-phase` causes the unit-tests workflow to go red immediately, before
   any apply. The failure message names the file and the missing key.

2. **Documentation pointer.** `AGENTS.md §10 Terraform conventions` will include
   the `default_tags` bullet after this spec is implemented. Any agent reading the
   conventions section before authoring a new Terraform module sees the rule. The
   same section references `test_terraform_default_tags.sh` so the agent can run it
   locally before pushing.

3. **Adversarial-review trigger.** Per `AGENTS.md §6.4`, any PR that introduces a
   new `provider "aws"` block triggers a test-plan adversarial review. The reviewer
   brief for such a PR should include this spec's unit test as a known existing check
   and probe whether the new module's provider block has been added to the lint's
   search scope.

---

## 11. Verification checklist

After implementing this spec, the implementing agent runs:

- [ ] `grep -n 'k8platform-phase\|k8platform-component' /home/user/k8-platform/terraform/base/versions.tf` — returns two lines with non-empty string literals.
- [ ] `grep -n 'k8platform-phase\|k8platform-component' /home/user/k8-platform/terraform/management/versions.tf` — returns two lines with non-empty string literals.
- [ ] `bash /home/user/k8-platform/tests/unit/test_terraform_default_tags.sh` — exits 0, prints `OK: all provider "aws" blocks carry required tags`.
- [ ] Introduce a temporary bare `provider "aws" {}` in a scratch `.tf` file, re-run the unit test, confirm it exits 1 and names the file. Remove the scratch file.
- [ ] `terraform validate` passes in both `terraform/base/` and `terraform/management/` (no change to provider API; validates syntax only).
- [ ] `terraform plan` against each module (with real backend config) shows only `~ update` lines for tag additions — zero resource recreations, zero deletions.
- [ ] After `terraform apply` in phase-base environment: `aws resourcegroupstaggingapi get-resources --tag-filters "Key=k8platform-phase,Values=0" --region $AWS_REGION --output json | jq '.ResourceTagMappingList | length'` returns ≥ 1.
- [ ] After `terraform apply` in phase-management environment: same query with `Values=1` returns ≥ 1.
- [ ] `bash /home/user/k8-platform/tests/integration/12_terraform_tag_attribution.sh` exits 0 against a live phase-0+1 cluster.
- [ ] `AGENTS.md §10` contains the `default_tags` bullet.
- [ ] `ai/testing-guidelines.md` testing-loops section references both new test files.
- [ ] `ai/handoff.md` Pending follow-ups entry notes the PR-5 (SPEC-C3) dependency on this PR.

---

## 12. Rollout notes

### Backward compatibility — existing resources retagged in-place

When `terraform apply` runs against a module with an extended `default_tags` block
the AWS provider calls `tag:TagResources` (or the service-specific tag API) on
every resource it manages. This is an in-place mutation — no resource is recreated,
no ARN changes, no downtime. The `terraform plan` diff shows `~ update` lines for
every tag-capable resource; this is expected. Tag-incompatible resources (Route53
record sets, inline IAM policies, S3 bucket policies) generate no plan lines.

This is the one-shot drift on apply: the first `terraform apply` after this PR merges
pushes the new tags to all existing resources in `terraform/base/` and
`terraform/management/`. All new resources receive the tags automatically thereafter.

### Audit before merge

The unit test must pass against the post-edit tree before the PR is opened. The PR
modifies the only two existing `provider "aws"` blocks and adds the lint that checks
them — the lint lands green in the same commit.

### Pluralsight sandbox constraints

`tag:TagResources` is available in `us-east-1` and `us-west-2`. No EC2 instance
limit is affected. Fully compatible with the constraints in `ai/testing-guidelines.md §1`.

### Coordination with in-flight branches

Per `CLUSTERING-REVIEW.md` §Cluster-5: this PR (PR-5.0) must land before PR-5
(SPEC-A5 + SPEC-C3 skill work) — the tag-assertion sub-step in PR-5 would fire
red against any cluster that has not yet applied the new default tags. PR-5.0
must also land before Cluster 3 (SPEC-C5 drift detection) so the two new tag keys
are part of the drift-free baseline. No dependency on Clusters 1, 2, or 4.

### Branch sequencing

```
main
  └── feat/lc4-default-tags-phase-component   (this spec — PR-5.0)
        └── feat/cluster5-terraform-ci-watch  (PR-5 — SPEC-A5 + SPEC-C3, base = PR-5.0)
```

---

## 13. Estimated effort

**S** (≤ 1 hour): authoring ~15 min (two four-line HCL edits, literal values
are already determined); unit test ~15 min (single `find`-and-`grep` loop per §5,
auto-discovered by `run.sh`); integration test ~15 min (one AWS API call plus
retry loop and allowlist array); rollout audit ~10 min (two `terraform plan`
previews confirming only `~ update` lines, no resource recreations); smoke test
~5 min (unit test requires no AWS; integration test optional if a live cluster
is up). Total approximately 60 minutes. No new infrastructure pattern is
introduced — `default_tags` is already present in both modules; this spec only
extends the existing map with two keys and adds the lint that enforces the
convention for future modules.
