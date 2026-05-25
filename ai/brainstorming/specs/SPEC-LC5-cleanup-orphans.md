# SPEC-LC5 — `scripts/cleanup-orphans.sh`

## 1. Summary

Add `scripts/cleanup-orphans.sh`, a read-only script that cross-references
three authoritative sources — the AWS Resource Groups Tagging API, every
`terraform.tfstate` under `terraform/`, and every live Crossplane XR's
`.spec.resourceRefs` — and prints any AWS resource tagged
`managed-by=k8-platform` that is not claimed by either source.  The script
never deletes anything by default; an explicit `--delete` flag is required,
after which the operator confirms each resource individually before any AWS
API write is issued.  It is the runtime safety net for the auto-tagging work
in SPEC-LC4: LC4 ensures every managed resource carries the tag; LC5 ensures
every tagged-but-unclaimed resource surfaces before it accumulates and trips a
sandbox quota cap.  The script is a manual runbook; it is never invoked
automatically.  Tier C item LC5, brainstorm ID A1-070.

## 2. Retro pain killed

- **Orphan NAT gateways blocked new sessions.**
  `retrospective/2026-05-23-36/preflight-aws-account-spec.md:69–70` names
  "orphan NAT gateways consuming EIPs" as an explicit session-start blocker:
  "Verify no leftover resources from a prior session would block this one —
  e.g. orphan NAT gateways consuming EIPs."  No cross-check tool existed; the
  agent had to enumerate EIPs and NAT GWs manually.

- **Phase-2 IRSA cascade left unattributable IAM roles.**
  SPEC-C3 ("Retro pain killed" §2) documents that PRs #66–#68 accumulated
  IAM roles across multiple create-and-abandon cycles.  With no tag-based
  query the next session "had no way to know which IAM roles were 'phase 1
  management' vs 'phase 2 ad-hoc' — everything looked the same to
  `aws iam list-roles`."  Two iterations were lost triaging orphans.

- **Manual "remember to delete X" notes scattered across retros.**
  `ai/brainstorming/brainstorm.json` comment `A6→A1-010`: "`scripts/cleanup-orphans.sh`
  (A1-070) plus auto-tagging (A1-054) lets us drop the manual 'remember to
  delete X' notes scattered across retros."

- **Sandbox quota cap is a hard session-kill.**
  `ai/aws-test-environment-limitations.md` caps EC2 at 9 instances, EIPs at 5,
  NAT GWs at 2.  A resource that drifts out of terraform or Crossplane control
  silently consumes quota; the first symptom is a `RunInstances` or
  `AllocateAddress` hard failure mid-apply.  Brainstorm A1-070 justification:
  "Sandbox kill class: drifted resources past the cap."

## 3. Out of scope

- **Automatic, unattended deletion.**  The Pluralsight sandbox has no recovery
  path once resources are deleted; a wrong delete is a multi-hour session
  restart.  Cleanup is always interactive — this is a deliberate constraint,
  not an oversight.  Scheduled or CI-driven deletion requires a separate spec
  with its own safety review.

- **Resources without the `managed-by=k8-platform` tag.**  Pre-existing
  infrastructure (Route53 zone, Pluralsight bootstrap IAM roles, VPC default
  SG) is out of scope by definition; the tag is the opt-in boundary.

- **Terraform state repair** (reverse orphan: in state, missing from AWS).
  That is a `terraform import` / `state rm` problem; this script does not
  address it.

- **Non-tag-queryable resource types** (certain IAM inline policies, Route53
  record-set sub-resources).  The Tagging API is the primary sweep; per-type
  supplements are added only for the highest-risk types (IAM roles).  Expanding
  to all untaggable types is deferred to a follow-on spec.

- **Multi-account or multi-region sweep.**  The script targets the current
  account and region (`$AWS_REGION`).  Sandbox hard constraint: us-east-1 or
  us-west-2 only (one region per invocation).

### Considered and rejected

- **CI invocation on every push.**  Rejected: mid-apply the Tagging API may
  return live resources not yet in state, producing high false-positive counts;
  and CI automation of `--delete` is categorically excluded.
- **Fold into `scripts/whereami.sh --json`.**  Rejected: whereami is a <2 s
  precondition gate; orphan scan takes 15–30 s with variable-length output.
  Separate scripts, separate concerns.
- **CloudTrail as authoritative source.**  Rejected: 7-day retention (Tier C1)
  misses resources from earlier sessions.  Tagging API is the live source of
  truth.

## 4. Files to change / create

**Create:**

- `/home/user/k8-platform/scripts/cleanup-orphans.sh` — executable,
  `#!/usr/bin/env bash`, `set -euo pipefail`.
- `/home/user/k8-platform/tests/unit/test_cleanup_orphans.sh` — offline
  unit tests, no AWS calls.

**Modify:**

- `/home/user/k8-platform/scripts/README.md` — add `cleanup-orphans.sh`
  entry under a "Safety / audit" section (create if absent).
- `/home/user/k8-platform/AGENTS.md` §8.1 — one bullet referencing the
  script as the session-start orphan-check tool.
- `/home/user/k8-platform/ai/testing-guidelines.md` — one bullet in the
  sandbox quota section referencing the script.
- `/home/user/k8-platform/ai/aws-test-environment-limitations.md` —
  add step 5 to "Pre-flight ritual (always)": run `cleanup-orphans.sh`.

## 5. Implementation notes

### 5.1 CLI signature and execution flow

```
cleanup-orphans.sh [--delete] [--region REGION] [--tag-key KEY] [--tag-value VAL]
```

Default tag filter: `managed-by=k8-platform`.  Overridable to support LC4
extensions such as `k8platform-phase=2`.

Steps in order:

1. **Sandbox safety guard** — abort exit 2 if `$REGION` is not
   `us-east-1` or `us-west-2` (see §5.4).
2. **Preflight** — `aws sts get-caller-identity`; print account ID and
   region to stderr so the operator knows which account is being scanned.
3. **Collect tagged resources** — Tagging API + explicit IAM sweep (§5.2).
4. **Collect known resources** — union of terraform-state ARNs and
   Crossplane MR `atProvider.arn` values (§5.3).
5. **Diff** — subtract known from tagged; print orphan list to stdout,
   one `ORPHAN  <arn>` line each; summary to stderr.
6. **If `--delete`** — show count, print sandbox-kill reminder, then for
   each orphan prompt `Delete? [y/N]:` and call the per-type AWS CLI
   delete command.  One confirmation per resource; never batch.
7. **Exit codes** — 0 = no orphans; 1 = orphans exist (useful for
   read-only CI probe); 2 = preflight / region guard failure.

### 5.2 Tagged-resource collection

```bash
# Regional resources via Tagging API
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=${TAG_KEY},Values=${TAG_VALUE}" \
  --output json \
  | jq -r '.ResourceTagMappingList[].ResourceARN'

# IAM roles (global; Tagging API does not cover IAM in a regional call)
aws iam list-roles \
  | jq -r --arg k "$TAG_KEY" --arg v "$TAG_VALUE" \
    '.Roles[] | select(.Tags[]? | .Key==$k and .Value==$v) | .Arn'
```

KMS key sweep is added if `--include-kms` is passed (off by default;
KMS list-keys requires per-key tag lookups and is slow).

### 5.3 Known-resource collection

**Terraform state** — scan both roots (`terraform/base/`, `terraform/management/`):

```bash
for statefile in terraform/base/terraform.tfstate terraform/management/terraform.tfstate; do
  [[ -f "$statefile" ]] || { echo "WARNING: $statefile not found — skipping" >&2; continue; }
  terraform show -json "$statefile" 2>/dev/null \
    | jq -r '.. | strings | select(startswith("arn:aws:"))' | sort -u
done
```

If `terraform show` is unavailable (remote state backend) fall back to
`terraform state list` + per-resource `terraform state show`.  Missing
state files emit a warning and continue; the partial result is still useful.

**Crossplane XR resourceRefs** — walk every composite resource's MR list and
extract the AWS ARN from `atProvider`:

```bash
for mr in $(kubectl get managed -o name 2>/dev/null); do
  kubectl get "$mr" \
    -o jsonpath='{.status.atProvider.arn}{"\n"}{.status.atProvider.id}' \
    2>/dev/null
done | grep -E '^arn:aws:' | sort -u
```

If `kubectl` is unreachable, print `WARNING: cluster unreachable — XR
resourceRefs not checked` to stderr and continue with the terraform-only
known set.

### 5.4 Sandbox safety check

```bash
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"
if [[ "$REGION" != "us-east-1" && "$REGION" != "us-west-2" ]]; then
  echo "ERROR: region '$REGION' is not a permitted sandbox region." >&2
  echo "       Permitted: us-east-1, us-west-2" >&2
  echo "       See ai/aws-test-environment-limitations.md" >&2
  exit 2
fi
```

This is the first substantive statement in the script, before any AWS API
call.  The same guard fires when `--region` is passed an unpermitted value.
This prevents accidentally scanning a production account via a leaked
credential or misconfigured `AWS_PROFILE`.

### 5.5 Performance and output budget

Total expected runtime: 15–30 s (Tagging API 3–8 s, IAM 1–2 s, terraform
show scales with state size).  Cap the terraform scan at 200 resources; warn
if exceeded.  Orphan list to stdout is one ARN per line; informational output
to stderr keeps stdout pipe-friendly.

### 5.6 SPEC-LC4 dependency guard

Without LC4's tags the Tagging API returns zero results and the script is a
no-op.  If zero tagged resources are found but active XRs exist, warn:

```bash
if [[ ${#tagged[@]} -eq 0 ]] \
   && kubectl get composite --all-namespaces --no-headers 2>/dev/null | grep -q .; then
  echo "WARNING: no resources tagged '${TAG_KEY}=${TAG_VALUE}' found," >&2
  echo "         but active Crossplane XRs exist. Is auto-tagging (SPEC-LC4) deployed?" >&2
fi
```

## 6. Tests required (per AGENTS.md §6.1)

| Layer | File | Assertion |
|---|---|---|
| Unit | `tests/unit/test_cleanup_orphans.sh` | Fixture: 5 tagged ARNs, 3 in state JSON, 2 absent. Dry-run (no AWS). Assert stdout lists exactly the 2 absent ARNs. |
| Unit | same | `AWS_DEFAULT_REGION=eu-west-1 bash cleanup-orphans.sh` exits 2; stderr contains "not a permitted sandbox region". |
| Unit | same | `cleanup-orphans.sh --help` stdout contains `--delete`; the word "dry-run" or "read-only" appears. |
| Unit | same | Stub `kubectl` that always exits 1; dry-run exits 0 or 1 (not 2); stderr contains "cluster unreachable". |
| Integration | `tests/integration/NN_cleanup_orphans.sh` | Create tagged SG outside terraform; assert ARN in orphan list; delete SG; assert ARN gone on next run. |

Before authoring the unit tests, dispatch an adversarial subagent (§6.4) with
the facts above to probe false-positive scenarios — e.g. a resource created by
`terraform apply` that is in AWS but not yet in the local state file.

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Offline, <10 s each.  All cases live in `tests/unit/test_cleanup_orphans.sh`.

1. **ARN-diff correctness** — 5-ARN tagged fixture, 3 in state, 2 absent:
   assert stdout lists exactly the 2 absent ARNs, nothing more.
2. **Region guard fires** — `AWS_DEFAULT_REGION=ap-southeast-1`: exit 2,
   message names permitted regions.
3. **Malformed state file** — truncated JSON fixture: script warns to stderr
   and does not crash; orphan list is based on the Tagging API side only.
4. **LC4 not deployed warning** — empty Tagging API stub, stubbed `kubectl`
   returns one composite: assert LC4 warning fires on stderr.
5. **`--delete` with no orphans** — assert exit 0 and no `Delete?` prompt.

### Integration

Against a live sandbox.  Names follow `tests/integration/NN_cleanup_orphans.sh`.
Each case tears down any resources it creates in a `trap ... EXIT` handler.

1. **Clean sandbox** — all XRs synced, terraform state current: assert exit 0
   and "No orphans found."
2. **Deliberate SG orphan** — create tagged SG via AWS CLI outside terraform;
   assert `ORPHAN` line in stdout; delete SG; re-run; assert gone.
3. **Cluster unreachable** — `KUBECONFIG=/nonexistent`; assert "cluster
   unreachable" warning on stderr and script still scans terraform side.
4. **IAM role orphan** — create tagged IAM role outside terraform; assert it
   appears in orphan list (confirms explicit IAM sweep in §5.2 works, since
   IAM is not returned by the regional Tagging API).

### E2E

Not applicable.  The script is a human-in-the-loop CLI tool with no Crossplane
XRD or claim surface to exercise via chainsaw.  The integration tests above
are the closest functional equivalent.  If a future phase adds an automated
cleanup gate a chainsaw wrapper can be added at that point.

## 8. Documentation updates

- `/home/user/k8-platform/AGENTS.md` §8.1 — add bullet: *"Run
  `scripts/cleanup-orphans.sh` (SPEC-LC5) before the first apply of any
  session to confirm no orphan tagged resources are consuming quota."*
- `/home/user/k8-platform/ai/aws-test-environment-limitations.md` —
  "Pre-flight ritual (always)" step 5: *"Run `bash scripts/cleanup-orphans.sh`
  and confirm the orphan list is empty before applying."*
- `/home/user/k8-platform/ai/testing-guidelines.md` — sandbox constraints
  section: note `cleanup-orphans.sh` as the orphan audit step before any
  capacity-consuming apply.
- `/home/user/k8-platform/scripts/README.md` — "Safety / audit" section,
  one-line entry for `cleanup-orphans.sh`.

## 9. Workflow / auto-invocation wiring

This spec is a **manual runbook tool**.  It is not wired into any CI workflow
or pre-commit hook.  The operator or agent runs it deliberately at session
start and after any partial teardown.  Automatic invocation with `--delete`
is excluded by the §3 decision.

The AGENTS.md §8.1 bullet (§8 above) is the only procedural hook; it relies
on agent compliance with the session-start checklist.  A future spec could add
a lightweight scheduled read-only CI invocation (exit-code check only, no
`--delete`) to surface orphans passively.

## 10. Discoverability

1. **Mechanical enforcement** — no hard CI gate for orphan existence (by
   design).  Soft enforcement: the integration test creates a deliberate
   orphan and fails if the script does not detect it.  The §5.4 region guard
   produces exit 2 if the script is accidentally invoked against a
   non-sandbox account.

2. **Documentation pointer** — `AGENTS.md §8.1` (session-start checklist)
   references the script after the §8 doc update.  An agent reading §8.1 at
   session start lands on the script without searching.

3. **Adversarial-review trigger** — add to `ai/testing-guidelines.md` §6.4
   adversarial checklist: *"For scripts that enumerate live AWS resources,
   confirm: (a) no writes occur without `--delete`, (b) region guard exits 2
   on non-permitted regions, (c) unreachable cluster does not crash the
   script."*

## 11. Verification checklist

- [ ] `bash scripts/cleanup-orphans.sh --help` exits 0; stdout contains
  `--delete` as a documented flag.
- [ ] `AWS_DEFAULT_REGION=eu-west-1 bash scripts/cleanup-orphans.sh`
  exits 2; stderr contains "not a permitted sandbox region".
- [ ] `AWS_DEFAULT_REGION=us-east-1 bash scripts/cleanup-orphans.sh`
  does NOT exit 2 on the region guard (cred failure is acceptable, not 2).
- [ ] `bash tests/unit/test_cleanup_orphans.sh` exits 0 with ≥ 4 `PASS`
  lines (one per unit case).
- [ ] With live sandbox creds: `bash scripts/cleanup-orphans.sh` exits 0
  (clean) or 1 (orphans present); never exits 2.
- [ ] `aws ec2 create-security-group --group-name orphan-test \
  --description test \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=managed-by,Value=k8-platform}]'`
  then `bash scripts/cleanup-orphans.sh`; assert the SG ARN appears in
  stdout.  Delete the SG; rerun; assert the ARN is gone.
- [ ] Run `bash scripts/cleanup-orphans.sh --delete`; answer `N` to every
  prompt; confirm no AWS resources are mutated (re-run shows the same
  orphan list).
- [ ] `grep -c "cleanup-orphans" /home/user/k8-platform/scripts/README.md`
  returns ≥ 1.
- [ ] `grep -c "cleanup-orphans" /home/user/k8-platform/AGENTS.md`
  returns ≥ 1.

## 12. Rollout notes

- **Backward compatibility:** purely additive.  No existing scripts,
  workflows, or HCL files are modified.  Doc edits are one-line additions.
- **Audit-before-merge:** unit tests are fully offline; they pass without AWS
  credentials and can land in CI immediately.  The integration test requires a
  live sandbox and can be skipped in the initial PR if the sandbox is not
  available; it verifies on the next `apply-and-verify` run.
- **Sandbox constraints:** the §5.4 guard enforces us-east-1 / us-west-2.
  Dry-run mode issues only read APIs (Tagging, IAM list, terraform show).  The
  `--delete` path uses only safe-by-default AWS services listed in
  `ai/aws-test-environment-limitations.md`.
- **SPEC-LC4 sequencing:** LC4 should land before LC5 is used in earnest.  If
  LC4 is not yet deployed the §5.6 warning handles the partial-state case; the
  LC5 PR does not need to wait for the LC4 merge.
- **Branch:** `feat/lc5-cleanup-orphans` per AGENTS.md §3.
- **Coordination:** no known in-flight branch touches `scripts/cleanup-orphans.sh`.

## 13. Estimated effort

**M** (1–3 hr).

- Script authoring (~1 hr): three-source diff, region guard, and interactive
  `--delete` flow are each ~20–40 lines; the IAM supplement loop and the `jq`
  ARN-extraction pipeline are the fiddliest parts.
- Unit tests (~30 min): four offline fixture-based cases with JSON stubs.
- Integration test (~30 min): deliberate-orphan create/detect/delete cycle;
  likely one iteration on SG tag-filter syntax.
- Doc edits (~15 min): four small additions.
- §11 smoke (~15 min): checklist run against a live sandbox including the
  deliberate-orphan round-trip.

Total: ~2.5 hours; ceiling 3 hours if the two-root terraform state extraction
requires extra iteration.  Rollout-audit cost is low — the change is additive
and touches no shared infrastructure.
