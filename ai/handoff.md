# Session Handoff — k8-platform

This file is the first thing a new session reads. It captures what was
done last, the current state of the cluster, and the next concrete steps.

The **Environment State** block immediately below tracks what's currently
live in AWS and which phase is being worked on. The agent reads it first
and writes back to it after every workflow run. See
`ai/testing-guidelines.md` for the procedure that drives those updates.

---

## NEW SESSION QUICKSTART (read this first)

**Resume context: late-2026-05-24 session.** You are picking up after a session that root-caused the long-standing "PlatformSecret claim never Ready=True" bug to **two cascading misconfigs**, fixed the first half, and was mid-iteration on the second half when (a) the sandbox capabilities were upgraded AND (b) the AWS test account was rotated.

### The AWS account has been rotated — start from scratch

Per AGENTS.md §8.1, the AWS test account is ephemeral and is usually torn down in full between sessions. **The cluster, IRSA roles, ACM cert, Cognito pool, and Route53 zone from the prior session no longer exist.** All `applied` phase states in the table below were on a now-deleted account; treat them as "the code is known to apply cleanly" but **not** "the cluster is live".

You must bring up phases 0 → 1 → 2 from scratch on the new account. See "Where this leaves us — what to do FIRST" below.

### Session capabilities you now have (NEW — not available in prior sessions)

The new sandbox grants you:

1. **`aws` CLI with full admin** on the current test account (env vars `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` pre-loaded — confirm with `aws sts get-caller-identity` before doing anything else).
2. **Unlimited outbound network** — no jentic bridge needed for AWS / kubectl / curl / ArgoCD API.
3. **Direct `kubectl` against the live management cluster** (once phase 1 is applied): `aws eks update-kubeconfig --name k8-platform-mgmt --region "$AWS_REGION"`.

**This changes the inner debug loop fundamentally.** Prior sessions had to dispatch a workflow + wait 3 minutes + parse a 170 KB log just to read one MR's `.status.conditions`. You can now:

- Read MR status: `kubectl get secret.secretsmanager.aws.upbound.io <name> -o yaml`
- Verify IRSA trust subject: `aws iam get-role --role-name k8-platform-mgmt-crossplane --query Role.AssumeRolePolicyDocument`
- Confirm caller: `aws sts get-caller-identity`
- Force ArgoCD sync: hit `argocd.management.<zone>/api/v1/applications/<name>/sync` directly. ArgoCD admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`. Zone is `<account-id>.realhandsonlabs.net` where account-id comes from `aws sts get-caller-identity`.

**Do not author one-off diagnose workflows for things you can now check directly.** `phase-2-diagnose.yml` is still the right tool for **capturing a reproducible snapshot before opening a PR** — not for ad-hoc lookups during a debug loop.

The `ext-aws` / `ext-argocd` / `ext-kubernetes` skill requests in older handoffs are no longer needed for THIS session. Keep them on the radar for future sandboxes that lose this access.

### What was just done (PRs #64–#68 — chronological)

Cascading failure chain rooted in `terraform/management/helm.tf`'s `terraform_data.crossplane_aws_provider`. Each PR fixed one layer of the onion:

| PR | Merged | Fix |
|---|---|---|
| **#64** | ✅ | **Bug 3** (Kyverno-vs-ArgoCD drift): set `spec.admission: true` + `pod-policies.kyverno.io/autogen-controllers: none` on `crossplane/policies/09-platform-secret-namespace-allowed.yaml`. Kyverno was defaulting these fields onto every ClusterPolicy, surfacing as eternal `crossplane-resources` OutOfSync. Extended `tests/unit/test_kyverno_policy_lint.sh` to assert all three fields. |
| **#65** | ✅ | **Enhanced `phase-2-diagnose.yml`**: dump XR yaml in full (was `head -120` truncated), walk every `XR.spec.resourceRefs` and yaml each, print events, grep crossplane core logs filtered to the XR name. Plus a YAML-literal-block fix because the first attempt embedded a Python heredoc whose unindented body terminated the `run: |` block (GitHub silently refused to register `workflow_dispatch` until merged — error message was `Workflow does not have 'workflow_dispatch' trigger`). |
| **#66** | ✅ | **Bug 5 / root cause of composite-not-Ready**: pin `serviceAccountTemplate.metadata.name: upbound-provider-family-aws` in the `DeploymentRuntimeConfig`. Without it Crossplane generates a hash-suffixed SA name (e.g. `provider-family-aws-24aaab54a3a0`) that doesn't match the IRSA trust subject in `terraform/management/irsa.tf:98` (`namespace_service_accounts = ["crossplane-system:upbound-provider-family-aws"]`). AssumeRoleWithWebIdentity → 403 → ASM Secret MR never reconciles → XR Ready=False → claim Waiting. |
| **#67** | ✅ | **`triggers_replace` miss**: PR #66's YAML edit was a no-op at apply time. `terraform_data.crossplane_aws_provider.triggers_replace` only watched the IRSA arn + provider version, not the manifest body. Extracted manifest into `local.crossplane_aws_provider_manifest` and added `sha256(local....)` to triggers. Same pattern as `terraform_data.argocd_bootstrap` (helm.tf:360–363). |
| **#68** | **OPEN** (draft) | **Provider Deployment not rolled**: after #67's apply ran (`terraform_data` replaced, `deploymentruntimeconfig configured`), diagnose run [26355033199](https://github.com/lago-morph/k8-platform/actions/runs/26355033199) showed the new SA `upbound-provider-family-aws` exists with the correct IRSA annotation BUT the running provider pod is still mounted on the OLD hash-suffixed SA. Crossplane's Provider controller only re-renders its Deployment when the Provider object itself changes — a `DeploymentRuntimeConfig` edit alone doesn't flip `serviceAccountName`. PR #68 adds `kubectl delete deploy -l pkg.crossplane.io/provider=provider-family-aws --wait=false` after the apply so Crossplane recreates the Deployment from the current config. Includes a `"provisioner-command-v2"` sentinel in `triggers_replace` since the command-body edit lives outside the manifest local that's hashed. |

### Where this leaves us — what to do FIRST

The account is brand new (per AGENTS.md §8.1). PR #68's verification can't happen until phases 0 and 1 are applied on the new account.

**Step 0 — read this whole quickstart**, then `aws sts get-caller-identity` to confirm you have AWS creds and what account you're on. If `aws sts get-caller-identity` fails, the env vars aren't set — stop and ask the user.

**Step 1 — confirm PR #68 + PR #69 are merged to main.** If either is still open: `mcp__github__pull_request_read` for status, then either ask the user to merge or merge via `mcp__github__merge_pull_request` if CI is green. PR #69 is the handoff doc (this file); PR #68 is the actual Crossplane-Deployment-rebuild fix that completes the IRSA chain.

**Step 2 — bring up phase 0 (~5 min).** Dispatch `terraform-test.yml` on `main` with `phase=base action=apply-and-verify`. Read the job log for `Apply complete! Resources: ~25 added` and `aws_acm_certificate_validation.cert: Creation complete`. Do NOT trust the workflow's overall `success` conclusion alone — read the apply step's evidence line.

**Step 3 — bring up phase 1 (~15 min).** Dispatch `terraform-test.yml` `phase=management action=apply-and-verify`. Read the log for `Apply complete! Resources: ~51 added`, the five `helm_release.<name>: Creation complete after` lines, and `application.argoproj.io/bootstrap created`. The `Verify ArgoCD URL` step should log `argocd reachable at https://argocd.management.<zone> (HTTP 200|307)`.

**Step 4 — wait ≥3 minutes for ArgoCD to sync phase 2** (XRDs, Compositions, ClusterPolicy 09, ClusterSecretStore are all GitOps-only). ArgoCD's default refresh interval is 3 min; jumping past this shows OutOfSync from race rather than actual drift.

**Step 5 — confirm the post-PR-#68 cluster state directly with `kubectl`** (NEW: no diagnose workflow needed for ad-hoc lookups).

```bash
aws eks update-kubeconfig --name k8-platform-mgmt --region "$AWS_REGION"
kubectl -n crossplane-system get deploy -l pkg.crossplane.io/provider=provider-family-aws \
  -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}{"\n"}'
# Expected: upbound-provider-family-aws  (NOT provider-family-aws-<hash>)
```

If `serviceAccountName` is the hash form, PR #68's `kubectl delete deploy` step didn't take effect — re-trigger the apply (it's idempotent).

**Step 6 — verify a probe claim end-to-end.**

```bash
NS=verify-irsa-$(date +%s)
kubectl create ns "$NS"
kubectl apply -n "$NS" -f - <<YAML
apiVersion: platform.k8-platform.io/v1alpha1
kind: PlatformSecret
metadata: { name: verify-claim, namespace: $NS }
spec: { refreshInterval: 30s, region: "$AWS_REGION", description: "post-#68 verify" }
YAML
kubectl wait --for=condition=Ready --timeout=180s -n "$NS" platformsecret/verify-claim
kubectl delete platformsecret -n "$NS" verify-claim
kubectl delete ns "$NS"
```

**Step 7 — if the claim does NOT go Ready=True, investigate the SECONDARY bug.** Prior-session diagnose run [26355033199](https://github.com/lago-morph/k8-platform/actions/runs/26355033199) (on a now-torn-down account, but the bug class persists) showed that *even with the SA name fixed*, the XR had **zero `status.conditions`** and the composed managed resources (ASM Secret + ExternalSecret) were **NotFound**. The composition reconciler isn't producing the MR objects at all — `XR.spec.resourceRefs` is populated (composition function ran) but the MRs themselves don't exist.

Top hypotheses, in order:
1. **Crossplane v2.0.1 composition-reconciler bug** — see "Crossplane 2.2 upgrade" in Pending follow-ups (item 8). v2.2 has the unified composite reconciler / realtime compositions that may fix this directly. **DO NOT upgrade yet** — first finish phase 2 on 2.0.1 so cause-and-effect stays clean, then upgrade (per user instruction).
2. **Provider CRD missing or stale.** Check `kubectl get crd secrets.secretsmanager.aws.upbound.io` and `provider.pkg.crossplane.io/provider-aws-secretsmanager`'s Healthy condition.
3. **Composition function input rejected.** Look at `kubectl -n crossplane-system logs deploy/function-patch-and-transform-* --tail=200` filtered to the XR name; v2.0.1 strict-decoding has bitten us before (Bug 4 in PR #61).

**Step 8 — phase 2 GREEN end-to-end.** Update Phase states below. Land PR #58 next (phase-2 lifecycle tooling), then start the Crossplane 2.2 upgrade (item 8 in Pending follow-ups), then phase 3.

### Open PRs at session end (2026-05-24 late)

| PR | What | State |
|---|---|---|
| #58 | Phase-2 lifecycle tooling (mode input + teardown/verify-absent/rebuild) + `ai/PHASE-2-LIFECYCLE-PLAN.md` | **draft** — still held pending phase 2 end-to-end green. After Step 5 above, this is the next thing to land. |
| #68 | Force provider Deployment rebuild after DeploymentRuntimeConfig change | **draft / CI in progress** — see Steps 1–3 |

Older PRs from this session — #64, #65, #66, #67 — are all merged.

### Critical behavioral rules (carried forward from prior sessions, reinforced this session)

| Action | Evidence to check (not just `success`) |
|---|---|
| `terraform apply` on management | `Plan: N to add ...` line confirms a replace fired. A `0 added, 0 changed, 0 destroyed` after a manifest edit means `triggers_replace` is missing a hash — PR #67 added the manifest sha256 idiom. |
| `kubectl apply` on a DeploymentRuntimeConfig | `kubectl -n crossplane-system get deploy -l ... -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}'` reflects the NEW name. Crossplane does NOT roll the Deployment on RuntimeConfig changes alone (PR #68's whole point). |
| IRSA trust | `aws iam get-role --role-name <role> --query 'Role.AssumeRolePolicyDocument.Statement[*].Condition'` shows the `StringEquals` clause; the SA's pod-projected token's `sub` claim must match. |
| Claim Ready | `kubectl wait --for=condition=Ready --timeout=180s ...` is the unambiguous signal. Don't trust step exit codes. |
| ArgoCD app | `kubectl get application <name> -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}'` must be `Synced/Healthy`. |

### Behavioral rule additions this session

- **"It applied successfully" ≠ "the change reached the cluster".** Three times this session a green apply did not produce the intended cluster state: PR #66's YAML edit was no-op'd by `triggers_replace`; PR #67's apply ran but didn't roll the Deployment; the very first apply (run 26354235231) reported "Apply complete! Resources: 0 added" but I initially read that as success. Always trace from PR diff → terraform plan diff → kubectl object diff → behavior in cluster.
- **`workflow_dispatch` against a non-default-branch ref** silently fails with `"Workflow does not have 'workflow_dispatch' trigger"` when the workflow file is malformed on that branch. PR #65's first push had an unindented Python heredoc that broke the YAML literal block; Actions wouldn't register the workflow until it parsed clean. Validate workflow YAML with `python -c "yaml.safe_load(open(...))"` before push if you've changed anything that looks like a heredoc, multi-line string, or inline script.
- **Crossplane version awareness.** The cluster Helm-chart version is `crossplane_version = "2.0.1"` (`terraform/management/variables.tf:78`). Several behaviors I assumed (composition reconciler producing MRs reliably, RuntimeConfig propagation) may be v2.0-specific. v2.2 is current stable. See pending-followups item 8 for the planned upgrade.
- **AWS account is ephemeral — codified in AGENTS.md §8.1 this session.** First version of this handoff hardcoded account ID `413117505476` in ~12 places (FQDN, S3 bucket name, ACM cert SAN, etc.); user flagged that the account is rotated between sessions and stale IDs waste a debug loop. Scrubbed and rule added.

### For the next /self-retrospective (user will trigger manually)

Surface these as findings:
1. **"Hardcoded ephemeral account IDs in docs are an anti-pattern"** — material for an AGENTS.md justification entry pointing at the new §8.1. The bug class is "writing values into a plan/handoff that won't survive the resource lifecycle". Generalize beyond AWS accounts: any per-session identifier (sandbox FS paths, run IDs as something-to-trust, ephemeral SHAs) follows the same rule.
2. **"It applied successfully ≠ the change reached the cluster"** (above) — three independent failure modes in one session (PR #66 triggers miss, PR #67 Deployment-not-rolled, run 26354235231 misread); justifies a stronger pattern in AGENTS.md §6.

### Pointers

- `ai/PHASE-2-LIFECYCLE-PLAN.md` — phase 2 A → E checklist
- `terraform/management/{helm.tf,irsa.tf,variables.tf}` — the files this session touched
- `crossplane/policies/09-platform-secret-namespace-allowed.yaml` — Bug 3 fix
- `.github/workflows/phase-2-diagnose.yml` — the diagnose script (enhanced PRs #64+#65+#67)
- `AGENTS.md` §6.6 (throughput mode), §6.7 (verify-then-PR)
- `retrospective/` — prior session retros; consider running `/self-retrospective` at end of this session



## Environment State

| Field | Value |
|---|---|
| Active phase | **Phase 2 — code-fixed, needs end-to-end verify on a fresh account.** Prior session shipped fixes via PRs #64+#66+#67 (merged) and #68 (open). The cluster they were verified against has been torn down; the new session must apply phases 0 → 1 → 2 from scratch and re-verify. |
| Last update | 2026-05-24 late — end of IRSA-root-cause session |
| AWS account | **ephemeral — derive from `aws sts get-caller-identity`** (see AGENTS.md §8.1) |
| Route53 zone | `<account-id>.realhandsonlabs.net.` (account-id from `aws sts get-caller-identity`) |
| EKS cluster | `k8-platform-mgmt` in the region from `$AWS_REGION` (cluster name is fixed by `terraform/management/variables.tf`; region comes from the workflow env / secret) |
| Cluster URL | `https://argocd.management.<account-id>.realhandsonlabs.net` (post-phase-1) |
| State backend | s3 `k8-platform-tfstate-<account-id>`, lock table `k8-platform-tfstate-lock` (auto-bootstrapped by terraform-test.yml) |

### Phase states

State semantics: `code-only` = source is in the repo, never applied on THIS account; `applied` = applied on THIS account this session; `verified` = applied AND probed end-to-end this session. Cross-session `applied`/`verified` are NOT durable (§8.1).

| Phase | State (this account) | Code notes | Last applied (any account) |
|---|---|---|---|
| 0 base | **code-only — needs apply** | Known good. ~25 resources: VPC, IGW, NAT pair, subnets, route tables, ACM ISSUED, Cognito user pool + test user. | 2026-05-24 on prior-account |
| 1 management | **code-only — needs apply** | Known good. ~51 resources including IRSA roles, helm_release × 5, ArgoCD bootstrap, Crossplane DeploymentRuntimeConfig (post-#64–#68 chain). | 2026-05-24 on prior-account |
| 2 xrds | **code-fixed — needs apply + verify** | PRs #64+#66+#67 merged. PR #68 still open as of this handoff. Secondary suspected issue: XR with zero `.status.conditions` even after IRSA fix — see Step 7 of QUICKSTART. | n/a (not green on any account yet) |
| 3 platform | scaffolding only (PR #55 merged earlier) | — | — |
| 4 observability | not-coded | — | — |
| 5 auth | not-coded (spec done 2026-05-10) | — | — |
| 6 workload | not-coded | — | — |

### Live AWS resource shape (durable shape, not durable IDs)

```
EKS cluster name:   k8-platform-mgmt  (fixed by variables.tf; region from $AWS_REGION)
IRSA role names:    k8-platform-mgmt-{argocd,crossplane,eso,external-dns}
                    Trust subjects (post-#66): system:serviceaccount:crossplane-system:upbound-provider-family-aws (for the crossplane role).
                    Verify any role's trust via:
                      aws iam get-role --role-name k8-platform-mgmt-crossplane \
                        --query Role.AssumeRolePolicyDocument
Route53 zone:       <account-id>.realhandsonlabs.net.  (pre-existing per-account; not provisioned by us)
ACM wildcard cert:  *.<account-id>.realhandsonlabs.net  (ISSUED, NLB-bound by ingress-nginx)
ASM secrets:        k8-platform/<XR-uid>  (created by Crossplane on PlatformSecret claims)
```

Always run `aws sts get-caller-identity` first to confirm what account you're on.

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

8. **Crossplane 2.0.1 → 2.2.x upgrade — AFTER phase 2 is fully green and BEFORE starting phase 3.** (Per user instruction, late 2026-05-24 session.)

   **Why this slot, not earlier:**
   - Doing it during phase 2 conflates "fix didn't work" with "fix worked but upgrade broke something else" — keep the variables separate.
   - Doing it during phase 3 risks blocking the EKS-via-Crossplane work on an unrelated upgrade-bisect; phase 3 iterations are ~15 min each so a regression discovery is expensive.
   - Doing it between is the safe slot: phase 2 proves the Composition pipeline works on 2.2; phase 3 inherits a known-good base.

   **Why it's worth doing:**
   - Current cluster runs `crossplane_version = "2.0.1"` (`terraform/management/variables.tf:78`). 2.2 is current stable.
   - Late 2026-05-24 session uncovered a symptom (XR with zero `.status.conditions`, MRs in `spec.resourceRefs` but never created on the cluster — diagnose run 26355033199) consistent with v2.0 composite-reconciler limitations that v2.1+ unified reconciler / realtime compositions address. Independent of PR #68's fix.
   - Provider-family-aws is pinned at `v1.12.0` (compatible with 2.x family). Re-check compatibility matrix before bumping.

   **Upgrade procedure (when started):**
   1. Read https://docs.crossplane.io/v2.2/whats-new/ and the v2.0 → v2.1 → v2.2 release notes for breaking changes.
   2. Bump `var.crossplane_version` to `2.2.x`. Re-check `crossplane_provider_family_aws_version` and `crossplane_function_patch_and_transform_version` for compatibility; bump if needed.
   3. Plan: `terraform-test phase=management action=plan`. Read the plan diff: expect `helm_release.crossplane` to be updated in-place (Helm chart upgrade); the three `terraform_data.crossplane_*` resources may or may not replace depending on their `triggers_replace`. If a Crossplane chart upgrade changes the Provider/Function CRDs, expect the providers to reconcile through a revision bump.
   4. Apply, then verify with the existing `phase-2-diagnose.yml` and a fresh probe claim. The success criterion is the same: claim reaches Ready=True within 90s and the ASM Secret MR has a real `status.atProvider.arn`.
   5. If 2.2 changed the DeploymentRuntimeConfig propagation semantics such that PR #68's `kubectl delete deploy` hack is no longer needed, remove it — keep the apply minimal.

   Authoring tip: a small chainsaw or kind-based test that brings up Crossplane + Composition on 2.2 BEFORE the live cluster bump can de-risk significantly. The `tests/chainsaw/` harness already pins versions in `run.sh`.

9. **Unit-test coverage audit — to be done IMMEDIATELY BEFORE starting phase 3.**

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
