# SPEC-B4 — Kyverno audit: IRSA-annotated SA must match its role's trust subjects

## 1. Summary

Add a Kyverno **audit-mode** ClusterPolicy under `policies/audit/` that, for
every ServiceAccount carrying the `eks.amazonaws.com/role-arn` annotation,
asserts the IAM role's trust policy actually lists `system:serviceaccount:<ns>:<sa>`
as a permitted subject — AND that the SA the running provider/workload pod
is actually mounted on matches. Because Kyverno cannot reach the AWS IAM
API directly, a paired CronJob mirrors each IRSA role's trust subjects into
a single `ConfigMap` (`kyverno-irsa-trust-subjects` in `kyverno`), and the
policy reads that ConfigMap via Kyverno's `context.configMap` to do the
comparison. Violations surface as PolicyReport entries — never block apply.

## 2. Retro pain killed (PR #66 / Bug 5)

`ai/handoff.md` ~line 50: *"pin `serviceAccountTemplate.metadata.name: upbound-provider-family-aws`
in the DeploymentRuntimeConfig. Without it Crossplane generates a hash-suffixed
SA name (e.g. `provider-family-aws-24aaab54a3a0`) that doesn't match the IRSA
trust subject in `terraform/management/irsa.tf:98`. AssumeRoleWithWebIdentity
→ 403 → ASM Secret MR never reconciles → XR Ready=False → claim Waiting."*

The trust JSON itself was syntactically fine and `04-irsa-rolearn-format.yaml`
saw a perfectly valid ARN — the bug was a **referential** mismatch between
the trust subject set and the SA actually mounted on the pod. No existing
unit, integration, or Kyverno policy catches that class today. PR #66's fix
plus PR #67's `triggers_replace` fix plus PR #68's Deployment-rebuild fix
together cost ~3 sessions; a PolicyReport that fired the moment the SA name
drifted would have collapsed that to one read.

Related: PR #67 (apply was a no-op so the new SA name never landed) and
PR #68 (`DeploymentRuntimeConfig` edit alone doesn't roll the Deployment)
both manifest, downstream, as the *same observable* — the pod's
`serviceAccountName` doesn't match a trust subject. One audit policy covers
the whole bug family at runtime.

## 3. Out of scope

- **Does NOT mutate.** No `mutate` rules; the policy is `validate` only.
- **Does NOT enforce.** `validationFailureAction: Audit` — never blocks
  admission or apply. Promotion to Enforce is explicitly forbidden in
  §11 Rollout.
- **Does NOT cover non-IRSA SAs.** A SA without `eks.amazonaws.com/role-arn`
  is ignored by `preconditions`. Pod-identity associations (the non-IRSA
  EKS identity path) are out of scope; if/when the cluster adopts them,
  author a sibling policy.
- **Does NOT verify IAM permissions** (the policy attached to the role).
  That is `tests/unit/test_iam_required_actions.sh`'s job.
- **Does NOT chase cross-account roles.** Trust subjects are mirrored only
  for roles in the current account (the CronJob calls `aws iam get-role`
  with the cluster's own creds).
- **Does NOT replace `04-irsa-rolearn-format.yaml`.** That checks ARN shape;
  this checks referential integrity. Both stay.

## 4. Files to create

Under `policies/audit/` (the only path SPEC-B4 is authorized to add to in
the policies tree):

- `policies/audit/09-irsa-sa-trust-subject-exists.yaml` — the ClusterPolicy.
  Numbered 09 to slot after the existing 01–08 (10–99 reserved for future
  audit rules that consume the same trust-subjects ConfigMap).

Under `crossplane/` (the paired sync job lives here because phase 2+
ArgoCD already syncs this tree; a Composition-free YAML bundle is
acceptable per existing pattern in `crossplane/policies/`):

- `crossplane/policies/10-irsa-trust-subjects-sync.yaml` — single file
  bundling:
  1. `Namespace`/`ServiceAccount` (the SA the CronJob uses; SA gets its
     own IRSA annotation, with a read-only `iam:GetRole`/`iam:ListRoles`
     policy attached via terraform/management/irsa.tf in a follow-up PR).
  2. `ClusterRole` + `ClusterRoleBinding` granting list/get on
     ServiceAccounts cluster-wide (the job needs to enumerate annotated
     SAs to know which roles to fetch) and patch on the target ConfigMap.
  3. `ConfigMap` `kyverno-irsa-trust-subjects` in `kyverno` namespace
     (initial empty body — keys are role ARNs, values are JSON arrays of
     `system:serviceaccount:<ns>:<name>` subjects).
  4. `CronJob` `irsa-trust-subjects-sync` (schedule `*/10 * * * *`,
     `concurrencyPolicy: Forbid`, image pinned to a vetted
     `amazon/aws-cli:2.x` SHA, command is a small `bash + jq + kubectl`
     script that loops over annotated SAs, calls
     `aws iam get-role --role-name <derived-from-arn>`, extracts every
     `system:serviceaccount:*` from the `Principal.Federated` /
     `Condition.StringEquals` clauses, and writes the merged map via
     `kubectl patch configmap`).

Under `ai/brainstorming/specs/` (this file only):

- This spec.

**Not touched** (per task constraints): `terraform/`, `argocd/`, `clusters/`,
`platform-services/`, `tests/`, `policies/audit/README.md`, `scripts/`,
`.github/`. The follow-up PR that implements this spec will need to extend
the IAM policy attached to the cluster's IRSA bundle in `terraform/management/irsa.tf`
to allow `iam:GetRole` on `arn:aws:iam::*:role/k8-platform-*`, but that
edit is implementation work, not authorial scope of B4.

## 5. Implementation notes

**Approach choice (a vs b in the task):** **(a) — periodic ConfigMap sync.**
Justification:

- Kyverno cannot call the AWS IAM API directly. Both options require an
  out-of-band fetcher.
- Option (b) (CronJob fetches at evaluation time, Kyverno calls webhook):
  requires an HTTPS webhook server, mTLS, lifecycle ownership, and a
  custom image. Implementation surface is ~5× larger and the failure
  modes (webhook down → policy fails open silently) are worse than a
  stale ConfigMap.
- Option (a): one CronJob, one ConfigMap, Kyverno's built-in
  `context.configMap` reads the data inline. Failure mode is bounded —
  if the sync stops, PolicyReports stop updating; staleness is visible
  via the ConfigMap's `metadata.annotations.last-sync-timestamp`.
- 10-minute sync cadence is well under the human-debug loop on which
  this fires; trust subjects don't change on a sub-minute timescale.

**Kyverno policy structure** (per AGENTS.md §6.1 and existing patterns
in `policies/audit/04-irsa-rolearn-format.yaml`):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: irsa-sa-trust-subject-exists
  annotations:
    policies.kyverno.io/title: IRSA-annotated SA must appear in the role's trust subjects
    policies.kyverno.io/category: IRSA
    policies.kyverno.io/severity: high
    pod-policies.kyverno.io/autogen-controllers: none   # PR #64 — avoid ArgoCD drift
spec:
  admission: true                                       # PR #64 — explicit, avoid Kyverno default-injection
  background: true
  validationFailureAction: Audit
  rules:
    - name: sa-matches-trust-subject
      match:
        any:
          - resources: { kinds: [ServiceAccount] }
      preconditions:
        all:
          - key: "{{ request.object.metadata.annotations.\"eks.amazonaws.com/role-arn\" || '' }}"
            operator: NotEquals
            value: ""
      context:
        - name: subjects
          configMap:
            name: kyverno-irsa-trust-subjects
            namespace: kyverno
      validate:
        message: >-
          ServiceAccount {{ request.object.metadata.namespace }}/{{ request.object.metadata.name }}
          carries IRSA role {{ request.object.metadata.annotations."eks.amazonaws.com/role-arn" }}
          but system:serviceaccount:{{ request.object.metadata.namespace }}:{{ request.object.metadata.name }}
          is NOT listed in that role's trust policy (per most-recent sync at
          {{ subjects.metadata.annotations."last-sync-timestamp" }}).
          AssumeRoleWithWebIdentity will be rejected by STS. See PR #66.
        deny:
          conditions:
            all:
              - key: "system:serviceaccount:{{ request.object.metadata.namespace }}:{{ request.object.metadata.name }}"
                operator: AnyNotIn
                value: "{{ subjects.data.\"{{ request.object.metadata.annotations.\\\"eks.amazonaws.com/role-arn\\\" }}\" | parse_json(@) }}"
```

Notes:

- `spec.admission: true` and `pod-policies.kyverno.io/autogen-controllers: none`
  are mandatory — without both, Kyverno's webhook injects defaults and
  ArgoCD reports eternal `OutOfSync` (PR #64, Bug 3). The
  `tests/unit/test_kyverno_policy_lint.sh` lint already enforces this
  pair on every policy file (lines 161, 168); the new policy file passes
  that lint by construction.
- `context.configMap` looks up by literal name/namespace — no templating
  in the lookup, only in the JMESPath inside `validate`.
- The `parse_json(@)` step on the ConfigMap value matters because
  ConfigMap values are strings — the sync writes the subject list as a
  JSON-array string per role-ARN key.
- If the ConfigMap is missing or the key isn't present, Kyverno
  evaluates the `value` as null; the `AnyNotIn` comparison still yields
  "subject not in []", so a brand-new role surfaces as a violation
  within one sync cycle. Acceptable failure-open posture in audit mode.

**Trust-subject sync CronJob** (sketch — implementation lives in the
follow-up PR, not in this spec):

```bash
# pseudocode for the job's main loop:
kubectl get sa -A -o json \
| jq -r '.items[] | select(.metadata.annotations["eks.amazonaws.com/role-arn"]) | .metadata.annotations["eks.amazonaws.com/role-arn"]' \
| sort -u \
| while read -r role_arn; do
    role_name="${role_arn##*/}"
    trust=$(aws iam get-role --role-name "$role_name" --query 'Role.AssumeRolePolicyDocument' --output json)
    # Extract every system:serviceaccount:* subject from StringEquals/StringLike clauses
    subjects=$(echo "$trust" | jq -c '[.Statement[].Condition // {} | (.StringEquals // {}, .StringLike // {}) | to_entries[] | select(.key | endswith(":sub")) | .value | (if type=="array" then .[] else . end)] | unique')
    jq -n --arg k "$role_arn" --argjson v "$subjects" '{($k):($v|tostring)}'
  done \
| jq -s 'add' >/tmp/data.json
kubectl create configmap kyverno-irsa-trust-subjects -n kyverno \
  --from-file=/tmp/data.json --dry-run=client -o yaml \
| kubectl apply -f -
kubectl annotate configmap -n kyverno kyverno-irsa-trust-subjects \
  last-sync-timestamp="$(date -u +%FT%TZ)" --overwrite
```

This is not committed in B4; it documents the contract the spec assumes.

**Sandbox constraint reminders** (per task — Pluralsight): the CronJob
runs in-cluster; no new EC2 needed; no Bedrock/Marketplace dependency;
region pinning honors `$AWS_REGION` via downward API or env var; image
is from a public registry (`amazon/aws-cli` is on Public ECR — no
Marketplace).

## 6. Tests required

Per AGENTS.md §6.1, two layers — unit lint + chainsaw scenario.

| Layer | File (to be created by impl PR) | Assertion shape |
|---|---|---|
| Unit | `tests/unit/test_kyverno_policy_lint.sh` (extend) | Existing lint already runs over every file in `policies/audit/`. The new `09-irsa-sa-trust-subject-exists.yaml` is picked up automatically and must pass: (a) no empty/invalid JMESPath backtick literals; (b) `spec.admission == true`; (c) `metadata.annotations."pod-policies.kyverno.io/autogen-controllers" == "none"`. No new test file — verification is the lint already firing on every push via `.github/workflows/unit-tests.yml`. |
| Unit | `tests/unit/test_irsa_trust_subjects_sync.sh` (new) | Static checks on `crossplane/policies/10-irsa-trust-subjects-sync.yaml`: (a) CronJob exists with `concurrencyPolicy: Forbid` and `schedule` not more frequent than `*/5`; (b) the script body contains `aws iam get-role`, `system:serviceaccount:`, and writes to ConfigMap `kyverno-irsa-trust-subjects` in `kyverno`; (c) ServiceAccount used by the CronJob carries an `eks.amazonaws.com/role-arn` annotation; (d) image reference is pinned by SHA digest (`@sha256:...`), not a floating tag. |
| Chainsaw | `tests/chainsaw/irsa-sa-trust-existence/01-drift-fires-policyreport/` (new) | Setup: pre-populate `kyverno-irsa-trust-subjects` ConfigMap with a known role-ARN → `["system:serviceaccount:demo:expected-sa"]` mapping. Assert: (a) creating an SA `demo/expected-sa` annotated with that role-ARN produces NO PolicyReport entry for `irsa-sa-trust-subject-exists`. (b) Creating an SA `demo/drifted-sa` with the same annotation produces a PolicyReport with `result: fail` for `irsa-sa-trust-subject-exists` within 30s. (c) Deleting `demo/drifted-sa` removes the entry. Chainsaw `Test` follows the pattern in `tests/chainsaw/platform-secret/`. |
| Chainsaw | same scenario, second `Test` file `02-missing-configmap-fails-open/` | If the ConfigMap is absent entirely, the policy does NOT crash Kyverno and does NOT block SA creation; PolicyReport may still be emitted (acceptable audit-mode behavior). Defends the "fail open in audit mode" contract. |

**§6.4 adversarial review:** before authoring these tests, the
implementation PR dispatches one adversarial subagent with the standard
brief (AGENTS.md §6.4 verbatim job text). The fixtures-vs-real-shape risk
applies here too — the sync job's actual JSON shape must match what the
policy's `parse_json(@)` expects, and the chainsaw setup must use the
exact same shape. Plan: bake a single canonical shape into both the
chainsaw setup ConfigMap AND the sync job's `jq` filter; assert the
shape in the unit test on the CronJob YAML.

## 7. Documentation updates

- `policies/audit/README.md` — add row to the "What's caught today"
  list: *"09-irsa-sa-trust-subject-exists.yaml — for every IRSA-annotated
  SA, asserts the role's trust policy actually lists `<ns>:<name>` as a
  subject. Catches PR #66 / Bug 5 (SA-name drift from Crossplane
  hash-suffix or hand-edit)."*
- `ai/handoff.md` — add one line under "Behavioral rule additions"
  pointing future agents at the new PolicyReport class: *"On any IRSA
  failure (`AccessDenied` / `InvalidIdentityToken`), first run
  `kubectl get policyreport -A | grep irsa-sa-trust-subject-exists` —
  if a fail entry exists, the SA-vs-trust-subject mismatch is named
  there with the role ARN. No need to manually reconcile trust JSON
  against pod SA."*
- `docs/decisions/` — short ADR (`ADR-NNN-kyverno-trust-subjects-sync.md`)
  recording the option (a) vs (b) choice and the staleness-vs-complexity
  trade-off. One page max.
- No edits to `AGENTS.md` (skill discoverability is covered by §9 below).

## 8. Workflow / auto-invocation wiring

- **`argocd/` already syncs `policies/audit/` automatically** via
  `terraform/management/helm.tf:304 terraform_data.kyverno_audit_policies`
  (today) and via the planned phase-4 ArgoCD Application (per
  `policies/audit/README.md` Lifecycle section). The new file lands and
  applies with zero additional wiring.
- **`crossplane/policies/` is already ArgoCD-managed** (the existing
  `09-platform-secret-namespace-allowed.yaml` proves the path works);
  the new `10-irsa-trust-subjects-sync.yaml` lands the same way.
- **`crossplane-claim-verify` skill amendment** (SPEC-A1/A2): in
  Phase 4b (SPEC-A2's classifier), class D (IRSA rejection) gets one
  extra `next_read` line: `kubectl get policyreport -A -o json | jq '.items[] | select(.results[]?.policy=="irsa-sa-trust-subject-exists" and .results[]?.result=="fail")'`.
  If this returns a hit, the gap message becomes: *"SA `<ns>:<sa>` is
  not a trust subject of role `<arn>` — Kyverno audit policy
  irsa-sa-trust-subject-exists already flagged this at <timestamp>."*
  This collapses the PR #66 debug loop to one read.
- No new GitHub Actions workflow. No `terraform-test.yml` dispatch
  required for the policy itself; CronJob lands via ArgoCD on next sync.

## 9. Discoverability for future agents

Four forcing functions:

1. **PolicyReport visibility.** A future agent debugging an IRSA failure
   running `kubectl get policyreport -A` (the standard Kyverno read,
   already documented in `scripts/kyverno-violations.sh`) sees a
   `fail` entry naming the SA and role.
2. **Skill integration.** The `crossplane-claim-verify` skill's
   classifier (SPEC-A2) surfaces a class-D hit with a one-line message
   citing this policy by name. Agents using the skill never have to
   know the policy exists by name; the skill names it.
3. **README row.** `policies/audit/README.md` lists every policy with a
   one-line description — agents scanning the README to find "what
   catches IRSA bugs" see this row alongside `04-irsa-rolearn-format`.
4. **Lint enforcement.** `tests/unit/test_kyverno_policy_lint.sh` runs
   on every push; if a future refactor breaks the policy's
   `spec.admission` / autogen annotation, the unit suite goes red and
   names the file.

## 10. Verification checklist

Concrete observable checks after the implementation PR lands:

- [ ] `bash tests/unit/test_kyverno_policy_lint.sh` exits 0 with the new
  policy file appearing in the per-file output.
- [ ] `bash tests/unit/test_irsa_trust_subjects_sync.sh` exits 0.
- [ ] `bash tests/unit/run.sh` includes both tests in its output and
  exits 0.
- [ ] `kubectl get clusterpolicy irsa-sa-trust-subject-exists -o jsonpath='{.spec.validationFailureAction}'`
  prints `Audit` (NOT `Enforce`).
- [ ] `kubectl get cronjob -n kyverno irsa-trust-subjects-sync` exists
  and shows a non-empty `LAST SCHEDULE` within 15 minutes of install.
- [ ] `kubectl get configmap -n kyverno kyverno-irsa-trust-subjects -o jsonpath='{.metadata.annotations.last-sync-timestamp}'`
  returns a timestamp within the last 15 minutes.
- [ ] **Negative probe:** create a SA `default/probe-bad` with annotation
  `eks.amazonaws.com/role-arn=arn:aws:iam::<account>:role/k8-platform-mgmt-crossplane`
  (whose trust subject is `crossplane-system:upbound-provider-family-aws`,
  NOT `default:probe-bad`). Within one Kyverno background-scan cycle,
  `kubectl get policyreport -A` shows a `fail` entry for
  `irsa-sa-trust-subject-exists` naming `default/probe-bad`. Delete the
  SA; entry clears within one cycle.
- [ ] **Positive probe:** the existing IRSA-correct SAs
  (`argocd/argocd-server`, `crossplane-system:upbound-provider-family-aws`,
  `external-secrets/external-secrets`, `external-dns/external-dns`)
  produce zero `fail` entries.
- [ ] Chainsaw scenario `tests/chainsaw/irsa-sa-trust-existence/01-*` and
  `02-*` pass under `tests/chainsaw/run.sh`.

## 11. Rollout notes

- **`validationFailureAction: Audit` ONLY — never promote to Enforce.**
  Enforcing this policy would block legitimate cluster operations during
  any window where the sync ConfigMap is stale: e.g., immediately after
  a new IRSA role is created by Terraform but before the next 10-minute
  sync cycle, every new SA creation against that role would be rejected.
  Audit posture surfaces the drift without breaking the bring-up loop.
  Codified in this spec; the impl PR's policy file MUST hard-code
  `Audit` and the README MUST document the no-Enforce stance.
- Land on branch `feat/kyverno-irsa-sa-trust` off `main`. Stacked off
  SPEC-A2 only if SPEC-A2's skill amendment in §8 ships in the same PR;
  otherwise independent.
- No Terraform changes in B4 itself, but the impl PR will need to add
  `iam:GetRole` and `iam:ListRoles` to the CronJob's IRSA role (a new
  role under `terraform/management/irsa.tf`). Out of authorial scope here.
- No account-derived values per AGENTS.md §8.1 — the policy is account-
  agnostic; the CronJob discovers role names from the actual SA
  annotations at runtime; the ConfigMap keys are full ARNs that carry
  account ID but the file checked into git is empty at install time.
- Backward compatible — adding an audit-mode policy never breaks any
  existing flow.
- Stale-sync failure mode: if the CronJob stops, the ConfigMap goes
  stale. Surface this with a sibling audit policy in a later spec
  (B-followup) that fires if `last-sync-timestamp` is older than 1 hour.
  Not in B4 scope.

## 12. Estimated effort

**M** — medium.

Justification: the policy YAML itself is small (~50 lines, mirrors
`04-irsa-rolearn-format.yaml`). The CronJob bundle is medium-sized
(~150 lines for Namespace+SA+Role+RoleBinding+ConfigMap+CronJob+script).
The IAM-role addition in `terraform/management/irsa.tf` and an
adversarial-review-driven test set (one unit lint + one chainsaw scenario
with two Test files + fixture corpus) add the rest. Total: roughly a
full day of focused implementation, plus a half-day cluster-side smoke
loop (one round of "policy renders → CronJob fires → ConfigMap
populates → drifted SA gets a PolicyReport") on the live management
cluster. The IRSA-on-the-CronJob bootstrap is the load-bearing
prerequisite — without `iam:GetRole` the entire policy is inert.
