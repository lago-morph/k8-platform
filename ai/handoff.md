# Session Handoff — k8-platform

This file is the first thing a new session reads. It captures what was done
last, the current state, and the next concrete steps. Keep it factual
(AGENTS §8.3) and prune resolved items so the next session isn't misled.

---

## NEW SESSION QUICKSTART (read this first)

**Resume context: 2026-06-05, `auto-007` long-run (phases 3-6). PR #142 IS MERGED.
Live build on a fresh account 730335382332 (Route53 zone
`730335382332.realhandsonlabs.net.`). Verify the account is still live first
(`scripts/whereami.sh` / `aws sts get-caller-identity`) — it may rotate again.**

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
| Active phase | **auto-007: phases 0-1 VERIFIED live (runs 27035432871 / 27035617598); chainsaw dispatched; phase-3 cluster sync pending ArgoCD recovery. Next: auto-009 runbook.** |
| Last update | 2026-06-05 (auto-007 long-run, mid-session) |
| AWS account | **730335382332 this session — re-derive via `aws sts get-caller-identity` (may rotate, AGENTS §8.1)** |
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
