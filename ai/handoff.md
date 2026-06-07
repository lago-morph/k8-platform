# Session Handoff — k8-platform

This file is the first thing a new session reads. It captures what was done
last, the current state, and the next concrete steps. Keep it factual
(AGENTS §8.3) and prune resolved items so the next session isn't misled.

---

## NEW SESSION QUICKSTART (read this first)

> **[auto-011 — 2026-06-06/07 — SUPERSEDES auto-010 below.]** Full detail:
> `run-summary-auto-011.md` + `decisions/auto-011-*` + `retrospective/2026-06-…`.
>
> **⚠️ SAME INHERITED LIVE ACCOUNT `596430611165` (us-east-1). Phases 0/1 up.**
> Tools are NOT preinstalled in a fresh sandbox — install `aws` v2 + `argocd` (and
> `kubectl` is useless: kube-API is private-CA blocked; use the **`kube-diagnose`
> workflow** (`workflow_dispatch`, read-only script input) + the **ArgoCD REST API**
> (`/api/v1/applications/{app}/resource…` with the login token) for live kube reads).
>
> **What auto-011 did (all on branch `claude/k8-pods-phase-validation-7oqVK-k5sS4`):**
> - **#160 MERGED** — AppProject `k8-platform` now permits ClusterRole/Binding
>   (the ESO-RBAC manifest was blocking the whole `crossplane-resources` app).
> - **#161 MERGED** — added the shared **`ClusterProviderConfig/default` (IRSA)**
>   via GitOps (`crossplane/providerconfig/`); it was a manual bootstrap step
>   (SEG-1 §0c) never automated, absent on the rebuilt cluster, blocking ALL AWS MRs.
> - **#162 (MERGED 2026-06-07)** — XSpokeAccess XRD+Composition+spoke-access wiring
>   (phase-3 spoke AWS trust plane) + EnvironmentConfig `accountId`/`argocdRoleArn`
>   extension + provider-kubernetes (**v1.2.1**) install + the child-provider IRSA
>   fix + the SessionStart tools hook + run docs/retro. Its terraform was applied
>   live (`management apply-and-verify`, green) BEFORE merge.
>
> **✅ PHASE-3 CLUSTER IS LIVE.** The three blockers are all fixed and the platform
> cluster provisioned:
> - #160 AppProject RBAC; #161 ClusterProviderConfig/default (IRSA); **blocker #3
>   (child-provider IRSA) FIXED via Option A** — `runtimeConfigRef: aws-provider-config`
>   on all 6 child providers so their pods run under `upbound-provider-family-aws`
>   (the only subject the crossplane role trusts). Confirmed live: the eks provider
>   pod has `AWS_WEB_IDENTITY_TOKEN_FILE`; XR `Synced=True`.
> - **`provider-kubernetes` was failing** because the subagent guessed tag `v0.16.0`
>   which is NOT published to xpkg (404 MANIFEST_UNKNOWN) and predates Crossplane v2.
>   Bumped to **v1.2.1** (the v1.x line is the Crossplane-v2 series); now Healthy,
>   `providerconfig.kubernetes.crossplane.io/hub` created.
> - **Live now:** EKS `k8-platform-services` **ACTIVE**, node group **ACTIVE**,
>   `*.platform.596430611165.realhandsonlabs.net` ACM cert **ISSUED**, mgmt e2e-verify
>   all green (ArgoCD HTTP 200). The XR `Ready` may still show `Creating` briefly while
>   it aggregates the last MR condition — verify it flips to `Ready=True`.
>
> **IMMEDIATE NEXT STEPS — spoke registration (resume `decisions/auto-009-phase3-live-completion-runbook.md`):**
> 1. Confirm `crossplane-resources` synced the **XSpokeAccess XRD + Composition**
>    (now on main) and the **`spoke-access` Application** exists (manual-sync).
> 2. Read the cluster's live `oidcIssuer`:
>    `argocd`/ArgoCD-API → `XPlatformCluster.status.oidcIssuer` (or kube-diagnose).
>    Overlay it onto the XSpokeAccess XR (`clusters/platform/spoke-access/spoke-access.yaml`
>    spec.oidcIssuer is a placeholder), then `argocd app sync spoke-access` → creates
>    the OIDC provider + external-dns IRSA Role/RolePolicy + EKS AccessEntry on the spoke.
> 3. Build the **`platform-spoke` ArgoCD cluster Secret** from the EKS Cluster MR's
>    connection secret (endpoint+CA, aws/exec auth via the argocd role) — provider-kubernetes
>    + the `hub` ProviderConfig are installed for this. NOTE: provider-kubernetes Object
>    MRs need RBAC to write the Secret (same class as the ESO ClusterRole) — grant it.
> 4. Overlay spoke values (certArn/domain/region) → spoke apps converge (ingress-nginx →
>    external-dns → hello) → verify `https://hello.platform.596430611165.realhandsonlabs.net`
>    (200, valid ACM chain).
> 5. **Phase 5:** sync `keycloak-db` XDatabase XR; verify RDS + connection secret +
>    Keycloak. (xdatabase XRD now syncs — include-glob widened to `xrds/*`.)
>
> Open issues: `OI-2026-06-06-5` (child-provider IRSA — FIXED via Option A, keep the
> note as the rationale record), `OI-2026-06-06-3` (xdatabase `-master` secret orphan),
> `OI-2026-05-28-1` (claim-creates-secret flake).

> **[auto-010 — 2026-06-06 — SUPERSEDES the auto-009 block below.]** Full detail:
> `run-summary-auto-010.md` + `retrospective/2026-06-06-159/`.
>
> **⚠️ ACCOUNT IS INHERITED, NOT ROTATED.** Unlike the usual §8.4 assumption, the
> next session inherits the SAME LIVE account `596430611165` (us-east-1). **Phases
> 0 and 1 are already APPLIED and VERIFIED live — do NOT rebuild them.** Run
> `scripts/whereami.sh` first to confirm the account/cluster are still up, then
> proceed straight to phase 3. Work continues on branch
> `claude/k8-pods-phase-validation-7oqVK` (PR #159, open, NOT yet merged).
>
> Live state on the inherited account (run 27072048311):
> - **EKS `k8-platform-mgmt` ACTIVE, 3 nodes Ready**, full mgmt stack running
>   (ArgoCD, Crossplane + all providers **incl. provider-aws-rds**, ESO, Kyverno,
>   ingress-nginx, external-dns), all `policies/audit` applied.
> - **ArgoCD UI is REACHABLE**: `https://argocd.management.596430611165.realhandsonlabs.net`
>   (HTTP 200; admin password = `terraform/management` output `argocd_admin_password`,
>   read from S3 state `s3://k8-platform-tfstate-596430611165/k8-platform/management/terraform.tfstate`).
> - **maxPods → 110 DONE + proven** (AL2023 nodeadm node group up in 1m47s; eks.tf).
> - **Phase 4 COMPLETE**: hub Alloy via new `hub-addons` AppProject (Option A).
> - **Phase 5 COMPLETE (authored+tested)**: `XDatabase` XRD + RDS Composition +
>   `keycloak-db` wiring; provider-aws-rds INSTALLED on the cluster. Live RDS not
>   yet provisioned.
> - **6 real bugs fixed w/ regression tests** (run-summary §2): helm static-token
>   expiry → exec auth; Kyverno bare-CRD-kind → group-qualified; external-dns
>   `--aws-zone-match-parent`; mikefarah-yq glob `==` → `test()`; async-CRD
>   ordering (policy12↔RDS CRD); chainsaw real-AWS scenarios gated out of the
>   per-PR kind run.
>
> **IMMEDIATE NEXT STEPS (in order):**
> 1. `scripts/whereami.sh` — confirm account `596430611165` + cluster ACTIVE.
> 2. **Confirm phase-2 chainsaw green** on commit `fab6026` (run dispatched; real-AWS
>    scenarios excluded). If only `claim-creates-secret` flaked (OI-2026-05-28-1),
>    re-kick once. Then re-run the `chainsaw-verify` PR check so #159 goes green.
> 3. **Phase 3 LIVE** — ArgoCD is reachable, so follow
>    `decisions/auto-009-phase3-live-completion-runbook.md` end-to-end: argocd login →
>    sync `platform-cluster-claim` (platform EKS + ACM cert, ~20 min) → build the
>    XSpokeAccess composition (OIDC/IRSA/AccessEntry) → register the spoke → overlay
>    ephemeral values → verify `https://hello.platform.<domain>`.
> 4. **Phase 5 LIVE** — on the spoke, sync the `keycloak-db` XDatabase XR
>    (`platform-services/keycloak/database/keycloak-db.yaml`); verify the RDS
>    Instance + connection Secret; Keycloak consumes it. Or run a nightly real-AWS
>    chainsaw with `CHAINSAW_INCLUDE_REALAWS=1` to validate the RDS flow.
> 5. **Merge PR #159** once chainsaw-verify is green.
> - Sandbox tools: `aws`/`kubectl`/`helm`/`kubeconform`/mikefarah-`yq` installed;
>   kube-API is private-CA-blocked from the sandbox (use ArgoCD CLI / CI / AWS CLI).
> - Open issues: `OI-2026-06-06-3` (xdatabase `-master` secret orphan),
>   `OI-2026-06-06-4` (real-AWS chainsaw gating), `OI-2026-05-28-1` (claim-creates-secret flake).

> **[auto-009 — 2026-06-06 — SUPERSEDES the auto-007 block below.]** Full

> **[auto-009 — 2026-06-06 — SUPERSEDES the auto-007 block below.]** Full
> detail: `run-summary-auto-009.md` + `retrospective/2026-06-06-157.md`.
> Durable state now on `main`:
> - **Phase 3-6 GitOps stack landed** (#144-148): phase-3 spoke, phase-4
>   observability, phase-5 Keycloak, phase-6 workload1 (all scaffolding).
> - **The recurring crossplane provider-bootstrap deadlock is FIXED** (#156,
>   `OI-2026-06-06-2`): the explicit family Provider is now named
>   `upbound-provider-family-aws` (the child-dependency name) + `depends_on`
>   ordering + an idempotent orphan-cleanup + a one-Provider assertion.
>   Supersedes the partial OI-2026-06-05-3/4 fixes. Phases 0+1 are now
>   **reproducibly green** (confirmed live, run 27056287208).
> - **Decisions recorded** (`decisions/2026-06-06-phase4-alloy-phase5-db.md`):
>   phase-4 Alloy = Option A (`hub-addons` AppProject); phase-5 Keycloak DB =
>   general `XDatabase` XRD, RDS-backed.
> - **CI-red fixed** (#153, crossplane render `:stable` pin) + a working
>   `.github/workflows/*` write path via the jentic PAT / `ext-github`
>   Contents-PUT endpoint (the git/MCP path lacks `workflow` scope).
>
> **Next session** (account rotates per §8.4 — live mgmt cluster is gone):
> rebuild 0→1→2→3 on the fresh account (now reproducibly green), then build
> phases 4/5/6 LIVE — the `hub-addons` AppProject (convert
> `argocd/apps/spoke/observability-alloy-mgmt.yaml.todo`), the `XDatabase`
> XRD + RDS Composition for Keycloak's `keycloak-db`, and finish
> **maxPods/prefix-delegation** (nodes still cap ~17 pods) before the 4/5/6
> pod load. Open PRs to merge: #155 (envelope), #157 (this summary).

**Resume context: 2026-06-06 (`auto-007` — phase-3 provisioning push) on a LIVE
account (phases 0-1 already applied, management cluster up). Cleared FOUR phase-3
blockers; the `XPlatformCluster` XR reached `Ready=False/Creating` with 11 managed
resources composing before the AWS account was RESET (~02:30). Code is durable in
git; live AWS is gone. The auto-005 "rebuild 0→2" content further below still
applies on the fresh account.**

Branches/PRs from this session (NOT merged):
- **#149** `fix/management-argocd-cert-coverage` — the `*.management.<domain>` ACM
  cert (`acm-management.tf`) + ingress-nginx ssl-cert repoint, PLUS `node_min_size=3`
  and the VPC-CNI **prefix-delegation** addon (`eks.tf`).
- **#150** `docs/agents-never-remove-error-checks` — AGENTS §6.23 (never disable a
  check to dodge an undiagnosed error).
- **this PR** `chore/handoff-phase3-progress-2026-06-06` — render-fixtures exclude
  fix (`argocd/apps/crossplane-resources.yaml`) + this handoff.

### The FOUR phase-3 blockers found + fixed this session

1. **ArgoCD unreachable from sandbox — cert SAN gap (the "directly reachable" note
   below was WRONG).** The base wildcard `*.<acct>.realhandsonlabs.net` covers only
   ONE label, so NOT the two-label host `argocd.management.<acct>…`. The sandbox
   egress is an Anthropic MITM gateway doing STRICT upstream SAN verification → 503
   "verify SAN list", refused to proxy. FIX (#149): a dedicated `*.management.<domain>`
   ACM cert on the ingress NLB. After it landed, `argocd login` from the sandbox works.
2. **`kubectl` from the sandbox is STRUCTURALLY blocked.** The same gateway can't
   verify the EKS API's **private-CA** serving cert on the upstream leg (`unable to
   get local issuer certificate`) → every kube-API call 503s. Trusting the gateway
   CA fixes the CLIENT leg only. Use the **`argocd` CLI** (via the public NLB) + the
   **AWS CLI** for all sandbox-side diagnostics; kube-API needs CI.
3. **ingress-nginx admission-webhook hook timeout = pod-IP exhaustion, NOT mem/CPU.**
   Both t3.medium nodes were at 3/3 ENIs, 18/18 IPs (max-pods ~17), CPU idle 5-7% —
   diagnosed via AWS CLI ENI/IP counts (kube-API blocked). The certgen hook Job
   couldn't get an IP → couldn't schedule → helm hook timed out (and a taint-driven
   recreate DESTROYED ingress-nginx, taking ArgoCD down until restored). FIX (#149):
   `node_min_size=3` (the eks module IGNORES `desired_size`, so `min_size` is the
   lever; AWS rejects `min>desired`, so scale `desired`→3 via
   `aws eks update-nodegroup-config` FIRST) + the prefix-delegation addon. Restored
   to 3 healthy nodes; cert fix confirmed (`argocd login` OK).
4. **`crossplane-resources` app couldn't sync → XRDs never installed.** SPEC-S9
   `render-fixtures/{input,expected}.yaml` under `crossplane/xrds/platform-*/` were
   swept into the synced path, so each `render-probe-*` XR appeared TWICE → invalid
   sync → nothing applied. UNBLOCKED live by syncing only the XRDs+Compositions
   (`argocd app sync crossplane-resources --resource …`); DURABLE fix in this PR
   (`exclude: '**/render-fixtures/**'`). Then `argocd app sync platform-cluster-claim`
   applied the XR and Crossplane began provisioning (11 MRs). A
   `cluster-cert-validation-record` ReconcileError was transient ordering (waits on
   the cert's DNS-validation CNAME).

### Terminology + a half-done follow-up
- It's an **`XPlatformCluster` XR**, not a "claim" (Crossplane v2 has no claims —
  AGENTS §12.1). `platform-cluster-claim` is only the (v1-era) ArgoCD-app/file name.
- **prefix delegation is HALF done:** #149 adds the ADDON but NOT the kubelet
  `maxPods` bump (nodes still cap ~17). TRAP: `enable_bootstrap_user_data=true`
  emitted **AL2 `/etc/eks/bootstrap.sh`** user-data — WRONG for the AL2023 AMI, no
  `maxPods` — which would have failed node bootstrap and downed the cluster (caught
  by plan + user-data DECODE, not applied). To finish: pin
  `ami_type=AL2023_x86_64_STANDARD`, re-plan, DECODE the LT user-data to confirm
  nodeadm-format `maxPods: 110`, THEN apply (node recycle). 3×17≈51 slots suffices
  without it.
- **`crossplane render` CI breakage** (`unexpected argument internal`) fails
  `test_composition_render_fixtures.sh` on every push — ENVIRONMENTAL (crossplane CLI
  version), unrelated to any change here; needs its own pin fix (log to open-issues).

> Earlier-snapshot note (PR #145 / 2026-06-05 framing, retained): this branch is
> the phase-3 spoke GitOps foundation. PR #142 was merged; the live build ran on a
> rotated account. Verify the account is still live first (`scripts/whereami.sh` /
> `aws sts get-caller-identity`) — it may rotate again.

This session (auto-007) rebuilt the stack live and started phase 3:

| Phase | Live result | Evidence |
|---|---|---|
| 0 base | apply-and-verify GREEN | run 27035432871 |
| 1 management | apply-and-verify GREEN — EKS `k8-platform-mgmt` ACTIVE, ArgoCD + Crossplane + providers + ESO + Kyverno + IRSA | run 27035617598 |
| 2 xrds | chainsaw dispatched (run on `534a0ce`) — check conclusion | chainsaw.yml |
| 3 cluster | **NOT yet synced** — blocked on ArgoCD 503 (see below) | — |

**Open in-flight (auto-007):** PRs #144 (trunk/envelope), #145 (phase-3 spoke
GitOps foundation, CI-green locally), + phase 4/5/6 scaffolding branches
(subagent-authored). Merge order in the run summary.

**Immediate next step — finish phase 3 live:** follow
`decisions/auto-009-phase3-live-completion-runbook.md` step-by-step (sync
`platform-cluster-claim` via ArgoCD → platform EKS + ACM cert → XSpokeAccess MRs
→ spoke registration → verify `https://hello.platform.<domain>`). The runbook has
the exact MR manifests (from the auto-008 R1/R2 adversarial review).

**ArgoCD 503 note (auto-007):** mgmt apply-and-verify passed WITH an ArgoCD
HTTPS-200 check (~19:45Z), but ArgoCD went 503 minutes later (argocd-server
settling after the app-of-apps sync). If still 503 on resume: re-poll
`https://argocd.management.<domain>/healthz` until 200, or dispatch
`phase=management action=verify` to force a CI-side re-check. Do NOT sandbox-kubectl
the EKS API (private CA — blocked from the sandbox; use ArgoCD/CI).

⚠️ Per AGENTS §8.4 a rotated account is FRESH+EMPTY. The CODE is durable in git;
live AWS resources are not. Re-verify with the live API before assuming.

### What this session proved (durable evidence — the code WORKS on a fresh account)

Built phases 0→2 live on a fresh account this session (before it expired):

| Phase | Result | Evidence |
|---|---|---|
| 0 base | apply-and-verify GREEN | run 27021589131 |
| 1 management | apply-and-verify GREEN — EKS cluster ACTIVE, 2 nodes, ArgoCD UI HTTPS 200 (ExternalDNS Route53 record), Crossplane + all providers + ESO + Kyverno + IRSA + cluster-network EnvironmentConfig | run 27024349261 |
| 2 xrds (chainsaw) | 4/6 scenarios PASS (`claim-creates-secret`, `claim-rotation`, `xrd-establishes`, smoke); 2 FAIL on the known OI-2026-05-28-1 flake | run 27024518071 |

Phase 1 surfaced **3 real bugs** on the fresh account, all FIXED on PR #142
(these are why #142 must merge before the next rebuild):
- **OI-2026-06-05-2** — `charts.crossplane.io` 403s the GitHub runner. Fixed by
  vendoring the digest-verified chart at
  `terraform/management/vendor/crossplane-2.3.0.tgz`; both `helm.tf` and
  `tests/chainsaw/run.sh` install from it.
- **OI-2026-06-05-3/4** — `terraform_data.crossplane_aws_provider` raced the
  package manager and used a by-label selector the v2.5.0 family-provider
  Deployment doesn't carry. Fixed: wait for the Provider to be `Healthy`, then
  a label-agnostic SA-readiness check + diagnostics dump.

### Immediate next steps (in order)

1. **Merge PR #142 to main.** It carries the 3 phase-1 fixes (required for a
   clean rebuild) plus the ASM-cleanup fix, the unit-suite SIGPIPE-flake fix,
   AGENTS §8.5/§8.6, and the session plans/briefs. ArgoCD tracks `main`, so the
   fixes must be on main for the live build.
2. **Rebuild phase 0→1→2 on the fresh account** via CI (the fixes are now in):
   - `terraform-test.yml phase=base action=apply-and-verify`
   - `terraform-test.yml phase=management action=apply-and-verify` (the 3 bugs
     above are fixed; expect it to complete)
   - `chainsaw.yml` full set. If `composition-drift` / `claim-deletion-cleanup`
     time out on the ResourceExistsException flake (OI-2026-05-28-1 Issue A),
     re-kick once — established remedy.
3. **Phase 3 — provision the platform cluster.** The agent drives the
   `platform-cluster-claim` sync directly from the sandbox via the ArgoCD
   Terraform-output credential — see **Phase-3 sync** below (manual-sync stays).
4. **Phase 3 spoke (REQ-PLAT-02/03/04/06)** — build LIVE per the full execution
   plan in `decisions/auto-005-session-plan.md` (spoke registration, ingress-nginx
   with the cross-cluster cert ARN, ExternalDNS + spoke OIDC/IRSA, hello app,
   ApplicationSet; verify `https://hello.platform.<domain>`).

### Phase-3 sync — the AGENT drives it; manual-sync STAYS

`platform-cluster-claim` **stays manual-sync** (don't flip it to auto — an
everyday push must never kick off a real EKS-cluster provision). The agent
performs that manual sync **itself**, with no human and no new CI workflow:

1. The ArgoCD admin credential is created **at install time** and exposed as
   Terraform outputs (AGENTS §10.1): `argocd_admin_password` (sensitive) +
   `argocd_server_url` = `https://argocd.management.<domain>`. Get them from the
   `terraform/management` outputs.
2. ArgoCD is **internet-facing** (the NLB at `argocd.management.<domain>`, with a
   publicly-trusted ACM cert) and **the sandbox has permissive network egress**,
   so call the ArgoCD API **directly from the sandbox** — no CI proxy, no kube-API
   access needed:
   `argocd login "$argocd_server_url" --username admin --password "$argocd_admin_password" --grpc-web`
   then `argocd app sync platform-cluster-claim` (and `argocd app wait ...`).

Crossplane then provisions the platform EKS cluster + `*.platform.<domain>` ACM
cert (~20 min). Verify `status.certificateArn` + `CertificateValidation` Ready.

> **The thing sessions keep missing:** a service you *installed* that exposes a
> public endpoint is reachable **directly from the sandbox**. Create the
> credential at install time (done — it's a Terraform output) and call the API
> directly. Don't treat ArgoCD as "CI-only / unreachable" and don't hunt for a
> sync workflow. (Only the EKS *kube-API* — private CA — and reading TF state /
> AWS APIs without creds genuinely need CI.)

**Pre-check before syncing:** `provider-aws-eks` and `provider-aws-route53` were
still `HEALTHY=False` at 14m this session — confirm they reach Healthy (the
cluster XR needs them).

To CHECK AWS creds, dispatch a workflow (AGENTS §8.5) — do not assume stale.

---

## Environment State

| Field | Value |
|---|---|
| Active phase | **Account RESET 2026-06-06 (auto-007). Phase-3 XR provisioning was reached LIVE (11 MRs composing) then wiped. Nothing live now. Next: rebuild 0→1→2 (merge #142 + #149 + #150 + this PR), then phase-3 sync — the 4 blockers in QUICKSTART are all fixed. Phases 0-1 had VERIFIED live earlier (runs 27035432871 / 27035617598); auto-009 runbook drives phase-3.** |
| Last update | 2026-06-06 (auto-007 — phase-3 blockers cleared) |
| AWS account | **ephemeral — derive from `aws sts get-caller-identity`** (AGENTS §8.1) |
| Route53 zone | `<account-id>.realhandsonlabs.net.` |
| EKS cluster | `k8-platform-mgmt` in the region from `$AWS_REGION` |
| State backend | s3 `k8-platform-tfstate-<account-id>`, lock table `k8-platform-tfstate-lock` |

### Phase states

State semantics: `code-only` = never applied on THIS (fresh) account; `applied`
= applied this session; `verified` = applied AND probed. Cross-session
`applied`/`verified` are NOT durable (AGENTS §8.1) — treat all as `code-only`
on the next account until the live API proves otherwise.

| Phase | Code state | Last live result (account now gone) |
|---|---|---|
| 0 base | complete (main) | VERIFIED — run 27021589131 |
| 1 management | complete; **fixes on #142 (merge first)** | VERIFIED — run 27024349261 |
| 2 xrds | complete (main) + chainsaw vendored-chart fix on #142 | 4/6 chainsaw — run 27024518071 (2 known-flake fails) |
| 3 cluster+cert | complete (main, PR #140) | not applied — blocked on phase-3 mechanism |
| 3 spoke | not started | REQ-PLAT-02/03/04/06 — plan in decisions/auto-005-session-plan.md |

### Live AWS resource shape (when applied)

```
EKS cluster name:   k8-platform-mgmt
IRSA role names:    k8-platform-mgmt-{argocd,crossplane,eso,external-dns}
                    crossplane trust subject:
                      system:serviceaccount:crossplane-system:upbound-provider-family-aws
Route53 zone:       <account-id>.realhandsonlabs.net.
ACM wildcard cert:  *.<account-id>.realhandsonlabs.net (base) ; *.platform.<...> (platform cluster)
ASM secrets:        k8-platform/<XR-uid>
```

Run `scripts/whereami.sh` first to confirm the account (AGENTS §8.1).

---

## Open follow-ups (roughly prioritized)

1. **Merge PR #142** (see QUICKSTART step 1) — unblocks the rebuild.
2. **Phase-3 sync** (QUICKSTART) — agent runs `argocd app sync platform-cluster-claim`
   directly from the sandbox using the §10.1 Terraform-output cred; manual-sync stays.
3. **OI-2026-05-28-1 Issue A** (ASM `ResourceExistsException` flake on
   `composition-drift`/`claim-deletion-cleanup`): durable fix is the
   `crossplane.io/external-name` change in `decisions/auto-006-asm-external-name-fix.md`
   (Round-1 brief written; needs render-golden regen + live chainsaw to confirm
   the external-name format upjet expects). Until then, re-kick clears it.
4. **Unit-test coverage audit** — content audit for missing contracts (the
   §6.16 run.sh↔unit-tests.yml wiring is already satisfied via the catch-all).
5. **Rename surviving v1-era `*-claim` artifacts to `*-xr`** (AGENTS §12.1):
   `clusters/platform/platform-cluster-claim.yaml`, the ArgoCD Application
   `platform-cluster-claim`, the `claim-*` chainsaw scenario dirs. Own small PR.
6. **Orphaned chainsaw ASM secrets:** the cleanup sweep can't delete secrets
   whose MR is already gone at trap time; chainsaw runs may leave `k8-platform/<uid>`
   secrets in the account (different uids, so no collision). Minor.

See `docs/open-issues.md` for the full register (OI-2026-05-28-1,
OI-2026-06-05-1/2/3/4).

---

## Critical behavioral rules

| Action | Evidence to check |
|---|---|
| `terraform apply` on management | Look for `Plan: N to add`. Zero changes after a manifest edit = `triggers_replace` missing a hash. See `docs/runbooks/runbook-apply-zero-resources.md`. |
| Provider SA (IRSA) | The v2.5.0 family-provider Deployment is NOT labelled `pkg.crossplane.io/provider=provider-family-aws` (OI-2026-06-05-4). Verify by pod: `kubectl -n crossplane-system get pods -o jsonpath='{range .items[*]}{.spec.serviceAccountName}{"\n"}{end}'` must include `upbound-provider-family-aws`; the SA object must exist. |
| IRSA trust | `aws iam get-role --role-name k8-platform-mgmt-crossplane --query 'Role.AssumeRolePolicyDocument'` |
| XR Ready | `kubectl wait --for=condition=Ready --timeout=180s ...` is the unambiguous signal. |
| ArgoCD app | `kubectl get application <name> -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}'` must be `Synced/Healthy`. |

---

## Key Design Decisions

| Decision | Choice | Why |
|---|---|---|
| Multi-cluster pattern | Hub-spoke via ArgoCD | Management cluster manages all others |
| Cluster provisioning | Crossplane XRDs (v2 namespaced XRs) | Self-service composites |
| Secret distribution | ESO + AWS Secrets Manager | Single source of truth |
| TLS | Per-cluster DNS-validated ACM cert provisioned by the cluster Composition + NLB termination (no cert-manager/ACME) | docs/decisions/0003 |
| Ephemeral inputs (subnets/zone/domain) | `cluster-network` EnvironmentConfig materialized from base Terraform outputs | docs/decisions/0003, ADR-e557a40123 |
| State backend | S3 + DynamoDB | Standard; auto-bootstrapped by CI |
| Instance sizing | `t3.medium` × 2 | Fits within 9-instance EC2 quota |
| Crossplane chart source | vendored tarball, not charts.crossplane.io | CDN 403s the runner (OI-2026-06-05-2) |

---

## Scripts inventory

| Script | One-liner |
|---|---|
| `scripts/whereami.sh` | One call for account, region, EKS, zone, kubectl ctx, ArgoCD URL, Crossplane version (SPEC-S4). |
| `scripts/irsa_trust_validator.py` | IRSA fleet sweep — `--all --ci` for gating, `--role <arn>` for triage (SPEC-S3). |
| `scripts/composition-render.sh` | SPEC-S9 author-time `crossplane render` dry-run vs committed golden. |
| `scripts/pre-chainsaw-audit.sh` | Static audit before any `chainsaw.yml` dispatch (AGENTS §6.13). |
