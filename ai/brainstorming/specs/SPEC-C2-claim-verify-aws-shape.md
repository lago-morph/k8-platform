# SPEC-C2 — crossplane-claim-verify: assert AWS resource shape matches intent

## Summary

Extend the existing `crossplane-claim-verify` skill so that after a claim
reaches `Ready=True`, the skill queries the underlying AWS resource(s)
out-of-band via the `aws` CLI and asserts the live resource's *shape*
(tags, KMS key, replication regions, retention, encryption mode, anything
else the Composition's `forProvider` block set) matches a committed
per-XRD **AWS shape contract**. Pain killed: a claim that goes Ready=True
while the underlying AWS resource is silently wrong-shaped — exactly the
class that took weeks to surface when Crossplane v2.0.1's strict-decoding
behavior silently dropped a string-transform field.

## Retro pain killed

- **Bug 4 — PR #61** (Composition `string` transform missing
  `type: Format` under Crossplane v2.0.1 strict-decoding). The
  Composition was accepted by the API server, the claim went
  `Synced=True / Ready=True`, the XR reported `Ready=True`, and the
  managed-resource (ASM `Secret`) had a `status.atProvider.arn`. Every
  surface signal looked green. The actual AWS Secrets Manager resource,
  however, was created with the *wrong name* (the transform that should
  have produced `k8-platform/<XR-uid>` silently produced the unrendered
  template literal) because v2.0.1's strict YAML decoder rejected the
  transform input and the function-runner fell through to a no-op
  rather than failing the reconcile. **No existing test caught it**:
  unit tests render Helm and lint YAML; Kyverno checks runtime
  patterns; chainsaw asserted claim `Ready=True`; integration asserted
  the ESO-projected `Secret` existed. None of them looked at AWS to
  ask "is this *the* secret you intended?"

  Strict-decoding lesson: **claim status is not a contract that the
  AWS-side resource is correctly shaped.** It only proves Crossplane's
  reconcile loop reached a fixed point. The fixed point can be a wrongly-
  configured resource. The contract must be checked against AWS
  directly, against a written-down expectation, in the same PR that
  ships the XRD.

- Bug-class parallels in the retro corpus (cited for taxonomy
  completeness, not as the primary motivator): chainsaw "Ready=True but
  empty resourceRefs" classes from PR #52/#53, and the
  `crossplane-resources` OutOfSync ghost in PR #64 where ArgoCD
  reported drift on a field Kyverno had defaulted. In each case the
  Crossplane-surface signal disagreed with the underlying truth and a
  separate, narrower probe would have fingerprinted the gap
  immediately.

## Out of scope

- **Performance / availability.** Does not measure latency,
  throughput, IOPS, replication lag, or any time-series shape. A
  resource that exists and has correct tags but is hot/slow is
  out-of-scope.
- **Resources not managed by an XRD.** S3 buckets created by
  Terraform, IAM roles created by the management module, ACM certs
  provisioned by the base module — out of scope. The shape contract is
  per-XRD; only resources whose `apiVersion.group` matches a registered
  XRD's MR list are asserted.
- **Data-plane operations.** Does not write to the resource, does not
  read its contents (e.g., does not fetch the Secret value, does not
  invoke a Lambda, does not query a DynamoDB row), does not enumerate
  contents (e.g., does not list ASM secrets cluster-wide). Read-only
  metadata only.
- **Cross-region resource discovery.** Asserts only in the region(s)
  the claim's `spec.region` (or the Composition's defaulted region)
  names. Does not search other regions for orphans — that is a
  separate concern.
- **Drift remediation.** The skill reports drift; it does not
  reconcile it. Fix flow is the existing Phase 6 taxonomy → terraform
  / GitOps loop.
- **Provider-level CRD schema validation.** Out of scope — covered by
  the existing chainsaw harness and the AGENTS §6.4 adversarial
  reviewer.

## Files to change / create

| Path | What changes |
|---|---|
| `.claude/skills/crossplane-claim-verify/SKILL.md` | Add **Phase 5.5 — AWS shape assertion** between the existing Phase 5 (success report) and Phase 6 (on failure). Phase 5.5 fires only when Phase 2 reached `Ready=True`. Update front-matter `description` to add the phrase "asserts the live AWS resource shape matches a committed per-XRD contract". |
| `.claude/skills/crossplane-claim-verify/reference/aws-shape-assert.md` | **New.** Canonical shape-contract YAML schema + per-AWS-service `describe-*` call recipes + assertion engine semantics (equality, set-equality for tags, presence-only for opaque IDs) + ≤5 KB output budget. |
| `.claude/skills/crossplane-claim-verify/reference/failure-taxonomy.md` | Add one row: *symptom* "Ready=True but AWS shape drift", *category* `aws-shape-drift`, *where to fix* the Composition's `forProvider` block (or the shape contract if the contract is wrong), *Auto?* no — escalate to the XRD author with the diff. |
| `crossplane/xrds/platformsecret/aws-shape-contract.yaml` | **New** (backfill — first instance). Declares the shape contract for `PlatformSecret`'s ASM `Secret` MR: required tags (`app.kubernetes.io/managed-by=crossplane`, `platform.k8-platform.io/xr-uid=<uid>`, `Environment=<from-claim>`), KMS key alias (`alias/aws/secretsmanager` or whatever the Composition pins), replication regions (empty list for phase 2), description format. Sits alongside the XRD at `crossplane/xrds/platformsecret/` — note: this introduces a per-XRD subdirectory pattern; an accompanying file move of the existing single-file XRD into that subdirectory is implied. |
| `crossplane/xrds/platformcluster/aws-shape-contract.yaml` | **New** stub (not authored in this spec; flagged as a phase-2b deliverable). Lists required tags + EKS-cluster-version pin + node-group instance-type whitelist (per sandbox constraints). |
| `ai/testing-guidelines.md` §6 (XRD-authoring checklist) | New checklist item: **"Every new XRD ships with an `aws-shape-contract.yaml` alongside it. PR is not mergeable without one."** Wire into the existing §6 list, not a separate section. |
| `AGENTS.md` §7 | Append one sentence to the `crossplane-claim-verify` bullet: "On `Ready=True` the skill asserts the live AWS resource shape against the per-XRD `aws-shape-contract.yaml`; a drift report is treated identically to a `Ready=False` failure for escalation purposes." |
| `.claude/skills/crossplane-claim-verify/reference/escalation-template.md` | Add a `Shape drift report` placeholder section so escalations include the verbatim per-field diff. |
| `ai/handoff.md` "Skills inventory" / "Pending follow-ups" | One-line note pointing future agents at the shape-contract pattern and the backfill obligation. |

## Implementation notes

The assertion engine runs inside the skill at the moment Phase 5
declares success. It reads the shape contract that ships alongside
the XRD whose claim was just verified, resolves the claim → XR → MR
chain to enumerate the live AWS resource IDs, calls `aws <service>
describe-*` once per resource, and diffs the returned fields against
the contract.

### Credentials path

Uses the session admin AWS credentials already on PATH (per AGENTS
§8.1 quickstart: `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
`AWS_REGION` pre-loaded; the skill confirms with
`aws sts get-caller-identity` per the existing Phase 3 pre-flight).
No new IAM, no new credential rotation, no new MCP tool. All calls
read-only.

### Region guard

Same constraint as SPEC-A1's chain walk: only `us-east-1` and
`us-west-2`. If the claim's resolved region is anything else, Phase
5.5 prints `AWS-SHAPE=skipped: region=<X> outside sandbox allowlist`
and exits clean. Treats out-of-allowlist as a non-failure (the user
explicitly opted into a non-sandboxed region; the assertion engine
declines rather than crashing).

### Shape-contract file format (per-XRD)

```yaml
# crossplane/xrds/<xrd-name>/aws-shape-contract.yaml
apiVersion: platform.k8-platform.io/v1alpha1
kind: AWSShapeContract
metadata:
  name: platformsecret
spec:
  # Each entry maps one MR kind in the Composition to its
  # AWS describe call + field assertions.
  resources:
    - mrKind: Secret.secretsmanager.aws.upbound.io
      awsService: secretsmanager
      describeCmd: describe-secret
      # The MR's status.atProvider.arn / .name names the live resource;
      # the engine substitutes ${atProvider.<field>} at runtime.
      identifier: "--secret-id ${atProvider.arn}"
      assertions:
        - field: Tags
          shape: set-equal
          # Tag values may interpolate XR-derived facts; the engine
          # resolves ${xr.metadata.uid}, ${claim.spec.<field>}, etc.
          expected:
            - { Key: app.kubernetes.io/managed-by, Value: crossplane }
            - { Key: platform.k8-platform.io/xr-uid, Value: "${xr.metadata.uid}" }
            - { Key: Environment, Value: "${claim.spec.environment}" }
        - field: KmsKeyId
          shape: equal
          expected: "alias/aws/secretsmanager"
        - field: ReplicationStatus
          shape: empty-or-absent
        - field: Description
          shape: regex
          expected: "^k8-platform/[a-f0-9-]{36}$"
```

### Discovering which fields to assert

The Composition's `forProvider` block is **ground truth** for the
shape contract. The XRD author's workflow:

1. Open `crossplane/compositions/<xrd>.yaml`.
2. For each MR template, enumerate every `spec.forProvider.*` field
   the composition sets (literal or via patch/transform).
3. For each such field, write an assertion in the shape contract
   naming the corresponding `describe-*` response key.
4. Note: AWS response key names (`Tags`, `KmsKeyId`, `ReplicationStatus`)
   often differ from MR `spec.forProvider` key names (`tags`,
   `kmsKeyID`, `replicaRegions`). The shape contract uses **AWS
   describe-response casing**, not MR-spec casing. Document this in
   `reference/aws-shape-assert.md`.

### SDK / CLI call patterns (per AWS service — table grows with each new XRD)

| AWS service | `describe-*` call | Identifier source | Notable response keys |
|---|---|---|---|
| Secrets Manager | `aws secretsmanager describe-secret --secret-id <arn>` | MR `status.atProvider.arn` | `Tags`, `KmsKeyId`, `ReplicationStatus`, `Description`, `RotationEnabled` |
| EKS | `aws eks describe-cluster --name <name>` | MR `status.atProvider.name` | `tags`, `version`, `resourcesVpcConfig.endpointPrivateAccess`, `logging.clusterLogging` |
| S3 | `aws s3api get-bucket-tagging --bucket <name>` + `get-bucket-encryption` + `get-bucket-versioning` | MR `status.atProvider.id` | per-call; bucket APIs are split |
| IAM Role | `aws iam get-role --role-name <name>` | MR `status.atProvider.id` | `Role.Tags`, `Role.AssumeRolePolicyDocument`, `Role.PermissionsBoundary` |

The skill ships with the SecretsManager entry only (Phase 2 sole
backfill); future XRDs append their row in
`reference/aws-shape-assert.md` as part of their PR. Out-of-table
services: the assertion engine refuses to run and prints
`AWS-SHAPE=skipped: no recipe for awsService=<X>`. The XRD PR that
introduces a new service MUST add the row in the same PR.

### Assertion semantics

- `equal` — strict string equality.
- `set-equal` — order-insensitive set equality for tag lists, security-
  group rule lists, etc. Both extra and missing entries reported.
- `subset` — for tag lists where AWS may inject service-managed tags
  (e.g., `aws:cloudformation:stack-name`). Asserts every expected
  entry is present; ignores extras.
- `regex` — POSIX ERE match against the live value.
- `present` — value is non-empty / non-null.
- `empty-or-absent` — value is `null`, missing, or an empty list.

### Output budget

Phase 5.5 output ≤5 KB. Format:

```
=== AWS SHAPE ASSERTION ===
XRD       <name>  contract=<path-relative-to-repo>
RESOURCE  <mrKind>  id=<identifier>
  Tags             [set-equal]  PASS
  KmsKeyId         [equal]      PASS
  ReplicationStatus [empty-or-absent] PASS
  Description      [regex]      FAIL
    expected: ^k8-platform/[a-f0-9-]{36}$
    actual:   "k8-platform/${xr.metadata.uid}"
SUMMARY   3 PASS, 1 FAIL
=== END SHAPE ASSERTION ===
```

A single FAIL flips the skill's overall exit to non-zero and routes
into Phase 6 escalation with the shape-drift taxonomy row.

### Interpolation engine

`${xr.<dotted-path>}`, `${claim.<dotted-path>}`, `${atProvider.<dotted-path>}`.
Resolved by `jq` against the JSON of the corresponding object the
skill already fetched in Phase 4. Unresolved variables → assertion
failure with `interpolation-failed: ${...}` reason; never silently
substitute empty string.

## Tests required (per AGENTS.md §6.1)

| Layer | File path | Assertion shape |
|---|---|---|
| Unit (engine) | `tests/unit/test_aws_shape_assert_engine.sh` | Drives the assertion engine against three canned `(contract.yaml, describe-output.json)` fixture pairs: (a) all-pass — every assertion shape green; (b) tag-mismatch — `set-equal` reports both missing and extra tags; (c) interpolation-failed — unresolved `${xr.spec.absent}` fails loud, never silent. Asserts output budget ≤5120 bytes, the literal `=== END SHAPE ASSERTION ===` terminator, and that the summary line counts match the per-row outcomes. |
| Unit (contract presence) | `tests/unit/test_xrd_ships_with_shape_contract.sh` | Walks `crossplane/xrds/*/` and asserts every subdirectory contains an `aws-shape-contract.yaml`. Defends the XRD-authoring checklist additionally codified in `ai/testing-guidelines.md` §6. Will fail red if a future XRD lands without one. |
| Unit (skill self-test) | `tests/unit/test_skill_phase_5_5_doc.sh` | Greps `.claude/skills/crossplane-claim-verify/SKILL.md` for the literal header `## Phase 5.5 — AWS shape assertion` and confirms `reference/aws-shape-assert.md` is referenced. |
| Unit (taxonomy completeness) | `tests/unit/test_failure_taxonomy_aws_shape_row.sh` | Greps `reference/failure-taxonomy.md` for an `aws-shape-drift` row citing Bug 4 / PR #61. |
| Chainsaw | `tests/chainsaw/platform-secret/03-aws-shape-assert/chainsaw-test.yaml` | Applies a `PlatformSecret` claim against the real AWS provider in CI, waits for `Ready=True`, runs the shape-assertion engine as a `script:` step, asserts captured output contains `SUMMARY ... 0 FAIL`. A sibling scenario `03b-aws-shape-drift/` deliberately patches the live AWS resource (`aws secretsmanager untag-resource` to strip the `Environment` tag) and asserts the engine reports the drift on a re-run. Both scenarios use `set -eu` per AGENTS §6.6; the drift scenario re-tags before teardown to leave AWS clean. |
| Integration | `tests/integration/13_aws_shape_drift_smoke.sh` | Against the live management cluster: apply a probe `PlatformSecret`, wait for Ready, run the assertion engine, assert 0 FAIL. Then `aws secretsmanager update-secret --description WRONG`, re-run, assert ≥1 FAIL. Then revert and delete. Per sandbox constraints — `us-east-1` only, idempotent, total wall-clock <2 min. |

Per AGENTS §6.4, **before** drafting these tests an adversarial
subagent review is mandatory. Brief includes: contracts (interpolation
correctness, set-equal symmetry, output budget, region-guard,
out-of-table service refusal, the empty-or-absent edge case for
missing JSON keys), the bug history (Bug 4 / PR #61's strict-decoding
silent-acceptance class explicitly; the broader "Ready=True doesn't
mean correct" class), and non-goals (no perf, no data-plane, no
cross-region).

## Documentation updates

- **`.claude/skills/crossplane-claim-verify/SKILL.md`** —
  - Front-matter `description`: add "asserts the live AWS resource
    shape matches a committed per-XRD `aws-shape-contract.yaml`;
    catches the silent-wrong-shape class where the claim reports
    Ready=True but AWS reality drifted."
  - New `## Phase 5.5 — AWS shape assertion` section between current
    Phase 5 and Phase 6. Documents the read-the-contract → resolve-MR
    → describe → diff loop, the region guard, the partial-data rules
    (an MR with empty `status.atProvider` ⇒ skip *that resource*, not
    the whole assertion), and the routing into Phase 6 on any FAIL.
  - Phase 7 escalation: require the shape-drift report be quoted
    verbatim.
- **`reference/aws-shape-assert.md`** (new) — canonical format, AWS
  service recipe table, interpolation grammar, assertion-shape
  catalogue, fail-soft rules, sandbox region guard.
- **`reference/failure-taxonomy.md`** — new `aws-shape-drift` row.
- **`reference/escalation-template.md`** — placeholder section.
- **`AGENTS.md` §7** — single-sentence addition.
- **`ai/testing-guidelines.md` §6** — new XRD-authoring checklist
  item: **every new XRD ships with an `aws-shape-contract.yaml`
  alongside it; PR not mergeable without one.** Cross-references the
  `test_xrd_ships_with_shape_contract.sh` unit test as the
  enforcement mechanism.

## Workflow / auto-invocation wiring

The skill is **already** auto-invoked per **`AGENTS.md` §7**:

> After applying a Crossplane Claim, XRD, or Composition (whether via
> `kubectl`, ArgoCD sync, or CI), invoke the
> **`crossplane-claim-verify`** skill to wait for `Synced`/`Ready` and
> verify the underlying cloud resource is healthy.

Phase 5.5 lives *inside* that existing invocation, after the
`Ready=True` wait succeeds. **No new trigger is required.** The
assertion engine fires automatically on every successful claim
verification, every time the skill runs, on every applicable XRD.
This is the explicit goal: agents cannot forget the AWS-side check
because it's not a separate skill, it's part of the only skill they
already invoke.

The §7 wording covers the three real triggering paths Bug 4 originally
slipped through (`kubectl apply`, ArgoCD sync, CI) — all three now
gain Phase 5.5 coverage with no agent action required.

## Discoverability for future agents

Forcing functions that make a future agent *unable to skip* the
contract:

1. **`AGENTS.md` §7** already names the skill by exact name. After
   this spec's edit, the bullet says the skill asserts AWS shape on
   `Ready=True`. Agents read `AGENTS.md` per §1.
2. **`ai/testing-guidelines.md` §6 XRD-authoring checklist** lists
   the `aws-shape-contract.yaml` requirement alongside the existing
   "ship chainsaw scenarios", "ship integration test", "ship Kyverno
   policy" items. The checklist is the canonical authoring rubric.
3. **`tests/unit/test_xrd_ships_with_shape_contract.sh`** is the
   build-time enforcement: any PR adding an XRD without a contract
   fails unit-tests CI immediately. Agents that "forgot" the
   checklist still hit the wall.
4. **`reference/failure-taxonomy.md`** carries the `aws-shape-drift`
   row — an agent that lands in the taxonomy via another path still
   sees the shape contract referenced in the row's fix recipe.
5. **`docs/adversarial-reviewer.md` §6.4 trigger list** (per
   AGENTS.md §6.4) gains an explicit prompt: *"for any new XRD,
   confirm the `aws-shape-contract.yaml` covers every
   `forProvider` field the Composition sets."* The adversarial
   reviewer dispatched for every new XRD test-drafting moment will
   probe contract completeness.

## Verification checklist

- [ ] Apply the existing `PlatformSecret` claim on the live cluster;
      Phase 5.5 fires after Ready=True and reports `SUMMARY ... 0 FAIL`
      against `crossplane/xrds/platformsecret/aws-shape-contract.yaml`.
- [ ] `aws secretsmanager untag-resource --secret-id <arn> --tag-keys
      Environment` against the live resource, then re-invoke the
      skill; Phase 5.5 reports the Tags assertion as FAIL with the
      missing tag named in the diff.
- [ ] Apply a claim in `eu-west-1` (not sandbox-allowlisted); Phase 5.5
      prints `AWS-SHAPE=skipped: region=eu-west-1 outside sandbox
      allowlist` and the skill exits 0 (not a failure).
- [ ] Author a throwaway XRD with no `aws-shape-contract.yaml`;
      `tests/unit/run.sh` goes red on
      `test_xrd_ships_with_shape_contract.sh`. Delete the throwaway —
      the test goes green again.
- [ ] Phase 5.5 output stays ≤5120 bytes against a contract with
      ≥20 assertions across ≥3 MR kinds (synthetic fixture).
- [ ] On a successful claim with all assertions PASS, the skill's
      overall exit is still 0 and the chainsaw/integration callers
      see no behavior change vs. pre-spec.
- [ ] Interpolation failures (e.g., `${claim.spec.absent}`) fail loud
      with `interpolation-failed: ${claim.spec.absent}` in the output,
      never silently substitute empty string and silently PASS.
- [ ] `aws sts get-caller-identity` is the first command Phase 5.5
      runs (re-uses the existing pre-flight, doesn't re-implement).
- [ ] No AWS write call anywhere in the assertion engine
      (greppable check: only `describe-*`, `get-*`, `list-*`,
      `get-bucket-*`, `get-role`).

## Rollout notes

- **PlatformSecret is the first instance.** This spec backfills
  `crossplane/xrds/platformsecret/aws-shape-contract.yaml` as part of
  its implementation. The backfill is a single contract file + the
  AWS-recipe row for SecretsManager in `reference/aws-shape-assert.md`
  + the per-XRD subdirectory move noted in Files Table.
- **PlatformCluster (phase 2b) is the next instance.** This spec
  flags the stub but does not author it; the phase 2b PR is
  responsible for the EKS shape contract.
- **Subsequent XRDs follow the pattern.** Every new XRD PR after this
  spec lands MUST include its contract file or fail the unit-tests
  CI gate. No grandfather clause — the existing XRD is migrated as
  part of this spec, so the precondition is "every XRD in the repo
  has a contract on the day this spec merges".
- **Backwards-compat for skill consumers:** Phase 5.5 is purely
  additive on the success path. Existing Phase 1-5 happy-path
  callers (chainsaw scenarios that asserted `Ready=True` and exited)
  continue to see `Ready=True` followed by a new short shape-report;
  callers that grep for `Ready=True` keep working.
- **No migration step for the existing live cluster.** Next time the
  skill is invoked on a Ready=True claim, Phase 5.5 runs against the
  newly-shipped contract. If the live resource happens to be wrong-
  shaped (latent Bug 4 residue), the skill reports it on the first
  invocation — which is the point.
- **Sandbox safety:** all AWS calls are read-only `describe-*` /
  `get-*` / `list-*`. None mutate. None cost meaningfully under the
  Pluralsight sandbox limits. Region-guard prevents any
  non-allowlisted-region call.

## Estimated effort

**M.** ~120 lines of new skill content (`aws-shape-assert.md`) + ~60
lines of bash assertion engine + ~40 lines for the PlatformSecret
shape contract + ~3 hours authoring the two chainsaw scenarios
(03-aws-shape-assert + 03b-aws-shape-drift, the latter requires
careful resource cleanup) + ~2 hours unit-test authoring with
synthetic `describe-secret` JSON fixtures + ~30 min on
`ai/testing-guidelines.md` and `AGENTS.md` edits. The chainsaw
drift scenario dominates the effort because it must mutate live
AWS and revert cleanly even on test failure (trap-driven teardown).
No Terraform or provider changes required.
