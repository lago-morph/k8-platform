# SPEC-S3 — `scripts/irsa_trust_validator.py --all`: fleet-sweep IRSA trust vs SA matcher

## 1. Summary

Add a Python diagnostic script at
`/home/user/k8-platform/scripts/irsa_trust_validator.py` that, given
`--all`, discovers every IRSA role attached to the EKS cluster, fetches
its IAM trust policy, decodes the OIDC provider and expected `sub`
claim, lists every ServiceAccount carrying a matching
`eks.amazonaws.com/role-arn` annotation, and emits one `MATCH` or
`MISMATCH` line per role. The `--all` fleet-sweep mode is the primary
deliverable; per-role mode (`--role <arn-or-name>`) is a secondary
convenience. Brainstorm item A1-018, rated Tier S3 in
`/home/user/k8-platform/ai/brainstorming/specs/larger-list-preferences.md`.
Directly defends against IRSA SA-name drift — the #1 recurring bug
class, documented concretely in Bug 5 (PRs #64–#68). Read-only;
applies from phase 1 onward.

## 2. Retro pain killed

- **Bug 5, PR #66 root cause** (`retrospective/2026-05-25-70.md` Phase 2):
  `terraform/management/irsa.tf:98` trusted
  `system:serviceaccount:crossplane-system:upbound-provider-family-aws`,
  but Crossplane generated the hash-suffixed SA
  `provider-family-aws-24aaab54a3a0`. Every `AssumeRoleWithWebIdentity`
  call was rejected; ASM Secret MR stayed `Ready=False`; claim sat
  `Waiting`. Root cause required delegating a 166 KB diagnose log to a
  subagent before the SA-name discrepancy was named. `--all` would have
  printed `MISMATCH crossplane-system:upbound-provider-family-aws
  (running pod SA: provider-family-aws-24aaab54a3a0)` in under 10
  seconds.

- **PR #67 silent no-op** (same retro, Phase 2): post-PR-#66 apply
  reported `Apply complete! Resources: 0 added`. The SA-name was still
  wrong. A re-run of `--all` between PR #66's merge and PR #67's fix
  would have confirmed the cluster state was unchanged without spawning
  another diagnose workflow.

- **PR #68 stale pod** (same retro, Phase 2): SA existed with the
  correct IRSA annotation, but the running provider pod was still
  mounted on the old hash-suffixed SA. `--all` surfaced the
  cluster-live SA name from the pod's actual
  `spec.serviceAccountName`, not from the Deployment template — making
  the stale-pod sub-class visible before the next diagnose dispatch.

- **Fleet-pattern blindness**: per-role invocation requires the
  operator to already know which roles exist. When a new phase adds
  multiple IRSA roles simultaneously, drift can appear on any of them.
  `brainstorm.json` comment `A4→A1-018`: *"run it across every IRSA
  role in CI and fail the build on any mismatch."* Every phase from 1
  onward adds at least one new IRSA role; without a fleet sweep every
  new role is a latent Bug 5.

## 3. Out of scope

- **Does not fix mismatches.** Diagnosis only. The fix path follows
  `SPEC-B2` (static lint at author time) and the existing
  `crossplane-claim-verify` chain walk (SPEC-A1). This script is the
  runtime complement.

- **Does not cover IRSA roles created outside Terraform** (e.g. roles
  provisioned by Crossplane Compositions at runtime for workload
  clusters). Discovering those requires a tag-based enumeration
  strategy that belongs in a follow-on spec.

- **Does not check IAM policy document correctness** (allowed actions,
  resource scopes). That is `iam:SimulatePrincipalPolicy` territory.

- **Does not replace `SPEC-B2`** (static SA-pin lint). SPEC-B2 fires
  at PR-author time against Terraform source; this script fires against
  the live cluster. Both layers are needed.

- **Does not implement the CI gate** (see §9 for wiring). CI mode
  (`--ci`) is a flag that changes exit code and output format; it is
  part of this script's implementation, not a separate spec.

### Considered and rejected

- **Bash instead of Python**: JSON traversal across multiple trust
  subjects and OIDC conditions crosses the bash-readability threshold.
  Python's `json` module gives exact parsing at comparable line count.
  The brainstorm item's naming (`irsa_trust_validator.py`) also signals
  Python intent.

- **Terraform-based role discovery** (parsing `irsa.tf`): static
  enumeration misses roles present in state but absent from current
  source. Runtime OIDC-provider-based discovery covers every live role.
  Static parsing is SPEC-B2's job.

- **Concurrent subprocesses per role** (`A5→A1-005`): useful for
  large fleets; for 4–8 IRSA roles sequential is fast enough and
  avoids output interleaving. Concurrency can be added behind
  `--parallel` later.

## 4. Files to change / create

| Path | What changes |
|---|---|
| `/home/user/k8-platform/scripts/irsa_trust_validator.py` | **Create.** The main script (see §5). |
| `/home/user/k8-platform/tests/unit/test_irsa_trust_validator.sh` | **Create.** Unit tests using JSON fixtures (see §6). |
| `/home/user/k8-platform/tests/unit/fixtures/irsa_trust_validator/` | **Create.** JSON fixture directory (see §6). |
| `/home/user/k8-platform/tests/unit/run.sh` | **Modify.** Register the new unit test (one `run_suite` line). |
| `/home/user/k8-platform/AGENTS.md` §6.3 | **Modify.** Add `scripts/irsa_trust_validator.py --all` to the "full test bundle" item list alongside the kyverno scripts. |
| `/home/user/k8-platform/ai/testing-guidelines.md` | **Modify.** Add one bullet in the IRSA invariant section pointing at the script. |
| `/home/user/k8-platform/ai/handoff.md` "Scripts inventory" | **Modify.** One-line entry: `scripts/irsa_trust_validator.py` — IRSA fleet-sweep. |

## 5. Implementation notes

### 5.1 Role discovery

In `--all` mode:

1. `aws sts get-caller-identity` — confirm account and region (per
   AGENTS.md §8.1).
2. `aws eks describe-cluster --name <cluster>` — get the OIDC issuer URL.
3. `aws iam list-roles` — filter locally for roles whose trust policy
   contains `sts:AssumeRoleWithWebIdentity` AND the cluster's OIDC
   provider ARN as `Principal.Federated`. This avoids tag-based
   conventions.
4. Cluster name from `aws eks list-clusters`. If multiple clusters
   exist, require `--cluster <name>` and error without it.

In `--role <arn-or-name>` mode: skip discovery, process the named
role only.

### 5.2 Per-role analysis

For each discovered role:

1. Fetch the trust policy:
   ```python
   role = iam.get_role(RoleName=role_name)
   trust = role['Role']['AssumeRolePolicyDocument']
   ```

2. Extract every `StringEquals` condition on `<oidc-fqdn>:sub` from
   the trust's `Statement` list into `expected_subjects` (a role may
   have multiple subjects, e.g. ArgoCD's two SAs).

3. Parse each subject as `system:serviceaccount:<namespace>:<sa>`.
   Unparseable subjects emit `WARN: unparseable sub claim: <raw>` and
   are skipped; do not abort the role.

4. For each `(namespace, sa_name)` pair:
   a. Check whether the SA exists:
      ```
      kubectl get sa <sa_name> -n <namespace> -o json
      ```
   b. Check `eks.amazonaws.com/role-arn` annotation matches the ARN.
   c. Inverse check — list all SAs in namespace whose annotation
      matches this role ARN (catches orphaned annotations):
      `kubectl get sa -n <ns> -o json | jq '[.items[] | select(...) | .metadata.name]'`
   d. If running pods exist in the namespace, check the live
      `spec.serviceAccountName` on pods labelled with
      `pkg.crossplane.io/provider` or `app.kubernetes.io/name`
      matching the role's inferred component name. This is the PR #68
      sub-class: correct SA existed but pod still ran under the old one.

5. Emit one status line per role (see §5.4 for format).

### 5.3 Pre-flight and error handling

- `aws sts get-caller-identity` first; failure exits 1 with
  `PREFLIGHT_FAILED: cannot confirm AWS account`.
- Confirm region is `us-east-1` or `us-west-2` (AGENTS.md §8.1).
  Outside allowlist: print `REGION_NOT_ALLOWED: <region>` and exit 1.
- Each per-role query is fail-soft: `iam:GetRole` error emits
  `ERROR <role>: <message>` and continues. Never abort the fleet sweep
  on a single role failure.
- `kubectl` failures print `KUBECTL_UNAVAIL: <reason>` per query and
  continue; the trust side is still reported even when cluster side
  fails.

### 5.4 Output format

One header block, then one line per role:

```
=== IRSA TRUST VALIDATOR ===
account: <id>   region: <region>   cluster: <name>
OIDC issuer: https://oidc.eks.<region>.amazonaws.com/id/<hash>
roles discovered: <N>

MATCH    <role-name>
  trust-sub:  system:serviceaccount:<ns>:<sa>
  sa-exists:  yes   annotation-ok: yes   pod-sa: <sa>

MISMATCH <role-name>
  trust-sub:  system:serviceaccount:<ns>:<sa-expected>
  sa-exists:  no
  pod-sa:     <sa-actual>   ← pod is running under wrong SA

WARN     <role-name>
  trust-sub:  system:serviceaccount:<ns>:<sa>
  sa-exists:  yes   annotation-ok: yes
  pod-sa:     (no matching pods found — not necessarily an error)

=== SUMMARY: <M> MATCH  <X> MISMATCH  <W> WARN  <E> ERROR ===
```

In `--ci` mode: exit 0 if `MISMATCH == 0`, exit 1 otherwise. `WARN`
and `ERROR` are informational and do not trigger non-zero exit.
Satisfies `A2→A1-004` (CI oracle) and `A3→A1-002` (pre-merge gate).
Output budget: ≤ 2 KB for 4–8 roles; cap subjects-printed at 10 per
role with `(+N more subjects)` if the trust has an unusually large
`Statement` list.

### 5.5 Performance and dependencies

Sequential across N roles: < 5 seconds for N ≤ 10. No retries needed;
a single boto3 retry on throttle is sufficient. Requires: `boto3`
(present wherever `aws` CLI is installed), `kubectl` on PATH with a
valid kubeconfig (pre-flight: `kubectl cluster-info --request-timeout=5s`),
Python 3.8+. No new pip install in CI.

### 5.7 Cross-references

SPEC-A1's chain walk runs a single-role version of this check inline.
Once this script exists, SPEC-A1's implementation should delegate to
`irsa_trust_validator.py --role <arn>` rather than duplicating the
logic. SPEC-B2 is the static complement (fires at Terraform-source
time); this script fires at runtime.

## 6. Tests required

Per AGENTS.md §6.1 and §6.4.

| Layer | File | Assertion |
|---|---|---|
| Unit | `/home/user/k8-platform/tests/unit/test_irsa_trust_validator.sh` | Mock `iam:GetRole` and `kubectl get sa` responses via JSON fixtures. Assert: (a) `MATCH` line emitted when sub matches the SA annotation and pod SA; (b) `MISMATCH` line emitted + exit 1 in `--ci` mode when SA does not exist; (c) `MISMATCH` line emitted when SA exists with correct annotation but pod runs under a different SA (PR #68 sub-class); (d) `WARN` for a role with no running pods; (e) `ERROR` per-role when `iam:GetRole` fails, and remaining roles still processed. |
| Unit (meta) | same file, `--self-test` flag | Fixture `mismatch-pr66/` causes `--ci` exit 1; fixture `match-all/` causes exit 0. Fails red against an unmodified script that does not yet exist. |
| Integration | `/home/user/k8-platform/tests/integration/13_irsa_trust_validator_smoke.sh` | Against a live cluster: `scripts/irsa_trust_validator.py --all` exits 0, output contains `=== SUMMARY:` line, every discovered role appears as `MATCH`. Fails explicitly if any `MISMATCH` line is present (latent Bug 5 recurrence). |
| E2E | not applicable — see §7 | The script is a read-only diagnostic; no chainsaw scenario is needed. Rationale in §7. |

The unit test uses a fixture-injection mechanism: the script honours
`IRSA_VALIDATOR_MOCK_DIR=<path>` when set, reading
`<path>/<role-name>/trust.json` for IAM responses and
`<path>/<role-name>/sa-<ns>-<sa>.json` for kubectl responses. This
keeps the unit layer fully offline. Before authoring tests, spawn an
adversarial-reviewer subagent per AGENTS.md §6.4; brief must include
the five assertion shapes above, PRs #66/#68 bug history, and explicit
non-goals (no rate-limit testing, no IAM action-correctness check).

## 7. Testing suggestions (unit / integration / e2e)

### Unit

Test file: `/home/user/k8-platform/tests/unit/test_irsa_trust_validator.sh`

1. **PR #66 exact replica** — fixture with trust sub
   `crossplane-system:upbound-provider-family-aws`, no SA in cluster.
   Assert output contains `MISMATCH` and `sa-exists: no`.
2. **PR #68 stale-pod sub-class** — fixture with correct SA + correct
   annotation, but pod `spec.serviceAccountName` is
   `provider-family-aws-24aaab54a3a0`. Assert `MISMATCH` and
   `pod-sa: provider-family-aws-24aaab54a3a0`.
3. **Full match** — SA exists, annotation matches ARN, pod SA matches.
   Assert `MATCH`, exit 0 in `--ci` mode.
4. **Role with multiple subjects** (ArgoCD pattern: two SAs per role).
   Assert both subjects appear in the output, each with their own
   `MATCH` / `MISMATCH` status.
5. **`iam:GetRole` error for one role** — fixture where one role
   returns HTTP 404. Assert `ERROR <role>: ...` line and that the
   remaining roles are still processed.

### Integration

Test file: `/home/user/k8-platform/tests/integration/13_irsa_trust_validator_smoke.sh`

1. **All-MATCH on known-good cluster** — run `--all` against the live
   management cluster after a successful phase 1 apply. Assert exit 0,
   `SUMMARY: N MATCH  0 MISMATCH`.
2. **`--role` single-role path** — call with one explicit role ARN.
   Assert output contains exactly one role block.
3. **Pre-flight region guard** — set `AWS_DEFAULT_REGION=eu-west-1`
   and assert exit 1 with `REGION_NOT_ALLOWED`. (Restore region after.)
4. **Missing kubeconfig** — unset `KUBECONFIG` to a nonexistent file.
   Assert `KUBECTL_UNAVAIL` line in output but script still reports
   the trust side (does not crash).

### E2E

Not applicable. The script is read-only with no cluster-state
side-effects; chainsaw scenarios are for XRD/Composition lifecycle
testing. The integration smoke test (case 1 above) covers the only
live end-to-end flow at the right layer. If a future spec adds
automated remediation, that path would warrant a chainsaw scenario.

## 8. Documentation updates

- **`AGENTS.md` §6.3** — add `scripts/irsa_trust_validator.py --all`
  to the "full test bundle" list, positioned after the kyverno lines,
  with the note: "Must report `0 MISMATCH` before phase sign-off."
- **`ai/testing-guidelines.md`** — add one bullet in the IRSA section:
  "Run `scripts/irsa_trust_validator.py --all --ci` after every
  `terraform apply` that touches `terraform/management/irsa.tf` or any
  `DeploymentRuntimeConfig`. A non-zero exit means a new Bug 5."
- **`ai/handoff.md`** "Scripts inventory" — one line:
  `scripts/irsa_trust_validator.py` — IRSA trust vs SA fleet sweep;
  `--all --ci` for gating, `--role <arn>` for targeted triage.
- **`scripts/README.md`** — add row for `irsa_trust_validator.py`
  with the same one-line description.

## 9. Workflow / auto-invocation wiring

- **`tests/unit/run.sh`**: add `run_suite
  tests/unit/test_irsa_trust_validator.sh` adjacent to the other IRSA
  unit tests. Runs on every push via `.github/workflows/unit-tests.yml`
  with no workflow YAML changes.
- **`tests/integration/run.sh`**: add
  `tests/integration/13_irsa_trust_validator_smoke.sh` so the full
  integration bundle (AGENTS.md §6.3) includes the live sweep.
- **Post-apply invocation** (manual runbook): `ai/testing-guidelines.md`
  instructs the implementing agent to run `--all --ci` after any apply
  touching IRSA or DeploymentRuntimeConfig. A live cluster is required,
  so this cannot be a pre-commit hook.
- No new CI workflow file needed. A future spec could promote `--all
  --ci` into a dedicated light workflow; deferred.

## 10. Discoverability

1. **Mechanical enforcement** — `13_irsa_trust_validator_smoke.sh`
   runs as part of `tests/integration/run.sh`; AGENTS.md §6.3 mandates
   that bundle before phase sign-off. A `MISMATCH` exits non-zero,
   blocking sign-off. Unit tests run on every push via `unit-tests.yml`.

2. **Documentation pointer** — AGENTS.md §6.3 (after this spec's edit)
   names the script in the test bundle. An agent reading the mandated
   files per AGENTS.md §1 lands on it automatically.

3. **Adversarial-review trigger** — AGENTS.md §6.4 requires an
   adversarial reviewer before any IRSA-related test is drafted. The
   brief template includes "paste the bug-to-test traceability matrix";
   this spec's row ensures the reviewer flags any plan missing a live
   fleet-sweep assertion.

## 11. Verification checklist

- [ ] `python3 scripts/irsa_trust_validator.py --help` exits 0 and
      prints usage including `--all`, `--role`, `--cluster`, `--ci`.
- [ ] `IRSA_VALIDATOR_MOCK_DIR=tests/unit/fixtures/irsa_trust_validator/mismatch-pr66
      python3 scripts/irsa_trust_validator.py --all --ci` exits 1 and
      stdout contains `MISMATCH` and `sa-exists: no`.
- [ ] `IRSA_VALIDATOR_MOCK_DIR=tests/unit/fixtures/irsa_trust_validator/match-all
      python3 scripts/irsa_trust_validator.py --all --ci` exits 0 and
      stdout contains `SUMMARY:` with `0 MISMATCH`.
- [ ] `bash tests/unit/test_irsa_trust_validator.sh` exits 0 (all
      fixture cases pass).
- [ ] `bash tests/unit/run.sh` exits 0 (new test registered and
      passing).
- [ ] `grep -n "irsa_trust_validator" /home/user/k8-platform/tests/unit/run.sh`
      returns a non-empty match.
- [ ] `grep -n "irsa_trust_validator" /home/user/k8-platform/AGENTS.md`
      returns a non-empty match in §6.3.
- [ ] With a live cluster: `python3 scripts/irsa_trust_validator.py
      --all` completes in under 10 seconds for the current role set
      and prints `=== SUMMARY:` with `0 MISMATCH`.
- [ ] With a live cluster and `AWS_DEFAULT_REGION=eu-west-1`: script
      exits 1 with `REGION_NOT_ALLOWED` and makes no IAM/EKS API calls
      (confirm via `--debug` flag showing no boto3 requests sent).
- [ ] The `ERROR` per-role fail-soft path: inject one bad role ARN via
      `--role arn:aws:iam::000000000000:role/nonexistent` and confirm
      the script exits 1 in `--ci` mode only if `--ci` is passed, and
      the error line is prefixed `ERROR`.

## 12. Rollout notes

- **Backward compat**: purely additive. No Terraform, Kubernetes, or
  IAM state is modified; only `run.sh` registrations are added.
- **Audit before merge**: unit tests must be green on the PR HEAD SHA.
  The integration smoke test requires a live cluster; dispatch manually
  per AGENTS.md §6.7 and confirm `0 MISMATCH`. If the cluster is down,
  mark `SKIP` in the PR description with a note to run at next
  phase-1 apply.
- **Sandbox constraints**: all AWS calls are read-only
  (`iam:GetRole`, `iam:ListRoles`, `eks:DescribeCluster`,
  `sts:GetCallerIdentity`). Region guard (`us-east-1` / `us-west-2`)
  per AGENTS.md §8.1. Fixtures use synthetic placeholder ARNs
  (`arn:aws:iam::123456789012:role/test-role-*`) — no account IDs
  hardcoded anywhere per AGENTS.md §8.1.
- **Branch sequencing**: orthogonal to all in-flight phase branches.
  Touches only `scripts/`, `tests/unit/`, `tests/integration/`,
  `AGENTS.md`, `ai/testing-guidelines.md`, `ai/handoff.md`.

## 13. Estimated effort

**S** (~2 hours total).

- Script authoring (`irsa_trust_validator.py`): ~60 min. Straightforward
  Python — boto3 + subprocess kubectl, one loop per role, JSON parsing,
  formatted output. Pre-flight and fail-soft patterns follow the
  existing bash scripts under `/home/user/k8-platform/scripts/`.
- Fixture trees (5 directories, 2–3 JSON files each): ~25 min.
- Unit test harness (`test_irsa_trust_validator.sh`): ~20 min. Follows
  the pattern of `test_irsa_sa_pinned.sh`.
- `run.sh` and doc updates: ~10 min.
- Adversarial-subagent review (AGENTS.md §6.4): ~5 min to brief.
  Rollout-audit cost is low — the only existing test that could break
  from the `run.sh` registration is a Python import error, caught by
  the unit test before merge.
