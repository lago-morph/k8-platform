# Session Handoff — k8-platform

This file is the first thing a new session reads. It captures what was
done last, the current state of the cluster, and the next concrete steps.

The **Environment State** block immediately below tracks what's currently
live in AWS and which phase is being worked on. The agent reads it first
and writes back to it after every workflow run. See
`ai/testing-guidelines.md` for the procedure that drives those updates.

---

## NEW SESSION QUICKSTART (read this first)

You are picking up a session whose predecessor brought the platform from a fresh AWS account (`309191981509`) through phases 0 and 1, shipped two bug fixes (PRs #39, #40 — both merged), and produced a phase-2a Crossplane foundations stack (PRs #41-#45) plus three independent CI/diagnostics PRs (#46, #47, #48). By the time you read this most or all of those PRs should have merged. **Verify the state below before changing anything.**

### Step 1 — confirm the cluster is alive and which account you're in

```sh
scripts/aws-creds-check.sh
aws eks update-kubeconfig --name k8-platform-mgmt --region us-east-1
kubectl get nodes
kubectl get pods -A | grep -E '(crossplane|external-secrets|external-dns|argocd|ingress-nginx|kyverno)'
```

Expect:
- AWS account ID `309191981509`
- Route53 zone `309191981509.realhandsonlabs.net.` (ID `Z0426781193AJAT8UDLZO`)
- EKS cluster `k8-platform-mgmt` with 2 nodes Ready
- 5 helm releases healthy: argocd, crossplane-system, external-secrets, external-dns, ingress-nginx (+ kyverno)
- ArgoCD UI reachable at `https://argocd.management.309191981509.realhandsonlabs.net` (HTTP 200)

If any of those don't match, treat this as a fresh-account session and follow the fallback at the bottom of this section.

### Step 2 — confirm phase 2a actually landed on the cluster

Phase 2a code is in PRs #41-#45. **Merging the stack is not enough** — the management module added one new `terraform_data.argocd_bootstrap` resource in PR #43 that needs an actual `terraform apply` to take effect. Without it, ArgoCD never knows about the bootstrap App and `argocd/` stays unsynced.

```sh
# A. Has the management cluster been re-applied since #43 merged?
#    Check by looking for the bootstrap Application in argocd:
kubectl get applications -n argocd bootstrap

# B. Has the bootstrap App synced the rest of argocd/?
kubectl get applications -n argocd
# Expect at least: bootstrap, crossplane-resources, management-cluster-config

# C. Did the ClusterSecretStore become Ready?
kubectl get clustersecretstore aws-secrets-manager
kubectl get clustersecretstore aws-secrets-manager \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# D. Are the XRDs registered?
kubectl get crd platformsecrets.platform.k8-platform.io
```

If A is empty: dispatch `phase=management action=apply-and-verify`. The new `terraform_data.argocd_bootstrap` will run its local-exec and `kubectl apply -f argocd/bootstrap.yaml`. From that moment on ArgoCD self-manages `argocd/`.

If B shows the bootstrap App but not the children: check `kubectl describe app bootstrap -n argocd` for sync errors. Most likely cause: stale `targetRevision: main` pointing at a different commit than your local main.

If C is False or D is missing: the bootstrap synced but ESO config + crossplane resources haven't applied yet. Wait 30s for the sync-wave ordering (-10 then 0) to land.

### Step 3 — end-to-end verify PlatformSecret on the live cluster

```sh
tests/integration/11_platform_secret_e2e.sh
```

This applies a `PlatformSecret` claim with a 10s refreshInterval, asserts Ready, writes a value to ASM, asserts the K8s Secret materializes, rotates the value, asserts ESO refreshes within the interval, deletes the claim, asserts ASM + ExternalSecret + K8s Secret are all gone. It `skip`s cleanly if the XRD CRD is not on the cluster (step 2 not yet complete).

That test passing is **the** completion criterion for REQ-XP-01 and REQ-XP-04. Mark phase 2 `verified` in the Environment State block below once it lands green.

### Step 4 — pick the next deliverable

In rough priority order (see "Pending follow-ups" later in this file for full list):

1. **PlatformCluster XRD** (phase 2b) — the second of the two phase-2 XRDs per DESIGN.md §3 / REQ-XP-02. Full EKS provisioned via Crossplane. Substantial — likely its own session given EKS-via-Crossplane validation time (~15 min per Composition iteration). Pattern follows phase 2a: chainsaw scenarios first, then live integration.
2. **Fix `tests/unit/test_helm_render.sh`** — 4 ArgoCD Ingress assertions fail on main (4 pre-existing failures noted in PR #39's body, tolerated in #47's CI workflow via `continue-on-error: true`). The yq selectors look for `metadata.name=="argocd-server"` but the rendered chart doesn't produce an Ingress with that exact name; likely a chart-version artifact. **Requires `helm` available locally to verify**, which the previous session didn't have. Likely fix: switch from name-based to label-based selectors (`app.kubernetes.io/component=server`).
3. **Cross-region smoke chainsaw scenario** (adversarial-reviewer B finding J.15) — once a real consumer claims a non-`us-east-1` region, build a smoke scenario.
4. **Long-running token-expiry chainsaw scenario** (adversarial-reviewer B finding F.10) — nightly only; not per-PR.

### Step 5 — read AGENTS.md before starting

Required reading. Pay particular attention to:
- §3 — branch policy + stacked PR procedure
- §5.1 — exact scope of "tear down phase X"
- §6.2 — TDD discipline on every bug, no exceptions
- §6.3 — full test bundle after every fresh `apply-and-verify`
- §6.4 — spawn adversarial subagents whenever drafting new tests
- §6.5 — repeat back compound prompts before acting
- §6.6 — **throughput-without-attention mode** (the previous session ran in this mode; the user's default expectation is stacked PRs, defensible assumptions, no idle waiting)

### Fallback: if the cluster is gone

If step 1 shows a different account ID or no `k8-platform-mgmt` cluster, you're starting from scratch:

1. Confirm `scripts/aws-creds-check.sh` finds a Route53 public hosted zone in the account. If not, **stop and escalate** — no code change provisions one.
2. `workflow_dispatch phase=base action=apply-and-verify` (waits for the base bootstrap script in CI to create the state bucket + lock table).
3. After green: `workflow_dispatch phase=management action=apply-and-verify` (~15 min).
4. Run the full test bundle per `AGENTS.md §6.3`.
5. Resume at step 2 of the normal path above to pick up phase 2a.

---

## Environment State

| Field | Value |
|---|---|
| Active phase | 2a (PlatformSecret) — code in git; live cluster activation pending `phase=management apply-and-verify` after #43 lands |
| Last update | 2026-05-23 — end of session that brought up phases 0+1 and authored phase 2a stack |
| AWS account | `309191981509` |
| Route53 zone | `309191981509.realhandsonlabs.net.` (id `Z0426781193AJAT8UDLZO`) |
| EKS cluster | `k8-platform-mgmt` in `us-east-1` |
| Cluster URL | `https://argocd.management.309191981509.realhandsonlabs.net` (HTTP 200 as of phase 1 verify) |
| State backend | s3 `k8-platform-tfstate-309191981509`, lock table `k8-platform-tfstate-lock` (both auto-bootstrapped by terraform-test.yml) |

### Phase states

| Phase | State | Last action | Run URL |
|---|---|---|---|
| 0 base | verified | 2026-05-23 apply-and-verify ✅ — 25 resources (VPC, IGW, NAT pair, subnets, route tables, ACM ISSUED, Cognito pool + test user) | https://github.com/lago-morph/k8-platform/actions/runs/26340162917 |
| 1 management | verified | 2026-05-23 apply-and-verify ✅ — EKS active, 2 nodes Ready, all 5 helm releases healthy, Kyverno policies applied, ArgoCD ingress + Route53 record live | https://github.com/lago-morph/k8-platform/actions/runs/26340615326 |
| 2 xrds | code-only → applied (after #41-#45 merge + `apply-and-verify`) | PRs #41 chainsaw-infra, #42 PlatformSecret XRD+Composition+ESO, #43 ArgoCD bootstrap, #44 extended tests, #45 handoff | — |
| 3 platform | not-coded | — | — |
| 4 observability | not-coded | — | — |
| 5 auth | not-coded (spec done in 2026-05-10) | — | — |
| 6 workload | not-coded | — | — |

### Live AWS resources you can `kubectl get` against right now

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

(This PR itself — `chore/session-wrap` — adds this very block.)

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

8. **Unit-test coverage audit — to be done IMMEDIATELY BEFORE starting phase 3.** The phase-2 verification on 2026-05-24 (integration-tests run 26347839740) silently reported PASS while four wait_for calls timed out; root cause was a class of bash bugs (`UID` shadowing + missing `set -e`) that no existing unit test would have caught — see PR `fix/integration-test-script-bugs` and the new `tests/unit/test_shell_readonly_var_assignment.sh` / `test_integration_scripts_strict_mode.sh` for the pattern. Several other failure modes encountered in this and earlier sessions (chainsaw condition-order non-determinism, dash-vs-bash pipefail in chainsaw `script` blocks, ESO webhook-cert harness regression, `crossplane-resources` OutOfSync, claim Ready=False on live cluster) likewise have no unit-test guard. **Scope of the audit (when started):** walk every PR retrospective and post-2026-05-23 CI failure, classify each as "a unit test would have caught this" / "no", and for the yes-rows author a focused lint. Goal is a measurable reduction in surprises during phase 3's live EKS-via-Crossplane work, where each iteration is ~15 min and a silent test failure costs far more than authoring the lint. Do NOT chase pure coverage metrics — author tests only where a real failure precedent exists.

---

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
