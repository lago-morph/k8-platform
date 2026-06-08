# Burndown Item 4 — "Make the live suite actually gate, fail-closed" — Implementation Plan

Base commit: `c750a72`. Status: READ-ONLY research + plan. Nothing dispatched.

Item 4 text: "Wire tests/live/run.sh into the dispatch apply-and-verify job under the
scoped verifier/reaper role; emit the clean-pass evidence artifact; wire the fail-closed
live-evidence gate + the static wired/gating/scoped lints (auto-013 CARRIED-FORWARD).
Acceptance: a config reconciled without fresh live evidence goes RED automatically."

## 0. Headline

The *logic* for almost every piece already exists and is unit-tested. The gap is **wiring**:
nothing in `.github/workflows/terraform-test.yml` invokes `tests/live/run.sh`, nothing
assumes the verifier role, nothing emits/uploads the evidence artifact, the gate's CI
`fetch_evidence()` is a stub returning `[]`, the live-evidence gate is not invoked by any
workflow, and the "wired/gating/scoped" static lint test does not exist.

## 1. What exists vs missing (per piece)

| Piece | State | Evidence |
|---|---|---|
| (a) `tests/live/run.sh` orchestrator | BUILT + unit-tested | `tests/live/run.sh` (full file); `tests/unit/test_live_orchestrator.sh` registered at `tests/unit/run.sh:96` |
| (a) run.sh INVOKED in CI | ABSENT | `terraform-test.yml` has no `tests/live/run.sh` step; `e2e_management` ends `:384`, then argocd-url `:388`, then destroy `:455`. `grep live/run.sh .github/**` → only `compute-gates.sh:17` comment |
| (b) scoped verifier/reaper IAM role | BUILT (TF) + unit-tested | `terraform/management/verifier_role.tf` + `terraform/management/policies/verifier-reaper-policy.json.tftpl`; `tests/unit/test_verifier_role_no_wildcards.sh` at `run.sh:98`. NOT yet assumed by any CI step |
| (c) clean-pass evidence artifact | PARTIAL (consumer-side schema defined; producer ABSENT) | gate expects records `{run_id,sha,account,cluster,profile,conclusion,created_at}` (`live-evidence-gate.sh:36`); run.sh emits NO artifact; no `upload-artifact` anywhere in `.github` |
| (d) fail-closed live-evidence gate (logic) | BUILT + unit-tested | `.github/scripts/live-evidence-gate.sh`; `tests/unit/test_live_evidence_gate.sh` at `run.sh:97` |
| (d) gate CI evidence fetch | STUB | `fetch_evidence()` returns `echo '[]'` (`live-evidence-gate.sh:78`) — "correctly RED until the adapter lands" |
| (d) gate INVOKED by a workflow | ABSENT | no workflow calls `live-evidence-gate.sh` |
| (e) static "wired/gating/scoped" lints | ABSENT | no `tests/unit/test_*` asserts terraform-test.yml invokes run.sh / no `|| true` / no admin secrets. Only the `LIVE_PROFILE_DEFAULT=full` literal is asserted (`test_live_orchestrator.sh:49`) |
| profile selector | BUILT + unit-tested | `.github/scripts/required-profile-for-changes.sh`; asserted in `test_live_evidence_gate.sh:76-79` |
| `mgmt_live_verify` derived gate | BUILT + unit-tested; NOT consumed | `compute-gates.sh:91,104`; consumed by NO step in terraform-test.yml |
| coverage deriver | BUILT (named `derive-coverage.sh`, not `coverage-deriver.sh`) | `tests/coverage/derive-coverage.sh`; oracle `tests/coverage/expected-coverage.txt`; registry `tests/coverage/registry.yaml` |
| sandbox kube relay helper | BUILT | `scripts/sandbox-kubeconfig.sh` (used by the committed after-check) |

## 2. The dispatch apply-and-verify job — where run.sh goes

File `.github/workflows/terraform-test.yml`:
- gates computed at `:75-84` (`id: gates` → `.github/scripts/compute-gates.sh`).
- `[management] apply` `:296-307`; `[management] e2e-verify` `id: e2e_management` `:315-384`
  (it already does `aws eks update-kubeconfig` `:329` and `kubectl get nodes` `:340`).
- INSERT the live-suite step immediately AFTER `e2e_management` (`:384`) and BEFORE the
  argocd-url step (`:388`).

Kubeconfig: CI is the GH runner with admin creds; it reaches the **public** EKS endpoint via
`aws eks update-kubeconfig` exactly as `e2e_management:329` already does. The committed
after-check `sandbox-kubectl-relay.sh` is the SANDBOX path (SSM relay) and will `skip` in CI
(no `session-manager-plugin`, no kube-relay tag) — that is fine; CI's live checks read the
public endpoint. Do NOT make CI depend on the relay.

Gate the step on `steps.gates.outputs.mgmt_live_verify == 'true'` (the derived `ma OR mv`,
`compute-gates.sh:91`) so it fires on bare `action=apply` too — that is the whole reason
`mgmt_live_verify` exists (`compute-gates.sh:16-24`, FINAL-PLAN §4.1 sre C2).

Scoped identity (FINAL-PLAN §3.4, `verifier_role.tf:1-21`): the step must NOT use the admin
env block. It should `aws sts assume-role` into
`terraform output -raw live_verifier_reaper_role_arn` (`verifier_role.tf:98-101`) with a
session tagged `live-verify=<RUN_ID>` (the trust policy requires `aws:RequestTag/live-verify`,
`verifier_role.tf:39-45`), export the temp creds, then run `tests/live/run.sh`. Pass
`LIVE_CLUSTER=$(terraform output -raw cluster_name)` and the profile.

Evidence emission: on the run.sh **clean-pass exit 0 only**, write
`{run_id:$GITHUB_RUN_ID, sha:$GITHUB_SHA, account, cluster, profile, conclusion:"success",
created_at:<RFC3339>}` to a file and `actions/upload-artifact` it as `live-evidence`. Schema
must match `live-evidence-gate.sh:36`. Never emit on exit 1/2/3 (FINAL-PLAN §4.3, :624-627).

## 3. The fail-closed gate (consumer)

Contract from `tests/unit/test_live_evidence_gate.sh`:
- no evidence ⇒ RED exit 1 (`:42`); fresh green full ⇒ exit 0 (`:46`).
- verify-only evidence CANNOT satisfy a `full` requirement (`:51`) — `profile_ok()`
  (`live-evidence-gate.sh:103-106`).
- keyed on sha × account × cluster (`:59-61`); `conclusion=failure` is not evidence (`:66`).
- staleness = `created_at > --bootstrap-after` (account-rotation guard) (`:71-72`,
  gate `:115`).
- a change to `crossplane/**`|`policies/**` ⇒ required-profile `full` (`:76-79`,
  `required-profile-for-changes.sh:30`).
- usage errors exit 2 (`:83-84`).

Mirror `chainsaw-verify.yml` (the named pattern, FINAL-PLAN :619-620): a push/PR job,
`permissions: actions: read`, that curls the Actions API for runs of `terraform-test.yml` on
HEAD's config-SHA, downloads each run's `live-evidence` artifact, and feeds the joined JSON
array to `live-evidence-gate.sh` via the `fetch_evidence()` seam (replace the `:78` stub).
The gate already turns RED on empty — so the acceptance criterion holds the moment the gate
job runs, even before the producer lands.

## 4. Verifier/reaper IAM role

Already created in `terraform/management/verifier_role.tf` (role
`${cluster_name}-live-verifier-reaper`, output `live_verifier_reaper_role_arn`). "Scoped" =
K=0 no-wildcard in any Action, per `tests/unit/test_verifier_role_no_wildcards.sh:26-40`;
every Delete tag-conditioned or ARN-scoped (`:43-64`); `GetSecretValue` pinned to
`live-verify/*` (`:67-80`); tf documents the NON-GOAL string and the `live-verifier-reaper`
name (`:83-86`). The TF resources exist but are **not yet applied** to the account and **not
yet assumed** by any CI step — both are item-4 wiring.

## 5. Static "wired/gating/scoped" lints (auto-013 CARRIED-FORWARD)

FINAL-PLAN §4.2 (:549-560) + checklist (:1229-1231) specify a NEW push lint
(no such `test_*.sh` exists yet) asserting, against `terraform-test.yml` literally:
1. WIRED: the apply-and-verify path invokes `tests/live/run.sh`.
2. GATING: build success is a function of run.sh's exit code — FORBID `run.sh || true`,
   backgrounding `&`, and an `if:` that silently excludes it (`if: false`, commented-out);
   reserved `exit 3` must fail the build (AGENTS §6.19/§6.24, PR #129 class).
3. SCOPED: the step does NOT reference `secrets.AWS_ACCESS_KEY_ID` (runs under the assumed
   verifier role, not admin).
Implement as `tests/unit/test_live_suite_wired.sh`, lexical assertions over the workflow
file; register in `tests/unit/run.sh` (alongside `:96-99`).

## 6. Additive gating RDS live check (carried from item 2)

`registry.yaml:72-75` marks `rds.aws.m.upbound.io/Instance` cost=`slow` "AFTER-THE-FACT only"
defended_by `pending:P2`. So it belongs in `tests/live/checks/after/` (NOT instantiate — RDS
is multi-minute; instantiate is cheap-hermetic, `instantiate/README.md:3`). Mirror
`sandbox-kubectl-relay.sh`: source `tests/live/lib/live-lib.sh`; precondition `skip` when
tools/creds/`LIVE_CLUSTER` absent; query the live cluster for an `Instance.rds.aws.m.upbound.io`
that is Synced+Ready (or `aws rds describe-db-instances` available:true); on success
`covers rds.aws.m.upbound.io/Instance` + `exit $LIVE_RC_PASS`; if git declares it but it's
absent call `expect_full_fail rds.aws.m.upbound.io/Instance` (exit 3). The deriver already
expects the kind: it is line 13 of `expected-coverage.txt`, emitted by
`derive-coverage.sh` and consumed by run.sh's `derive_expect_full()` (`run.sh:82-83,173-177`).
Update `registry.yaml:75` `defended_by` to the new path once landed.

## 7. Ordered, minimal implementation plan

### (a) Push/PR-safe — validatable by unit tests + static (no live dispatch)
1. NEW `tests/unit/test_live_suite_wired.sh` (wired/gating/scoped lint) + register in
   `tests/unit/run.sh`. Drives item-4's "static lints" deliverable. (Write the workflow step
   in #4a first so this lint has something to assert, or assert-then-implement.)
2. NEW push/PR workflow `.github/workflows/live-evidence-verify.yml` mirroring
   `chainsaw-verify.yml` (permissions actions:read), computing required-profile via
   `required-profile-for-changes.sh` over `git diff --name-only origin/main...HEAD`, and
   calling `live-evidence-gate.sh`. With `fetch_evidence` still stubbed/real-but-empty this is
   already RED on a no-evidence config change → **satisfies the acceptance criterion**.
3. Replace `live-evidence-gate.sh:66-79` `fetch_evidence()` CI branch: curl
   `actions/workflows/terraform-test.yml/runs?head_sha=...`, download each run's
   `live-evidence` artifact, emit the joined JSON array. Keep the `LIVE_EVIDENCE_FIXTURE`
   seam so `test_live_evidence_gate.sh` is unchanged. (Logic still unit-covered; the API
   join itself only proves out live.)
4. NEW `tests/live/checks/after/rds-instance-live.sh` (§6) + update `registry.yaml` defended_by;
   run `derive-coverage.sh --check` stays green (kind already in oracle). Validatable by
   `test_coverage_deriver.sh` + shellcheck-style unit lints.

### (b) Requires a live dispatch to validate
5. `terraform-test.yml`: add the live-suite step after `e2e_management` (`:384`), gated on
   `mgmt_live_verify`, doing assume-role into the verifier role + run.sh + evidence emit +
   `upload-artifact live-evidence`. (Workflow edit ⇒ push via jentic — `workflow`-scope gap.)
6. `terraform apply` (phase=management) so `verifier_role.tf` resources actually exist in the
   account before the assume-role in #5 can succeed.
7. Dispatch `terraform-test.yml action=apply-and-verify` to produce the FIRST real evidence
   artifact, then confirm `live-evidence-verify.yml` flips GREEN on that SHA and RED on a
   subsequent crossplane/** edit with no fresh dispatch (the end-to-end acceptance proof).

## 8. Riskiest unknowns

- **Trust-policy assume-role + session tagging in CI.** `verifier_role.tf:39-45` requires a
  `live-verify` *request tag* at assume time AND trusts only `account:root`; the CI principal
  must be allowed `sts:TagSession` and `sts:AssumeRole`. If the admin CI creds can't tag the
  session, the assume fails closed (good for safety, blocks the step). Validate with a
  throwaway assume-role spike before wiring the full step.
- **Artifact retention / cross-run visibility.** The gate joins the `live-evidence` artifact
  of a *different* (dispatch) run from the *push* gate run. Confirm `actions: read` + artifact
  download across runs works and within retention; otherwise fall back to a committed
  machine-emitted marker (allowed by FINAL-PLAN :623-628 with the same provenance contract).
- **config-SHA semantics for config-only changes.** `live-evidence-gate.sh:27-28` says SHA is
  HEAD *or* the crossplane/**+policies/** subtree SHA. The producer (#5) emits `$GITHUB_SHA`
  (HEAD). For a config-only ArgoCD path the gate must key on the same SHA the producer used —
  decide HEAD-only for v1 to avoid a subtree-hash mismatch that would be falsely RED.
- **Reaper deletes under the scoped role are still real deletes.** Keep run.sh in CI at
  `LIVE_PROFILE=full LIVE_MODE=readonly` for the first dispatch; only enable mutating
  instantiate/negative tiers after the tag-conditioned delete policy is proven on a throwaway.

## Critical files
- /home/user/k8s-platform/.github/workflows/terraform-test.yml (insert live step after :384)
- /home/user/k8s-platform/.github/scripts/live-evidence-gate.sh (replace fetch_evidence :66-79)
- /home/user/k8s-platform/terraform/management/verifier_role.tf (assume-role target :98-101)
- /home/user/k8s-platform/tests/live/run.sh (orchestrator; emit evidence on exit 0)
- /home/user/k8s-platform/tests/unit/run.sh (register new wired-lint + rds tests :95-99)
