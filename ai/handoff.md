# Session Handoff — k8-platform

This file is the first thing a new session reads. It captures what was
done last, the current state of the cluster, and the next concrete steps.

The **Environment State** block immediately below tracks what's currently
live in AWS and which phase is being worked on. The agent reads it first
and writes back to it after every workflow run. See
`ai/testing-guidelines.md` for the procedure that drives those updates.

---

## NEW SESSION QUICKSTART (read this first)

You are picking up a 2026-05-23/24 session that:

- Verified phases 0 + 1 on AWS account `309191981509` (now being torn down)
- Stacked phase 2a (PlatformSecret XRD) and phase 2b (PlatformCluster XRD) into main
- Got `phase=management apply-and-verify` green ([run 26346784628](https://github.com/lago-morph/k8-platform/actions/runs/26346784628))
- Authored an `integration-tests.yml` workflow that proved phase 2 was **NOT** actually working — silent PASS hiding 4 real failures
- Root-caused four bugs (two script, one Composition, one Kyverno-vs-ArgoCD drift)
- Shipped fixes for the script bugs (PRs #59, #60) and the Composition bug (PR #61)
- Did NOT ship the Kyverno-drift fix or re-verify on a live cluster

**Then the AWS account was changed.** Everything from `309191981509` is being torn down. You are starting on a new account.

### Before you even start

If you are reading a `main`-checkout version of this file, **verify PR #62 (the rewrite of this NEW SESSION QUICKSTART) is already merged**. If not, the doc on main is stale — work from branch `chore/handoff-resume-here` or ask the user to merge #62 first.

### What "continue" means right now

Run these steps in order. Where I say "dispatch X", I mean via the `mcp__560280ab...__execute` jentic bridge calling `op_2acb005c9f3704ad` (workflow_dispatch); poll via `op_e5f9dfd148ed5018` (list_workflow_runs); fetch job logs via `op_2064ead94c9950bc` (list_jobs_for_workflow_run) + `op_c08d23e5bd6966cb` (download_job_logs). Pattern is documented in `.claude/skills/ext-github/SKILL.md`.

**Critical behavioral rule (added this session):** verify every action by examining unambiguous evidence — read the actual log lines, query the actual status block, call the actual API. Do NOT trust wrapper exit codes alone. See `## Behavioral rules from 2026-05-24 session` below for the full table.

**Step 0 — verify the new account + secrets + creds + merge PR #61.** Dispatch nothing yet. Confirm with the user:

1. **The new AWS account ID.**
2. **The three GitHub Actions repo secrets are rotated to the new account's keys**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`. Every workflow dispatched below reads them; if they still hold the torn-down account's keys, every dispatch fails at `aws sts get-caller-identity`. If they're not yet rotated, **STOP** — ask the user to rotate them in repo Settings → Secrets and variables → Actions, and re-confirm before continuing. Do not dispatch Step 1 otherwise.
3. **A public Route53 hosted zone exists in the new account, named `<new-account-id>.realhandsonlabs.net.`** (trailing dot). We don't auto-provision the zone. The sandbox can't run `aws-creds-check.sh` directly (no AWS creds outside CI) — ask the user to run `bash scripts/aws-creds-check.sh` locally and paste the `hosted zone discovery` section. **Read the output, don't trust the exit code** — the script only WARNs on mismatch and still returns 0. Pass criterion: exactly one zone whose Name matches the new-account pattern.
4. **Merge PR #61 (Bug 4 fix) before Step 1.** Without it, phase 2's PlatformSecret Composition is rejected at function-input validation and every claim stays `Ready=False` — Steps 1–3 (~25 min of CI) would be wasted before Step 4 surfaces the problem. Confirm `merged: true` at the right SHA via `mcp__github__pull_request_read` (read-only — it cannot trigger the merge). If still open: either ask the user to click merge, or in throughput mode call `mcp__github__merge_pull_request` after CI is green. Do NOT proceed to Step 1 with #61 unmerged.

A new account should be treated as a hard stop condition (re-confirm scope with the user before continuing) even if AGENTS §6.6 throughput mode was previously granted. AGENTS §6.6 does NOT currently enumerate account-change as a stop condition; recommend adding it (separate small PR).

**Step 1 — bring up phase 0 (~5 min).** Dispatch `terraform-test.yml` on `main` with `phase=base action=apply-and-verify`. Poll `list_workflow_runs` until `status=completed`. Then read the job's log; look for the exact line `Apply complete! Resources: 25 added, 0 changed, 0 destroyed.` and `aws_acm_certificate_validation.cert: Creation complete`. Then read the `Verify base outputs` step for the issued ACM ARN. Do NOT just trust `conclusion=success`.

**Step 2 — bring up phase 1 (~15 min).** Dispatch `terraform-test.yml` `phase=management action=apply-and-verify`. Read the log: `Apply complete! Resources: 51 added`, five `helm_release.<argocd|external-dns|crossplane|external-secrets|kyverno>: Creation complete after` lines, plus the `terraform_data.argocd_bootstrap` local-exec output line `application.argoproj.io/bootstrap created`. Then read the workflow's `Verify ArgoCD URL` step — its last line should be `argocd reachable at https://argocd.management.<new-account>.realhandsonlabs.net (HTTP 200|307)`.

**Step 3 — wait at least 3 minutes for ArgoCD to sync phase 2.** Phase 2's XRDs, Compositions, ClusterPolicy 09, and ClusterSecretStore are GitOps-only now. The bootstrap App syncs `argocd/apps/` → which materializes `management-cluster-config` (wave -10) + `crossplane-resources` (wave 0) → which sync `clusters/management/eso/` + `crossplane/{xrds,compositions,policies}/`. ArgoCD's default refresh interval is 3 min and the wave cascade is serial; jumping to step 4 too early shows `OutOfSync` from race rather than from Bug 3. When in doubt dispatch `phase-2-diagnose.yml` and re-read.

**Step 4 — diagnose first, then verify.** Dispatch `.github/workflows/phase-2-diagnose.yml` (read-only, no inputs; ships on main since PR #60). Read the output. Specifically:
- Are all ArgoCD apps `Synced+Healthy`? **Bug 3 below means `crossplane-resources` will be `OutOfSync`** because Kyverno mutates ClusterPolicy 09 after apply. Fix Bug 3 (Step 5) before proceeding past this point.
- Does the diagnostic's probe `PlatformSecret` claim reach `Ready=True`? If not, read the XR's `status.conditions[].message`. With PR #61 merged (per Step 0) the bug 4 message should NOT appear — if it does, #61 didn't actually land; re-verify via `pull_request_read`.

**If `phase-2-diagnose.yml` itself fails** (workflow errors before producing output), read its failed step's log. Common modes: `aws eks update-kubeconfig` failure (= phase 1 wasn't actually green, re-do Step 2 evidence with attention); missing `yq`/`kubectl` install (workflow regression); IAM perms missing on the rotated creds (re-check Step 0 #2).

**Step 5 — fix Bug 3 (Kyverno-vs-ArgoCD drift).** Not yet fixed. Diagnostic output proves `ClusterPolicy/platform-secret-namespace-allowed` drifts OutOfSync after each ArgoCD sync. Kyverno's admission/background controller injects defaults that ArgoCD didn't apply. The complete list of fields to defend against (verify against your fresh `phase-2-diagnose` run before authoring):

- `spec.background: true` (auto-defaulted when absent — set explicitly in source)
- `spec.admission: true` (auto-defaulted when absent — set explicitly in source)
- annotation `pod-policies.kyverno.io/autogen-controllers: none` (autogen adds rules for Pod controllers unless suppressed)
- `spec.validationFailureAction` (set explicitly — already is, per existing source)

Two fix paths:
1. **Preferred (GitOps-clean):** add every field above explicitly in `crossplane/policies/09-platform-secret-namespace-allowed.yaml` so Kyverno has nothing to add. Note: the file already sets `spec.background: true` — confirm against your diagnose-run that it's specifically `spec.admission` and the annotation that drift. If the diagnose's "describe Application" output names different fields, defend those instead.
2. **Fallback:** add `ignoreDifferences` on `argocd/apps/crossplane-resources.yaml` for `kyverno.io/ClusterPolicy` on the drifting JSON paths. Hides legitimate diffs in future — only use if option 1 doesn't take.

TDD before fixing: write `tests/unit/test_kyverno_policy_no_drift.sh` that scans `crossplane/policies/*.yaml`; assert each of the four known drift fields is explicitly set on every ClusterPolicy. **Note**: this lint defends against re-introducing the four known drift fields — it does NOT detect new drift fields Kyverno might inject in future. The re-dispatch of `phase-2-diagnose.yml` and verifying `.status.sync.status` on `crossplane-resources` reads `Synced` is the only real loop-closer; the lint is the regression net.

**Step 6 — run integration tests for real.** Dispatch `integration-tests.yml` with **just `test_filter=11`** (the workflow on main has only the `test_filter` input; the `mode` input is added by PR #58, still draft). Read the log: every `wait_for` line ends with `✓ … (after Ns)` NOT `✗ … gave up after Ns`; explicit `PASS:` lines correspond to actual passes (PR #59 made the script fail loud — it can be trusted now, but still read it).

**Step 7 — full integration bundle.** Dispatch `integration-tests.yml` with `test_filter` empty (no `mode` field on main). Phase 0/1/2 components should all pass green or `SKIP:` cleanly.

**Step 8 — merge PR #58 (lifecycle tooling).** That PR adds the `mode` input + `test` / `teardown-phase-2` / `verify-absent` / `rebuild` modes to `integration-tests.yml` (the `test` mode is the default and preserves current single-input behaviour) AND ships `ai/PHASE-2-LIFECYCLE-PLAN.md` (currently only on its branch). Hold until step 7 is green. After merge, the next steps require those modes.

**Step 9 — exercise the full lifecycle.** Per `ai/PHASE-2-LIFECYCLE-PLAN.md` sections B → C → D → E (only available after #58 merges). The lifecycle dispatches `integration-tests.yml mode=teardown-phase-2`, then `mode=verify-absent`, then `mode=rebuild`, then `mode=test` again. This is the user's actual phase-2 completion criterion: GitOps tear-down + rebuild cycle closes.

**Step 10 — unit-test coverage audit (mandatory before phase 3).** See item 8 in `## Pending follow-ups` (the "Audit procedure (when started)" subsection). Walk past PR failures, classify, author lints. Phase 3's live EKS-via-Crossplane work is ~15 min per iteration; silent failures are expensive.

**Step 11 — phase 3.** Per `ai/DESIGN.md` §3.2 Iteration 3 + REQ-PLAT-01..06. Scaffolding is in `clusters/platform/` (PR #55, merged). Two prerequisites before syncing the `platform-cluster-claim` ArgoCD app:
1. **Substitute the TODO subnet placeholders** in `clusters/platform/platform-cluster-claim.yaml` (currently `subnet-REPLACE-ME-AZ1/2`). The `private_subnet_ids` output already exists in `terraform/base/outputs.tf` — it's a **list**, so use `terraform output -json private_subnet_ids | jq -r '.[0]'` and `'.[1]'` for the two AZs (NOT `-raw`, which doesn't work on list outputs). The sandbox has no `terraform` or AWS state access — run this inside a one-off `workflow_dispatch` job (author a `phase-3-subnet-discover.yml` calling `terraform init && terraform output` against the base module state) OR ask the user to paste the two IDs.
2. **Verify** the AppProject `k8-platform` allows `platform.k8-platform.io/PlatformCluster` claims by reading the spec: `grep -A4 namespaceResourceWhitelist argocd/projects/*.yaml` — must include `platform.k8-platform.io`. (Don't trust PR-history alone — see Behavioral rules: evidence not exit codes.)

Then sync. Preferred order (cheapest path first):
- **If `ext-argocd` is installed**, call `POST /api/v1/applications/platform-cluster-claim/sync`.
- **Else if you want a workflow trigger**, author `clusters/platform/sync-claim.yml` (one-shot `kubectl patch application platform-cluster-claim -n argocd --type merge -p '{"operation":{"sync":{}}}'`). NB: this workflow does NOT exist yet — needs authoring.
- **Else** ask the user to click sync in the ArgoCD UI.

Wait ~15 min for EKS provisioning, then layer on ingress-nginx + ExternalDNS + cert-manager + Let's Encrypt + hello.platform.<domain>.

### Open PRs at session end

| PR | What | State |
|---|---|---|
| #58 | Phase-2 lifecycle tooling (mode input + teardown/verify-absent/rebuild) + `ai/PHASE-2-LIFECYCLE-PLAN.md` | **draft** — hold until phase 2 verified end-to-end after fresh-account bring-up (Step 8) |
| #61 | Bug 4 fix: `type: Format` on every string transform | **ready for review** — MUST be in main before phase 2 will work; merge before Step 1 if possible, definitely before Step 4 |
| #62 | This handoff rewrite (what you're reading) | **ready for review** — purely docs, can merge anytime |

Anything else open is from another session.

### Known caveats (NOT bugs, but will trip you)

- **Chainsaw ESO webhook cert (kind-only).** The `tests/chainsaw/` kind-based harness's ESO install (`tests/chainsaw/run.sh`) sometimes fails to mint its webhook cert, producing `invalid certs. retrying...` / `stat /tmp/certs/tls.crt: no such file`. This breaks chainsaw scenarios that create ClusterSecretStore. It does NOT affect the live management cluster (where ESO is installed by `terraform/management/helm.tf` and IRSA-bound). If chainsaw on a PR turns red with this signature, it's not a regression — note and proceed. Separate cleanup item; not blocking phase 2 or 3.
- **`tests/unit/test_helm_render.sh` (pre-existing tolerated red).** 4 ArgoCD Ingress assertions fail. Tolerated via `continue-on-error: true` in `.github/workflows/unit-tests.yml`. Fix would be to switch yq selectors from `metadata.name=="argocd-server"` to label `app.kubernetes.io/component=server`. Listed in pending-followups; not blocking.

### Session retrospective queued

Many session-level findings (PR-state-as-signal, verify-then-PR pattern, evidence-not-exit-code, the unit-test coverage audit precedent) deserve to land in `retrospective/2026-05-24-*/` and as AGENTS.md edits. Trigger the `self-retrospective` skill when convenient — the chat trace from this session is the source material.

### APIs you want — request via the external-api-bridge skill

You currently rely on jentic + `ext-github` for everything cross-sandbox. The verification rule is much harder to enforce without direct kubectl/AWS/ArgoCD reads — every check today requires authoring a one-off workflow and reading its log. Ask the user to install these via the `external-api-bridge` meta-skill (read `.claude/skills/external-api-bridge/SKILL.md`):

| Service | What you'd actually use it for | Sample endpoints |
|---|---|---|
| **ext-aws** | Verify EKS cluster status, IAM role existence, ASM secret presence, Route53 record state, without dispatching a workflow | `eks DescribeCluster`, `iam GetRole`, `secretsmanager DescribeSecret`, `route53 ListResourceRecordSets`, `sts GetCallerIdentity` |
| **ext-argocd** | Confirm Application sync/health state directly; force-sync from session; read live cluster diff | `GET /api/v1/applications/{name}`, `POST /api/v1/applications/{name}/sync`, `GET /api/v1/applications/{name}/managed-resources` |
| **ext-kubernetes** (lower priority — auth is complex) | Direct read of any cluster resource without proxying through workflow logs | `GET /api/v1/namespaces/{ns}/pods`, `GET /apis/apps/v1/namespaces/{ns}/deployments` — needs cluster CA + token, EKS would need IAM auth bridge |
| **ext-github extension** | Re-run failed workflow runs, get full workflow run logs in one call (current bridge has 500 on `/logs` endpoint and uses per-job substitute) | `POST /repos/{owner}/{repo}/actions/runs/{run_id}/rerun-failed-jobs`, `GET .../runs/{run_id}/logs` if jentic adds 302-follow |

When proposing these to the user, name the exact endpoints (table above), then run `external-api-bridge` per its SKILL.md procedure. Trigger phrases that load the meta-skill include `create ext-aws`, `add an endpoint to ext-github`, `jentic`, or `egress blocked`. Each new `ext-{service}` ships as a self-contained child skill with per-endpoint recordings.

### Behavioral rules from 2026-05-24 session

Bugs found this session were almost all caused by trusting wrapper exit codes instead of evidence. Going forward:

| Action | Evidence to check (not just `success`) |
|---|---|
| `workflow_dispatch` | poll `list_workflow_runs` until `status=completed`; download the **relevant step's log**; quote a verbatim PASS-evidence line |
| `git push` | grep the push output for the branch line OR re-resolve `HEAD` and confirm |
| PR merge | `pull_request_read` returns `merged: true` for the exact SHA you intended |
| `kubectl apply` (via workflow) | follow up by reading `.status` of the applied object via a diagnostic workflow or `ext-argocd` (preferred near-term; `ext-kubernetes` is lower priority due to EKS IAM-auth complexity) |
| ArgoCD sync | call ArgoCD API (`ext-argocd`) or `kubectl get application … -o jsonpath='{.status.sync.status}/{.status.health.status}'` and confirm `Synced/Healthy` |
| AWS resource expected to exist | call AWS API (`ext-aws`) or `aws … describe-… --query`; quote the result |
| Bash script run in CI | read the log for the script's own PASS/FAIL lines, not the workflow's "step succeeded" badge — scripts can pass-on-fail if not strict (PRs #59 was the example) |

Also:
- **PR state = signal.** Open a PR as **draft** while you're still iterating. Mark **ready for review** ONLY when CI is green AND you want it merged. Don't open PRs before push-triggered checks complete — leave the commit on the branch, wait for green, then open.
- **Verify-then-PR.** Per AGENTS §6.7 for chainsaw, but generalize: any manual check (chainsaw, integration-tests, phase-2-diagnose) should be dispatched against the branch SHA and read green BEFORE opening the PR.
- **The unit-test gap.** Many failures this session would have been caught by a one-liner lint. The pending-followups item 8 captures the audit task; don't skip it before phase 3.

### Pointers (not the whole quickstart)

- `ai/PHASE-2-LIFECYCLE-PLAN.md` — the A → E checklist this session built
- `.claude/skills/ext-github/SKILL.md` — the existing ext bridge example to copy
- `.claude/skills/external-api-bridge/SKILL.md` — the meta-skill for adding new ext-* services
- `AGENTS.md` §3 / §5.1 / §6.2 / §6.3 / §6.4 / §6.5 / §6.6 / §6.7 — house rules
- `ai/DESIGN.md` §3.2 — phase 3 design

---

## Environment State

| Field | Value |
|---|---|
| Active phase | **none — AWS account `309191981509` torn down 2026-05-24, new account TBD.** Need fresh phase 0/1/2 bring-up per QUICKSTART above. |
| Last update | 2026-05-24 — end of session that ran phase-2 verify-then-tear-down → bug-hunt → fix-but-not-re-verify (account changed mid-session) |
| AWS account | **TBD — ask user.** Was `309191981509`. |
| Route53 zone | **TBD — derived from new account.** Was `309191981509.realhandsonlabs.net.` |
| EKS cluster | Will be `k8-platform-mgmt` in `us-east-1` again (cluster name is fixed by `terraform/management/variables.tf`) |
| Cluster URL | Will be `https://argocd.management.<new-account-id>.realhandsonlabs.net` after phase 1 apply-and-verify |
| State backend | Will be s3 `k8-platform-tfstate-<new-account-id>`, lock table `k8-platform-tfstate-lock` (auto-bootstrapped by terraform-test.yml) |

### Phase states

| Phase | State | Last action | Run URL |
|---|---|---|---|
| 0 base | **needs fresh apply** (account changed) — code is good | 2026-05-23 verified on prior account | [run 26340162917](https://github.com/lago-morph/k8-platform/actions/runs/26340162917) |
| 1 management | **needs fresh apply** (account changed) — code is good | 2026-05-23 verified on prior account | [run 26340615326](https://github.com/lago-morph/k8-platform/actions/runs/26340615326) |
| 2 xrds | **PR #61 must merge first** (Bug 4 root-cause); also Bug 3 (Kyverno-vs-ArgoCD drift) unfixed. Code partially correct, NOT yet end-to-end verified on a live cluster. | 2026-05-24 silent-PASS uncovered, fix authored | [diagnose run 26348711132 — prior account, historical only](https://github.com/lago-morph/k8-platform/actions/runs/26348711132), [PR #61](https://github.com/lago-morph/k8-platform/pull/61) |
| 3 platform | scaffolding only (PR #55 merged: `clusters/platform/platform-cluster-claim.yaml` + ArgoCD app, manual sync) | — | — |
| 4 observability | not-coded | — | — |
| 5 auth | not-coded (spec done 2026-05-10) | — | — |
| 6 workload | not-coded | — | — |

### Live AWS resources from torn-down account `309191981509` (FOR REFERENCE / SHAPE ONLY — none of these IDs exist anymore; the new account will have analogous resources with different IDs after Step 1/2 brings them up)

```
EKS cluster:        k8-platform-mgmt
Cluster endpoint:   https://F96592A65D3316DE1EA73CD4C1BC8AF0.gr7.us-east-1.eks.amazonaws.com
OIDC provider ARN:  arn:aws:iam::309191981509:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/F96592A65D3316DE1EA73CD4C1BC8AF0

IRSA roles:
  arn:aws:iam::309191981509:role/k8-platform-mgmt-argocd
  arn:aws:iam::309191981509:role/k8-platform-mgmt-crossplane
  arn:aws:iam::309191981509:role/k8-platform-mgmt-eso
  arn:aws:iam::309191981509:role/k8-platform-mgmt-external-dns

ACM cert (issued):  arn:aws:acm:us-east-1:309191981509:certificate/592bdcfa-dbfe-4afe-ba28-aa509c908095
Cognito user pool:  us-east-1_LOymmhYEF
Cognito client:     7imdshi763a01upp5fi88k9b4d (Keycloak SSO client)
Cognito test user:  ci-test@309191981509.realhandsonlabs.net
```

State values: `not-coded`, `code-only`, `plan-green`, `applied`, `verified`,
`broken`.

The agent updates this block after each `workflow_dispatch` completes.
If the state is stale or contradicts a recent CI run, refresh it first.

---

## PR landscape from the 2026-05-23 session

The previous session ended with **all 8 PRs from the session merged or expected to merge as a single batch**. Cross-reference against `git log main --oneline` to confirm what actually landed:

| PR | Title | Base | Merged? | What it ships |
|----|-------|------|---------|---------------|
| #39 | fix: post-comment KeyError + kyverno JMESPath; bring up phases 0 and 1 on fresh account | main | ✅ | The two pre-2a bug fixes + handoff/registry updates |
| #40 | docs(agents): add §6.6 throughput-without-attention mode | main | ✅ | AGENTS.md §6.6 |
| #41 | feat(chainsaw): add Crossplane test harness infrastructure (phase 2a-1) | main | ?? | `tests/chainsaw/` skeleton + kind + run.sh + `.github/workflows/chainsaw.yml` |
| #42 | feat(crossplane): add PlatformSecret XRD + Composition + ESO wiring (phase 2a-2) | #41 | ?? | XRD, Composition, ClusterSecretStore, ArgoCD AppProject+Apps, Kyverno policy, chainsaw scenarios 00/01, unit tests |
| #43 | feat(argocd): app-of-apps bootstrap from Terraform (phase 2a-3) | #42 | ?? | `argocd/bootstrap.yaml` + `terraform_data.argocd_bootstrap` in management module |
| #44 | test(platform-secret): live integration + rotation chainsaw scenario (phase 2a-4) | #43 | ?? | `tests/integration/11_platform_secret_e2e.sh` + chainsaw 02-data-rotation |
| #45 | chore(handoff): phase 2a stack progress + new-session quickstart | #44 | ?? | Earlier handoff update (this file's predecessor) |
| #46 | fix(scripts): diag-component $SELECTOR typo + add platform-secret diagnostics | main | ✅ | Latent `$SELECTOR` bug fix + `platform-secret` component in diag-component.sh + 15-assertion unit test |
| #47 | feat(ci): unit tests on every push | main | ✅ | `.github/workflows/unit-tests.yml` |
| #48 | feat(ci): terraform fmt + validate on every push | main | ✅ | `.github/workflows/terraform-validate.yml` |
| #49 | chore: terraform fmt (no behaviour change) | main | ?? | Pure fmt fix for pre-existing drift in `terraform/base/vpc.tf` + 4 management files. Surfaced by #48's CI. **Merge first** — every other open PR's CI fails on `terraform fmt -check` until this lands. |

(That session's `chore/session-wrap` PR added that block — historical.)

**Suggested merge order** (the user said they would merge everything in one go):

1. **#49 first** (`chore: terraform fmt`) — unblocks `terraform-validate.yml` CI on every other open PR.
2. Then **#41 → #42 → #43 → #44 → #45 → this PR (#50?)** in stack order. Each child PR's merge will be a regular GH merge because each branch carries its own `merge main` commit resolving the `tests/unit/run.sh` additive conflict with #46. GitHub will auto-rebase the next child onto the new main on each merge.
3. After #43 merges, **dispatch `phase=management action=apply-and-verify`** so the new `terraform_data.argocd_bootstrap` runs its local-exec. Without this step, `argocd/bootstrap.yaml` is never `kubectl apply`ed and phase 2a stays inert on the cluster.

**Critical activation step:** PR #43 added `terraform_data.argocd_bootstrap` to `terraform/management/helm.tf`. That resource only takes effect on the live cluster when `phase=management action=apply-and-verify` runs. **You cannot skip this step.** Without it, the ArgoCD bootstrap App is never `kubectl apply`ed, ArgoCD doesn't discover `argocd/apps/`, and the PlatformSecret CRD never installs.

---

## Pending follow-ups (clearly out of scope for the previous session)

In rough priority order.

1. **PlatformCluster XRD (phase 2b).** REQ-XP-02, DESIGN.md §3. Pattern mirrors phase 2a:
   - Author the XRD + Composition + claim example.
   - Chainsaw `setup-assert` + happy-path + deletion scenarios first (kind has no IRSA; chainsaw scenarios bring their own static-cred ProviderConfig).
   - Live integration test against the management cluster — but heads-up: Crossplane provisioning an EKS via the AWS provider takes ~15 minutes per Composition iteration. Plan the session accordingly.
   - Unit tests at every layer.
   - Update bug-class registry as new bug classes surface.

2. **Fix `tests/unit/test_helm_render.sh`.** 4 ArgoCD Ingress assertions fail (the yq selectors look for `metadata.name=="argocd-server"` but chart 6.7.3 with release name `argo-cd` likely renders `argo-cd-server`). Currently tolerated by `continue-on-error: true` in `.github/workflows/unit-tests.yml`. **Requires `helm` locally to verify the fix**, which the previous session sandbox didn't have. Recommended approach: switch selectors from `metadata.name` to label `app.kubernetes.io/component=server` for chart-version robustness. Remove the `continue-on-error` once green.

3. **`scripts/argocd-apps.sh` extension for PlatformSecret claims.** The existing script dumps ArgoCD Application status; extend to show PlatformSecret claim status across all namespaces (similar to `diag-component.sh platform-secret`). Small.

4. **Cross-region smoke chainsaw scenario.** Adversarial-reviewer B finding J.15. Wait until a real consumer claims a non-`us-east-1` region.

5. **Long-running token-expiry chainsaw scenario.** Adversarial-reviewer B finding F.10. Nightly only — add a separate `workflow_dispatch` input on `chainsaw.yml` rather than running per-PR.

6. **Compositions strict-schema rejection scenario.** Adversarial-reviewer A finding 14. The PlatformSecret XRD's openAPIV3Schema is implicitly strict (no `x-kubernetes-preserve-unknown-fields: true`); a live cluster scenario that proves it (apply a claim with `spec.foo: bar`, assert kubectl-apply non-zero) would belong with phase 2b's Chainsaw work.

7. **Iteration 5 prerequisite.** Per the older 2026-05-10 entry below: base module needs Cognito groups (`k8s-admins`, `k8s-viewers`) before Keycloak realm work. Not yet authored.

8. **Unit-test coverage audit — to be done IMMEDIATELY BEFORE starting phase 3.**

   **Precedents (failures that prompted this — non-exhaustive):**
   - Integration-tests run 26347839740 silently reported PASS while four `wait_for` calls timed out. Root cause: bash `$UID` shadowing + missing `set -e`. No existing unit test would have caught either — see PR #59 and the new `tests/unit/test_shell_readonly_var_assignment.sh` / `test_integration_scripts_strict_mode.sh`.
   - PR #61's bug 4 (Composition string transform missing `type: Format`) was a silent fatal that every claim hit; no unit test caught it until PR #61 added `tests/unit/test_composition_string_transform_type.sh`.
   - Chainsaw condition-order non-determinism (XPlatformSecret / XRD conditions emitted in non-deterministic order, broke positional asserts) — no lint.
   - Dash-vs-bash `set -o pipefail` in chainsaw `script:` blocks — no lint.
   - ESO webhook-cert harness regression (kind-only) — no lint, no diagnostic until the post-#56 dump.
   - `crossplane-resources` OutOfSync (Kyverno-vs-ArgoCD drift, Bug 3) — no lint, would be cheap.

   **Audit procedure (when started):**
   1. Read every `retrospective/*` doc and every CI failure on closed PRs since 2026-05-23.
   2. Classify each as `would-a-unit-test-have-caught` / `no` / `maybe-but-not-worth-it`.
   3. For each `yes`, author a focused lint under `tests/unit/test_*.sh` and wire it into `tests/unit/run.sh`.
   4. Stop when every precedent in the list above is either covered by a new lint OR classified `no` / `maybe-but-not-worth-it`. Do NOT chase coverage metrics — author tests only where a real failure precedent exists.

   Goal: a measurable reduction in surprises during phase 3's live EKS-via-Crossplane work, where each iteration is ~15 min and a silent failure costs more than the lint.

---

## Current State (as of 2026-05-10)

### Iteration progress

| Iteration | Description | Status |
|-----------|-------------|--------|
| 0 | Base environment (VPC, Route53, Cognito, ACM) | Code complete, **plan ✅ apply-tested ✅** (apply+destroy confirmed 2026-05-04) |
| 1 | Management cluster (EKS, ArgoCD, Crossplane, ESO, ExternalDNS) | Code complete, **apply-and-verify ✅** end-to-end (2026-05-23) |
| 2 | Crossplane foundations (PlatformSecret XRD) | PR stack #41-#44 open (chainsaw infra, XRD+Composition+ESO, ArgoCD bootstrap, extended tests); awaiting merge + management re-apply |
| 3 | Platform services cluster | Not started |
| 4 | Observability (Grafana, Prometheus) | Not started |
| 5 | Authentication (Keycloak → Cognito SSO; EKS API → Keycloak) | Spec updated, not started |
| 6 | First workload cluster | Not started |

### What "plan passes" means

The GitHub Actions CI workflow runs `terraform plan` on every push. Both modules
now plan cleanly against the target AWS account — base and management init+plan
both succeed regardless of whether base has been applied first.

---

## What Was Done — 2026-05-23 (phase 0 + 1 bring-up on fresh account, phase 2a stack)

Session branches: `claude/sweet-mayer-swD65` (bug fixes + bring-up) →
`docs/agents-throughput-without-attention` (AGENTS §6.6) →
`feat/phase-2a-chainsaw-infra` (#41) →
`feat/phase-2a-platform-secret` (#42, stacked on #41) →
`feat/phase-2a-argocd-bootstrap` (#43, stacked on #42) →
`feat/phase-2a-extended-tests` (#44, stacked on #43) →
`chore/handoff-phase-2a-progress` (this PR, stacked on #44).

1. **Phase 0 brought up from scratch** on account `309191981509` after
   user rotated credentials. Route53 zone
   `309191981509.realhandsonlabs.net` auto-discovered; 25 base resources
   created (VPC, IGW, NAT pair, subnets, route tables, ACM ISSUED,
   Cognito user pool + test user). [run 26340162917](https://github.com/lago-morph/k8-platform/actions/runs/26340162917).

2. **Phase 1 brought up** after fixing a Kyverno policy that had been
   broken on `main`. EKS active, 2 nodes Ready, all 5 helm releases
   running, ArgoCD ingress reachable, ExternalDNS Route53 record live.
   [run 26340615326](https://github.com/lago-morph/k8-platform/actions/runs/26340615326).

3. **Bug fix: `post-comment.py` `KeyError`** (PR #39, merged). The CI
   summary-comment poster crashed whenever a `test-*` workflow step
   failed, masking the real CI failure cause. Added structural
   invariant tests so a future split between `OUTCOMES` and
   `STEP_LABELS` fails at unit-test time.

4. **Bug fix: Kyverno empty-backtick JMESPath** (PR #39, merged).
   Policy `03-ingress-managed-by-external-dns.yaml` had `` `` ``
   (empty backticks), which Kyverno's admission webhook rejects at
   apply time. Added a static lint that catches the bug class.

5. **AGENTS.md §6.6 throughput-without-attention** (PR #40, merged).
   Codifies the mode the user explicitly grants: suspend §6.5 repeat-
   back, make defensible assumptions, split work into stacked PRs,
   keep the next thing dispatched.

6. **Phase 2a Crossplane foundations stack** (PRs #41-#44, in review):
   - **#41 chainsaw harness**: kind config + `run.sh` + CI workflow
     + pinned versions matching `terraform/management/variables.tf`
     so chainsaw and management can't silently drift.
   - **#42 PlatformSecret XRD + Composition + ESO wiring**:
     `XPlatformSecret`/`PlatformSecret` at
     `platform.k8-platform.io/v1alpha1`; Composition renders ASM
     `Secret` named `k8-platform/<XR-uid>` (UID over name avoids
     cross-namespace claim collisions) + ExternalSecret in the
     claim's namespace; `aws-secrets-manager` ClusterSecretStore;
     ArgoCD AppProject + two Applications with sync-wave ordering
     (-10 for ESO config, 0 for crossplane-resources); Kyverno
     audit-mode namespace allowlist policy; chainsaw scenarios
     `_setup`, `00-claim-creates-secret`, `01-claim-deletion-cleanup`.
   - **#43 ArgoCD bootstrap**: `argocd/bootstrap.yaml` (app-of-apps
     at sync-wave -100, self-excluded from sync) kubectl-applied
     ONCE by Terraform after `argocd-server` Available; closes the
     GitOps loop so subsequent updates to `argocd/` land via Argo,
     not Terraform.
   - **#44 extended tests**: `tests/integration/11_platform_secret_e2e.sh`
     (live cluster, end-to-end including value rotation through ESO)
     + `tests/chainsaw/platform-secret/02-data-rotation/`.

**Bug-class registry rows added in `ai/TESTING-PLAN.md`** for every new
bug class encountered, per `AGENTS.md §6.2`.

**Open at session end:**
- PRs #41-#44 all in review (pending CI).
- The phase-2a code is in git but **NOT yet on the live cluster** —
  the next session needs to merge the stack, run
  `workflow_dispatch phase=management action=apply-and-verify` so
  Terraform applies `terraform_data.argocd_bootstrap`, then watch
  ArgoCD sync `argocd/` and confirm `tests/integration/11_*.sh`
  passes green against the live cluster.

---

## What Was Done — 2026-05-10 (Iteration 5 spec extension: kubectl via Keycloak)

Branch: `claude/keycloak-k8s-integration-LurOa`. Spec-only change; no Terraform
or manifest work yet.

1. **Untangled the two OIDC roles in EKS** — the cluster as OIDC *issuer* (IRSA,
   already in scope) versus the API server as OIDC *client* (the new bit).
   Documented this distinction in `DESIGN.md` §2.5 so it is not re-confused later.

2. **Added the kubectl-via-Keycloak federation flow** to `DESIGN.md` §2.5,
   including the diagram, the "Keycloak is the only IdP EKS sees" stance, and
   the rationale for username/group prefixes (`kc:`).

3. **Extended Iteration 5 deliverables** in `DESIGN.md` §4 to include
   `aws_eks_identity_provider_config`, the Keycloak `kubernetes` public/PKCE
   client, the Cognito → Keycloak group-claim mapper, and ClusterRoleBindings
   for `kc:k8s-admins` / `kc:k8s-viewers`.

4. **Added REQ-AUTH-07..10** in `REQUIREMENTS.md`:
   - 07: associated OIDC config on the API server pointing at Keycloak
   - 08: groups originate in Cognito, mapped through Keycloak
   - 09: ClusterRoleBindings under `clusters/<cluster>/`; IAM stays as break-glass
   - 10: documented kubectl/`oidc-login` setup

5. **Added ADR-007** "EKS API server federates to Keycloak; Cognito stays
   behind Keycloak; IAM is break-glass" with the full reasoning chain
   (provider slot choice, group source choice, IAM-as-recovery, token
   refresh latency caveat).

**Decisions captured this session:**
- Group source: Cognito groups, passed through Keycloak (preserves ADR-004
  and REQ-AUTH-03).
- Sequencing: extend Iteration 5 rather than splitting into 5b — auth lights
  up as one coherent milestone.

**Immediate next step:** when Iteration 5 begins, the base module needs Cognito
groups (`k8s-admins`, `k8s-viewers`) added before Keycloak realm work can be
tested end-to-end.

---

## What Was Done — 2026-05-04 (Terraform fixes + Crossplane v2)

1. **Investigated real CI run** — a `workflow_dispatch apply-and-destroy` run on
   `main` was missed because CI results are posted as commit comments (not PR
   comments or check runs) when no PR exists. Updated `terraform-ci-watch` skill
   with explicit two-path instructions and `curl` commands for reading commit comments.

2. **Fixed management module Terraform errors** found in the CI apply run:
   - `manage_aws_auth_configmap = true` removed (no longer valid in EKS module v20+)
   - Remote state `try()` guards added so management plans when base state is empty
   - `aws_nat_gateways` data source guarded with `count` conditional
   - NAT gateway route block converted to `dynamic` to avoid index-out-of-bounds
   - Removed `kubernetes` provider entirely — replaced with `terraform_data`
     local-exec for Crossplane manifests; ArgoCD ingress moved to Helm values

3. **Upgraded to Crossplane v2 APIs** — the previous code used v1 APIs removed in v2:
   - `ControllerConfig` (v1alpha1) → `DeploymentRuntimeConfig` (v1beta1)
   - `controllerConfigRef` → `runtimeConfigRef` (with explicit apiVersion/kind)
   - Provider package: `upbound/provider-aws:v0.46.0` → `upbound/provider-family-aws:v1.12.0`
   - Crossplane Helm chart: `1.15.1` → `2.0.1`
   - IRSA service account: `provider-aws-*` → `upbound-provider-family-aws`

4. **Plan-only CI now fully green** — both base (25 resources) and management
   (51 resources) init and plan without errors on every push to `test/**`.

---

## What Was Done — 2026-05-03 second session (docs cleanup + skills)

Branch: `claude/plan-and-cleanup-docs-w7OKB`. Implementation phases 1–4 of
the plan in `/root/.claude/plans/we-need-to-plan-vectorized-moore.md`.

1. **Slimmed `CLAUDE.md`** — secrets table reduced from 9 rows to 3 (only
   the actually-required GitHub secrets), CI Loop section (~65 lines)
   replaced with a 4-line pointer to the new skills. Net 168 → 110 lines.

2. **Reorganized `ai/`**:
   - `ai/testing-overview.md` → `ai/archive/` (superseded by skill)
   - `ai/BLOG-OVERVIEW.md`, `ai/BLOG-OUTLINES.md` → `ai/blog/`
   - Added `ai/archive/README.md` and `ai/blog/README.md`
   - Kept in place: `REQUIREMENTS.md`, `DESIGN.md`, `handoff.md`,
     `testing-guidelines.md`

3. **Added a `SessionEnd` hook** at `.claude/settings.json` that copies
   each session's transcript to `logs/<session-id>.jsonl` automatically.
   The `.gitignore` rule on `*.jsonl` is preserved — files land untracked
   until a human reviews and `git add -f`s them. See `logs/README.md`.

4. **Created `terraform-ci-watch` skill** at
   `.claude/skills/terraform-ci-watch/`. Reusable across other Terraform-
   on-AWS-via-GitHub-Actions projects. Drives the post-push CI loop:
   locate run, poll, fetch logs on failure, classify, fix, re-push,
   3-strike escalation. Reference docs split out:
   `failure-taxonomy.md`, `log-fetching.md`, `escalation-template.md`.

5. **Created `crossplane-claim-verify` skill** at
   `.claude/skills/crossplane-claim-verify/`. Independent of the
   terraform skill; use whichever fits the change. Drives the
   post-claim-apply loop: wait for `Synced`/`Ready`, descend into managed
   resources, verify the actual cloud resource out-of-band, classify and
   fix, 3-strike escalation. Reference docs: `readiness-conditions.md`,
   `failure-taxonomy.md`, `cloud-verification.md`,
   `escalation-template.md`.

### Iteration code state — unchanged from first session

Iterations 0 and 1 are still code-complete and CI-plan-passing but not
yet apply-tested. That's still the immediate next milestone (Phase 5 in
the plan).

### Only 3 GitHub secrets are required

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | AWS credential for the target account |
| `AWS_SECRET_ACCESS_KEY` | AWS credential for the target account |
| `AWS_REGION` | e.g. `us-east-1` |

Everything else (domain, state bucket, Cognito test user) is auto-discovered
or generated at runtime.

---

## What Was Done — 2026-05-23 (Phase 1 verified + test scaffolding)

1. **Phase 1 verified end-to-end** in AWS. PR #34
   contains the seven fixes that took us from cold management apply to a
   live ArgoCD UI reachable over HTTPS through the NLB. See
   `ai/TESTING-PLAN.md` for the bug-to-test traceability matrix.

2. **Test scaffolding landed** to prevent another seven-strike phase-1
   bring-up. Three layers (and a fourth planned):

   - `tests/unit/` — four new suites: `test_helm_render.sh`,
     `test_irsa_helm_linkage.sh`, `test_iam_required_actions.sh`,
     `test_eks_module_defaults.sh`. All run in <30s, no AWS / no cluster.
     Catch five of the seven phase-1 bugs at authoring time.
   - `policies/audit/` — Kyverno installed in Audit mode with 8 starter
     ClusterPolicies. Acts as continuous in-cluster assertion store.
   - `tests/integration/` — 10 end-to-end smoke tests (ArgoCD app sync,
     ExternalDNS → Route53, NLB → nginx → echo, ESO secret round-trip,
     Crossplane MR + XRD/Claim, IRSA STS round-trip, Kyverno report,
     selfHeal loop, secondary ingress). Orchestrator at
     `tests/integration/run.sh`.
   - **(Planned)** `tests/chainsaw/` — Kyverno Chainsaw for Crossplane
     logic, to be authored as the first deliverable of phase 2. See
     `ai/TESTING-PLAN.md` §"Layer 4 (planned)".

3. **Helper scripts** under `scripts/`: `k8s-status.sh`, `k8s-logs.sh`,
   `diag-component.sh`, `kyverno-policies.sh`, `kyverno-violations.sh`,
   `argocd-apps.sh`, `route53-records.sh`, `aws-creds-check.sh`.
   All read-only, all deterministic, source-pinned at top with usage.

4. **Workflow diagnostics improved**: the management argocd-url verify
   step now queries Route53 directly (not `dig` against public
   resolvers) and dumps pod logs / events / ingress YAML on failure.
   Same diagnostic block now mirrors to the HTTP step too.

---

## Immediate Next Step

The previous AWS account is gone. The first thing this session does is
follow **NEW SESSION QUICKSTART** at the top of this file:

1. `scripts/aws-creds-check.sh` — confirm the new account is usable.
2. Bring phase 0 and phase 1 back up from scratch
   (`apply-and-verify` for each, then full test bundle per §6.3).
3. **Only after phase 1 is green end-to-end**, start phase 2.

### Phase 2 — Crossplane foundations (start once phase 1 verified)

Authorial order, with §6.4 adversarial review at each test-drafting
point:

1. **Author `tests/chainsaw/` infrastructure first** (kind config,
   run.sh, per-XRD Test fixtures). See `ai/TESTING-PLAN.md` §"Layer 4
   (planned)". Before authoring the chainsaw scenarios themselves,
   draft the test list and invoke §6.4 (adversarial subagent review).
2. **Author `crossplane/xrds/platform-secret.yaml` + composition**;
   verify green via Chainsaw before any AWS apply. The test list for
   PlatformSecret also goes through §6.4 review.
3. **Author `crossplane/xrds/platform-cluster.yaml` + composition**;
   verify green via Chainsaw. Same §6.4 review.
4. **Re-apply management module** to register both XRDs in the live
   cluster (terraform_data already in place would re-fire if XRDs
   added there; for phase 2 they ship as ArgoCD-managed instead —
   wire an ArgoCD Application pointing at `crossplane/`).
5. **Run integration tests** —
   `tests/integration/05_crossplane_managed_resource.sh` and
   `06_crossplane_xrd_claim.sh` — to confirm round-trip against real
   AWS. Any failure goes through §6.2 (TDD on bug fix).

### Stacked-PR pattern for phase 2

Per `AGENTS.md §3`:

1. Phase 2 implementation + tests → one PR off `main`.
2. Phase 2 live-run + bug-fix work → stacked PR off (1).
3. Once phase 2 tests pass against the live cluster, dispatch
   `destroy` scoped to phase 2 only (per `AGENTS.md §5.1`: delete
   Claims → wait for cloud cleanup → delete XRDs/Compositions; leave
   phase 1 management cluster alone). Re-apply phase 2 from scratch
   and run the full test bundle again — the clean re-run is the
   actual quality signal.

---

## Key Design Decisions (summary)

Full rationale is in `ai/DESIGN.md`. Short version:

| Decision | Choice | Why |
|----------|--------|-----|
| Multi-cluster pattern | Hub-spoke via ArgoCD | Management cluster manages all others |
| Cluster provisioning | Crossplane XRDs | Self-service via Claims, no Terraform per-cluster |
| Secret distribution | ESO + AWS Secrets Manager | Single source of truth, no k8s Secret replication |
| TLS (this account) | ACM wildcard + NLB termination | Pre-existing zone has no public-ACME challenge path |
| TLS (production) | cert-manager + Let's Encrypt | Per-service certs, fully automated |
| State backend | S3 + DynamoDB | Standard; bootstrapped automatically by CI |
| Instance sizing | `t3.medium` × 2 | Fits within the 9-instance EC2 quota |
