# SPEC-C3 — terraform-ci-watch: assert k8platform-phase + k8platform-component tags on applied resources

## Summary

Extend the `terraform-ci-watch` skill so that after a green `terraform apply`
in CI, the skill samples the freshly-applied AWS resources via the Resource
Groups Tagging API and asserts that each tag-capable resource carries both
`k8platform-phase` and `k8platform-component` tags. As a prerequisite (called
out but **not** implemented by this spec), every `provider "aws"` block under
`terraform/` must add a `default_tags` entry that injects those two keys with
phase- and component-appropriate values, so the assertion can pass without
per-resource tag plumbing.

## Retro pain killed

- **Cross-session orphan cleanup after account rotation.** Per `AGENTS.md §8.1`
  and the late-2026-05-24 quickstart in `ai/handoff.md`, the AWS test account
  is rotated between sessions and the prior account is usually torn down in
  full. When a teardown is partial (or a session ends mid-iteration), the
  next session inherits a soup of leftover EC2/NLB/IAM/Route53/S3 resources
  with no reliable way to attribute each one to a phase or component. The
  current `Project = k8-platform` default tag is too coarse to drive a
  `aws resourcegroupstaggingapi get-resources` cleanup query scoped to (e.g.)
  "everything phase 2 created".
- **Phase-2 IRSA cascade (PRs #66–#68, `retrospective/2026-05-25-70.md`).**
  Multiple cluster-side resources (the Crossplane provider SA, the IRSA role,
  the ASM secrets created by claims) were created and re-created across five
  iterations. When the account was rotated mid-cascade the next session had
  no way to know which IAM roles/policies were "phase 1 management" vs
  "phase 2 ad-hoc" — everything looked the same to `aws iam list-roles`.
  Two of those iterations were spent triaging orphans before the actual
  bug work resumed.
- **Phase-0 / phase-1 mixed teardown ambiguity.** `AGENTS.md §5.1` defines
  "tear down phase X" precisely, but the operator running the teardown has
  no machine-readable signal on a live resource that says "I belong to
  phase X." A tag-based query (`Tags.k8platform-phase=2`) would make
  scoped teardown a one-line CLI invocation.

## Out of scope

- **Cost-allocation tag enforcement.** This spec does not assert tags
  required for AWS Cost Explorer / billing reports (`Environment`,
  `Owner`, `CostCenter`, etc.). Those are a separate concern and the
  Pluralsight sandbox does not surface a billing console anyway.
- **Resources created by Crossplane.** Crossplane-managed AWS resources
  (XR-composed ASM Secrets, EKS clusters provisioned by `PlatformCluster`,
  etc.) follow a different tagging path — they need provider-side
  `spec.forProvider.tags` plumbing in the Composition. That is a separate
  spec; this one stops at the Terraform/provider boundary.
- **Auto-fixing tag-missing resources.** On a failed assertion the skill
  reports and escalates per its existing three-strike rule; it does not
  attempt to mutate live AWS state.
- **Backfilling tags on previously-applied resources.** The skill checks
  resources from the *just-completed* apply, not historical state.
- **Enforcing tag *values* beyond presence + non-empty.** A future spec
  could lint that `k8platform-phase ∈ {0,1,2,3,4,5,6}`; this one only
  asserts both keys exist with non-empty values.
- **Spec implementation.** This document is design only.

## Files to change / create

| Path | What changes |
|---|---|
| `.claude/skills/terraform-ci-watch/SKILL.md` | Add a new **Phase 3.5 — Sample tags on applied resources** sub-step that runs after Phase 3 (on success) but before the success report. Front-matter `description` gains the phrase "tag-attribution check after green apply" so the trigger surface includes the new behavior. `allowed-tools` adds `Bash` (already present) and the AWS CLI commands needed (already covered by `Bash`). |
| `.claude/skills/terraform-ci-watch/reference/tag-assertion.md` | **NEW.** Reference doc holding: required tag keys (`k8platform-phase`, `k8platform-component`); the AWS API call (`aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=k8-platform`); the resource-type allowlist of types that do NOT support AWS tagging (see Implementation notes); the sampling rule (≤20 resources, deterministic ordering by ARN to make output diffable); the failure-output shape (one line per offender: `MISSING <key> on <arn>`); the ≤5 KB output cap and truncation rule. |
| `.claude/skills/terraform-ci-watch/reference/failure-taxonomy.md` | Add one new taxonomy entry: `tag-attribution-missing — escalate` (do not auto-fix; the fix lives in Terraform module code, not in skill-level retries). |
| `terraform/base/versions.tf` (PREREQUISITE — separate PR, not this spec) | Existing `provider "aws"` `default_tags` block extends to include `k8platform-phase = "0"` and `k8platform-component = "base"`. Existing keys (`Project`, `ManagedBy`, `Environment`) stay. |
| `terraform/management/versions.tf` (PREREQUISITE — separate PR) | `default_tags` extends to include `k8platform-phase = "1"` and `k8platform-component = "management"`. |
| Any future `provider "aws"` block in `terraform/**` | Same pattern. Unit test below enforces it for new modules. |
| `tests/unit/test_terraform_default_tags.sh` (NEW, lives outside this spec's write scope — referenced as a prerequisite test) | Asserts every `provider "aws"` block in `terraform/**/*.tf` declares a `default_tags` block whose `tags = {...}` map contains both `k8platform-phase` and `k8platform-component` keys with non-empty literal values. |
| `tests/integration/12_terraform_tag_attribution.sh` (NEW, prerequisite test) | After `apply-and-verify` on phase 0 or 1, runs the same `resourcegroupstaggingapi get-resources` query the skill runs and asserts ≥1 resource present, all sampled resources tagged. |
| `ai/testing-guidelines.md` | One paragraph in the testing-loops section pointing at the new skill sub-step + the prerequisite unit/integration tests. |
| `AGENTS.md` §10 Terraform conventions | One bullet: "Every `provider \"aws\"` block declares `default_tags` with at minimum `k8platform-phase` and `k8platform-component` keys; the `terraform-ci-watch` skill asserts the tags reached live resources." |

This spec only *writes* to `ai/brainstorming/specs/SPEC-C3-...`. The skill
edit, the doc edits, and the `default_tags` prerequisite all happen in the
follow-on PRs that implement it.

## Implementation notes

### Which AWS API to call

Use `aws resourcegroupstaggingapi get-resources`. It is region-scoped,
supports `--tag-filters Key=Project,Values=k8-platform` to narrow output
to k8-platform-owned resources, and returns ARN + tag map for each entry
in a single paginated call. Available in both `us-east-1` and `us-west-2`
(the only two regions the sandbox allows per `ai/aws-test-environment-limitations.md`).

Alternative considered and rejected: walk CloudTrail `LookupEvents` for
the apply's time window. Higher fidelity (every CreateResource call is
attributable to the apply session) but CloudTrail is not guaranteed
available in the Pluralsight sandbox, and its event lag is 5–15 minutes
— larger than the entire apply CI step. Use CloudTrail only as a
best-effort attribution annotation on the offender line, never as the
authoritative resource list.

### How to scope the query to the recently-applied resources

Two-step scoping:

1. **Coarse pre-filter via tag.** `--tag-filters Key=Project,Values=k8-platform`
   trims output to k8-platform-owned ARNs (relies on the existing
   `Project = k8-platform` default tag, which is already present on
   every applied resource and survives the prerequisite addition).
2. **Fine scoping via terraform state.** Parse the apply step's stdout
   for `terraform state pull | jq -r '.resources[].instances[].attributes.arn'`
   and intersect with the API result. Resources that appear in tf state
   but NOT in the tagging-API result fall into one of two buckets:
   - The resource type is tag-incompatible — allowlisted, no offense.
   - The resource type is tag-capable but the apply forgot a tag — REAL
     offense, report.

The intersection is what gets sampled (deterministic order by ARN,
truncated to 20 entries, ≤5 KB output total per `failure-taxonomy.md`
emit budget).

### Allowlist for tag-incompatible resource types

AWS resource types known not to support tags (non-exhaustive — extend as
encountered):

- IAM trust policies (`AWS::IAM::Role` attribute `AssumeRolePolicyDocument`
  — the role itself *is* taggable, but the policy document inside it is
  not a resource).
- IAM inline policies (`aws_iam_role_policy`, `aws_iam_user_policy`).
- Route53 record sets (`aws_route53_record` — the zone is taggable,
  the records are not).
- S3 bucket policies, lifecycle configurations, ACL resources (the
  bucket is taggable, the sub-resources are not).
- EKS access entries (`aws_eks_access_entry`) — taggable on most
  AWS-CLI versions but historically not; check at runtime.
- Cognito user-pool app clients (`aws_cognito_user_pool_client`).
- VPC default route table associations.

The allowlist lives in `reference/tag-assertion.md` as a yaml list keyed
by Terraform resource type, with a one-line note per entry justifying
the exemption. New entries added by Edit when the skill encounters a
false positive in the wild.

### Output budget (≤5 KB)

Per the existing `reference/log-fetching.md` ≤5 KB convention. Format:

```
TAG-ATTRIBUTION OK: 17/17 sampled resources carry both required tags.
```

or on failure:

```
TAG-ATTRIBUTION FAIL: 3 of 17 sampled resources missing required tags.
  MISSING k8platform-phase on arn:aws:ec2:us-east-1:...:security-group/sg-abc
  MISSING k8platform-component on arn:aws:elbv2:us-east-1:...:loadbalancer/...
  MISSING k8platform-phase on arn:aws:iam::...:policy/k8-platform-mgmt-extra
[truncated: 1 additional offender, see html_url for full list]
```

## Tests required

Per `AGENTS.md §6.1`:

| Layer | Test | Path | Assertion |
|---|---|---|---|
| Unit | `default_tags` block presence | `tests/unit/test_terraform_default_tags.sh` | Every `provider "aws"` block in `terraform/**/*.tf` declares `default_tags { tags = { ... } }` with literal keys `k8platform-phase` and `k8platform-component` both non-empty. Uses `hcl2json` (already on the unit-test runner) or a focused `grep -Pzo` regex. Runs in <2 s, no AWS calls. |
| Unit | Allowlist sanity | `tests/unit/test_tag_assertion_allowlist.sh` | The yaml allowlist in `reference/tag-assertion.md` parses, every entry has a `terraform_type` key and a `justification` key, no duplicate entries. |
| Integration | Live tag attribution | `tests/integration/12_terraform_tag_attribution.sh` | After `apply-and-verify` phase 0 or 1, runs `aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=k8-platform --region $AWS_REGION`, asserts response is non-empty, asserts each returned resource (minus allowlist) carries both `k8platform-phase` and `k8platform-component` tag keys with non-empty values. Mirrors the skill's runtime check; catches drift if a future Terraform module forgets `default_tags`. |
| Integration | Skill end-to-end | embedded in the prior test | Optionally re-uses the skill's reference doc by sourcing the allowlist file, so the test and the skill cannot diverge silently. |

Per `AGENTS.md §6.4`, the test plan above goes through adversarial-subagent
review before authoring — known gaps to flag for the reviewer: (a) does
the unit test handle a `provider "aws"` block that uses `alias =` for
multi-region setups (we don't have any today but phase 3 multi-cluster
work will); (b) does the integration test handle the empty-result case
on a fresh account where the apply just started (race window); (c) does
it tolerate eventual consistency on the tagging API (≤30 s typical lag
between resource creation and tag-API visibility — wrap with retry).

## 7. Testing suggestions (unit / integration / e2e)

**This section is mandatory in every spec.** §6 is the gate (the spec
is not done without those tests); §7 is the broader catalogue of tests
one might add as the surrounding system matures.

### Unit

Fast (<10 s each), no AWS calls. Names follow `tests/unit/test_<name>.sh`.

1. **`tests/unit/test_terraform_default_tags.sh` — provider block presence.**
   Asserts every `provider "aws"` block in `terraform/**/*.tf` carries
   `default_tags { tags = { ... } }` with literal keys `k8platform-phase`
   and `k8platform-component`, both non-empty. Exercises the aliased-provider
   path (for future multi-region modules) as a separate fixture.
2. **`tests/unit/test_tag_assertion_allowlist.sh` — allowlist schema.**
   Parses `reference/tag-assertion.md` yaml; asserts every entry has
   `terraform_type` and `justification` keys with no duplicate `terraform_type`
   values. Catches copy-paste omissions when a new exemption is added.
3. **`tests/unit/test_tag_assertion_output_budget.sh` — output cap.**
   Feeds a synthetic 25-offender list through the offender-line formatter
   and asserts total output is ≤5 KB with the truncation notice present
   for the 21st+ entry.
4. **`tests/unit/test_terraform_default_tags.sh` — aliased provider fixture.**
   Validates that a fixture file containing `provider "aws" { alias = "west" }`
   also requires a `default_tags` block; prevents a regression when phase-3
   multi-cluster work introduces regional aliases.
5. **`tests/unit/test_tag_assertion_allowlist.sh` — no-duplicate guard.**
   Deliberately injects a duplicate `terraform_type` entry and asserts the
   test script exits non-zero, proving the guard itself works.

### Integration

Against a live cluster (kind or sandbox EKS). Names follow
`tests/integration/<NN>_<name>.sh`.

1. **`tests/integration/12_terraform_tag_attribution.sh` — live tag presence.**
   After `apply-and-verify` on phase 0 or 1, calls
   `aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=k8-platform`
   and asserts: (a) response is non-empty; (b) every returned ARN not in
   the allowlist carries both `k8platform-phase` and `k8platform-component`
   with non-empty values.
2. **`tests/integration/12_terraform_tag_attribution.sh` — eventual-consistency retry.**
   Wraps the API call in a retry loop (≤30 s, 5 s sleep) and asserts the
   test does not flake on a resource that was tagged but not yet indexed.
3. **`tests/integration/12_terraform_tag_attribution.sh` — allowlist cross-check.**
   Sources `reference/tag-assertion.md` allowlist at runtime so the
   integration test and the skill cannot diverge silently; asserts the
   sourced list is non-empty (prevents a silent empty-allowlist false-pass).
4. **`tests/integration/12_terraform_tag_attribution.sh` — empty-account guard.**
   On a freshly-rotated account where no apply has run yet, the test must
   exit 0 (zero resources is not a failure) rather than raising a false alarm.

### E2E

Not applicable for this spec. The tag-attribution check runs inside the
`terraform-ci-watch` skill which is already exercised end-to-end by the
skill's own chainsaw / workflow scenarios; no additional
`tests/chainsaw/` or `tests/e2e/` scenario is needed here. If a future
spec adds a full-stack teardown probe that asserts orphan-free state after
account rotation, it can include the tag-attribution query as one assertion.

## 8. Documentation updates

- `.claude/skills/terraform-ci-watch/SKILL.md` — new Phase 3.5 section,
  description-line edit for trigger surface.
- `.claude/skills/terraform-ci-watch/reference/tag-assertion.md` — NEW
  reference file (required keys, API call, allowlist, output format).
- `.claude/skills/terraform-ci-watch/reference/failure-taxonomy.md` —
  add `tag-attribution-missing` entry.
- `ai/testing-guidelines.md` — testing-loops section gains one paragraph
  describing the new skill sub-step and the prerequisite tests.
- `AGENTS.md §10 Terraform conventions` — one bullet codifying the
  `default_tags` requirement (so future modules don't forget).
- `ai/handoff.md` — Pending follow-ups entry pointing at the prerequisite
  PR (default_tags addition) and the skill PR (Phase 3.5 addition).

## 9. Workflow / auto-invocation wiring

Per `AGENTS.md §7`, `terraform-ci-watch` is already auto-invoked after
every push that affects Terraform. The new Phase 3.5 runs inside that
existing invocation — no new wiring, no new workflow file. The check
fires only after Phase 3 reports green; on a failed apply, Phase 4
handles the failure first and Phase 3.5 does not run.

If the tag-attribution sub-step itself fails (assertion-fail, not
operational error), the skill emits the offender block and exits with
the existing escalation template — no auto-retry.

For dispatched `terraform-test.yml` runs (the only path that actually
applies anything live), the skill picks up the apply step's stdout from
the workflow log it already fetches in Phase 4 — no new log-fetching
plumbing.

## 10. Discoverability for future agents

- **Failed-check naming.** When tag attribution fails, the offender line
  includes the full ARN, which a downstream agent can resolve via
  `aws <service> describe-<resource> --<id>` to find what created it.
  The ARN is durable across sessions in the sense of "uniquely names a
  cloud resource the human can click through to in the console"; the
  resource itself is ephemeral per `AGENTS.md §8.1`.
- **Dashboard query reuse.** Once `k8platform-phase` is live on every
  resource, ad-hoc cleanup queries become trivial:
  `aws resourcegroupstaggingapi get-resources --tag-filters Key=k8platform-phase,Values=2`
  returns every phase-2 resource for inspection or scoped destroy.
- **Pairs with SPEC-A1 (chain-walk).** The Crossplane chain-walk spec
  can include the resource's `k8platform-phase` tag in its chain block —
  e.g., "this MR's underlying ASM secret is tagged phase=2, component=platform-secret"
  — closing the loop between IRSA-trust diagnostics and resource-attribution.
- **Cross-skill reuse.** A future `aws-orphan-sweep` skill can take the
  same tag query as its primary input.

## 11. Verification checklist

- [ ] Prerequisite: `terraform/base/versions.tf` `default_tags` extended
      with `k8platform-phase = "0"` and `k8platform-component = "base"`.
- [ ] Prerequisite: `terraform/management/versions.tf` `default_tags`
      extended with `k8platform-phase = "1"` and `k8platform-component = "management"`.
- [ ] Prerequisite: `tests/unit/test_terraform_default_tags.sh` exists,
      runs in `tests/unit/run.sh`, passes against the post-prerequisite tree.
- [ ] Prerequisite: `tests/integration/12_terraform_tag_attribution.sh`
      exists, runs in `tests/integration/run.sh`, passes against a live
      phase-0+phase-1 cluster.
- [ ] Skill: `.claude/skills/terraform-ci-watch/SKILL.md` Phase 3.5 added.
- [ ] Skill: `.claude/skills/terraform-ci-watch/reference/tag-assertion.md` authored.
- [ ] Skill: failure-taxonomy entry added.
- [ ] Skill output respects ≤5 KB cap on both pass and fail.
- [ ] Allowlist covers every tag-incompatible resource type the post-PR
      apply produces (verified by running the integration test and
      treating any "false positive" as an allowlist gap).
- [ ] `AGENTS.md §10` updated with the `default_tags` requirement bullet.
- [ ] `ai/testing-guidelines.md` updated with the new skill sub-step
      paragraph.
- [ ] `ai/handoff.md` Pending follow-ups names both PRs (prerequisite
      and skill enhancement) and their order.

## 12. Rollout notes

Two PRs, strictly ordered:

1. **PR-N: `feat(terraform): default_tags k8platform-phase + k8platform-component`.**
   Touches `terraform/base/versions.tf`, `terraform/management/versions.tf`,
   `tests/unit/test_terraform_default_tags.sh`,
   `tests/integration/12_terraform_tag_attribution.sh`,
   `AGENTS.md §10`. Merged and applied via
   `phase=base action=apply-and-verify` then
   `phase=management action=apply-and-verify` to push the new default
   tags onto every existing resource (Terraform handles the `tag` AWS
   API call on next apply — no resource recreation). The integration
   test must pass post-apply before PR-N is considered done; this is the
   single most likely point for an unknown tag-incompatible resource
   type to surface, requiring an allowlist addition before PR-N+1.

2. **PR-N+1: `feat(skill): terraform-ci-watch asserts k8platform tags`.**
   Touches `.claude/skills/terraform-ci-watch/SKILL.md`, the new
   `reference/tag-assertion.md`, `reference/failure-taxonomy.md`,
   `ai/testing-guidelines.md`, `ai/handoff.md`. Merged after PR-N is
   live; the skill check would fire red against any tree that hadn't
   yet applied PR-N, so the ordering is strict.

PR-N+1 may stack per `AGENTS.md §3` (base = PR-N's branch) rather than
waiting for PR-N to merge — review can proceed in parallel.

A teardown-and-rebuild of phase 0+1 on the same account confirms PR-N's
tag application survives a destroy/apply cycle (per `AGENTS.md §6.3`
the full test bundle includes `12_terraform_tag_attribution.sh` so the
clean rerun is the actual quality signal).

## 13. Estimated effort

**S–M.** Prerequisite PR is small (≤4 lines per provider block, two
new tests, AGENTS.md bullet). Skill PR is medium (one new reference
doc with the allowlist requires care; the Phase 3.5 implementation is
~40 lines of bash; the AWS-side allowlist may need iteration as the
integration test surfaces tag-incompatible resource types not on the
initial list). Combined: ~1 short session if the allowlist guesses are
close; ~1.5 sessions if it takes two integration-test iterations to
converge on a clean allowlist.
