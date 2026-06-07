# Session Handoff — k8-platform

This file is the first thing a new session reads. It captures what was done
last, the current state, and the next concrete steps. Keep it factual
(AGENTS §8.3) and prune resolved items so the next session isn't misled.

---

## NEW SESSION QUICKSTART (read this first)

> **[auto-013 — 2026-06-07 — SUPERSEDES auto-012 below.]** Full detail:
> `overnight-summary.md` (root) + `retrospective/2026-06-07-177/` + PRs #170–#177.
>
> **Run goal:** EXECUTE the test overhaul per `planning/test-overhaul/FINAL-PLAN.md`.
> This run shipped the **P1 static scaffold** as 7 stacked implementation PRs
> (#171–#176, on trunk #170) and brought the substrate up live on the fresh
> account `695454131301`.
>
> **✅ Substrate is LIVE on `695454131301`:** phase-0 base (run 27085405081) and
> phase-1 **management apply-and-verify GREEN** (run 27085571769) — EKS
> `k8-platform-mgmt` ACTIVE, ArgoCD + Crossplane + all providers + ESO + Kyverno +
> IRSA up, mgmt e2e-verify passed. Phase-3 platform cluster NOT yet synced.
>
> **What auto-013 built (all cluster-INDEPENDENT, hermetically unit-tested):**
> 1. **#171** `mgmt_live_verify` derived gate — any mgmt apply ⇒ live verify (§4.1).
> 2. **#172** Pipeline-mode coverage deriver + byte-identical fixture test (§4.5);
>    extractor reproduces the 14-kind oracle exactly; drift gate ENFORCE.
> 3. **#173** inverted-skip live orchestrator `tests/live/run.sh` (§4.4): all-skip⇒RED,
>    expect-full-from-git, exit-code contract, LIVE_PROFILE/LIVE_MODE.
> 4. **#174** FAIL-closed live-evidence gate (§4.3, round-3 centerpiece) — logic +
>    config-only-trigger; profile re-arming; 17 hermetic assertions.
> 5. **#175** scoped zero-wildcard verifier/reaper IAM role + K=0 ceiling lint (§3.4).
> 6. **#176** SKIP_REGISTER lint — attributable, time-boxed disables (§4.6).
>
> **CARRIED FORWARD (NOT done — see overnight-summary.md §Morning-review + §NOT-done):**
> - **P0 SPIKE live confirmation** — read-only probe dispatched via `kube-diagnose`
>   (source:IRSA, no-static-creds, provider health, v2 composed-ref field). The
>   "drive a claim ⇒ real AccessDenied" half needs a provisioned cheap XR + a
>   crippled-twin grant removal; carried forward. **The P1 scaffold is built to the
>   plan's documented assumptions; confirm the spike before merging P4 behavioral code.**
> - **The jentic workflow integration capstone** (wire `tests/live/run.sh` into
>   `terraform-test.yml`'s apply-and-verify job gated on `mgmt_live_verify`, under
>   the scoped role; emit the clean-pass evidence artifact; wire the live-evidence
>   gate + the static wired/gating/scoped/on-by-default lints into a push workflow).
>   DEFERRED deliberately: it edits the live bring-up flow and must be
>   dispatch-validated before merge — do not land it unvalidated.
> - **P2–P6** (deepen after-the-fact, isolation/reaper, instantiate-and-verify,
>   negatives + spoke trigger, hardening) — not started.
> - **Stand up the verifier/reaper role + mutex table live** on the next mgmt apply
>   (the #175 terraform is committed but not yet applied).
>
> **Owner decisions (FINAL-PLAN §14, pre-answered in the run brief — resolutions in
> overnight-summary.md):** #1 scoped verifier/reaper role = built (#175); #2 spoke
> CIDR/AccessEntry = confirm at spike time (carried); #3 tighten `Resource:"*"` =
> recommend, ship deny tests with it in P4 (carried); #4 ArgoCD controller
> `role_policy_arns={}` = confirmed present at `terraform/management/irsa.tf`
> (module.irsa_argocd) — investigate if spoke registration needs a policy (carried).

---

### ⏭ NEXT PHASE (proposed, assessed-feasible, NOT yet implemented) — give the sandbox direct `kubectl`

**Sequence.** This is the **immediate next focused session** — full build spec in
[`planning/sandbox-kubectl-access-task.md`](../planning/sandbox-kubectl-access-task.md).
Do it **first**: direct `kubectl` makes finishing the P0 spike and building the
behavioural test layers much easier. **As soon as it is done, kick off the
test-strategy continuation** — the auto-013 "CARRIED FORWARD" items above (finish
the P0 spike: `spec.crossplane.resourceRefs` on a live XR + drive-a-claim ⇒ real
`AccessDenied`; the jentic workflow-integration capstone; then P2–P6). The two are
sequential, not parallel.

**Goal.** Let this sandbox run `kubectl` against the cluster API directly, instead of
going through the `kube-diagnose` CI workflow + the ArgoCD REST API for every live
read. Tighter inner loop. Wanted **for every cluster we create** (hub + spokes), so
the plumbing belongs in the `XPlatformCluster` Composition, not a one-off on the hub.

**Why it's blocked today (the real constraint, confirmed against our config).** Our
EKS endpoints are *already public* (`cluster_endpoint_public_access = true` on the
hub in `terraform/management/eks.tf`; `endpointPublicAccess: true` in the cluster
Composition). So network reach is **not** the problem. TLS is: the Anthropic egress
gateway verifies the *upstream* server certificate against **public** roots, and the
EKS API server always presents a cert signed by the cluster's **private** CA → every
direct kube-API call 503s. (Trusting the gateway's own MITM CA fixes only the
sandbox→gateway leg; the gateway→EKS leg still fails.) This is the exact reason
ArgoCD needed a public ACM cert on its NLB before the sandbox could reach it.

```mermaid
flowchart LR
    SB[Sandbox kubectl] --> GW[Egress gateway checks cert vs public roots]
    GW -. blocked: EKS serves a private-CA cert .-> EKS[EKS API server]
    GW --> FRONT[Public-cert front: ACM proxy or SSM tunnel]
    FRONT --> EKS
    classDef bad fill:#f8d7da,stroke:#cc3333;
    classDef good fill:#cde6cd,stroke:#33aa66;
    class EKS bad;
    class FRONT good;
```

#### The two approaches, assessed

**Approach B — give each cluster's API a publicly-trusted cert (the preferred
option): NOT FEASIBLE on EKS.** The API-server serving certificate is part of the
AWS-managed control plane. EKS exposes no knob to replace it with an ACM/public
cert, and no way to attach a custom domain to the managed `*.eks.amazonaws.com`
endpoint. Making the endpoint public (already done) does not change the cert. The
only way to present a publicly-trusted cert for the kube API is to put something *in
front* of it — which is Approach A. (A self-managed control plane — kops/kubeadm —
could set the apiserver cert, but moving off managed EKS is a non-starter.)

**Approach A — a non-cluster AWS resource that fronts the API with a public cert:
FEASIBLE.** The pattern is already proven by ArgoCD, and two building blocks for
"all clusters" already exist: the per-cluster DNS-validated **ACM cert the
Composition already mints** (`*.platform.<domain>` + its `CertificateValidation`)
and the Route53 zone. The catch is *which* front-end: `kubectl` is not only
request/response — it also does long-lived watches and **bidirectional connection
upgrades** for `exec`/`port-forward`/`attach` — so the choice decides how much of
kubectl actually works.

| Front-end (non-cluster AWS resource) | Public-cert source | kubectl coverage | Compute footprint | Main risk |
|---|---|---|---|---|
| **Lambda function URL** (the example given) | auto AWS public cert | plain CRUD only (`get`/`apply`/`delete`); **`exec`/`port-forward` break**; 15-min + payload caps | serverless | streaming/upgrade limits make it a partial kubectl |
| **NLB with a TLS listener** (ACM public cert) → EKS endpoint | our ACM cert | **full kubectl** (L4 passthrough forwards the raw stream, so HTTP/2 + websockets + SPDY all work) | none (pure AWS resource) | the EKS endpoint is AWS-managed IPs behind a DNS name; NLB targets are IPs → needs an IP-refresh mechanism |
| **Small reverse proxy** (nginx/haproxy on Fargate) behind NLB+ACM | our ACM cert | full kubectl, proxies by DNS (no IP problem) | a small standing service (still non-cluster) | one always-on component to run/patch |
| **SSM Session Manager port-forward tunnel** (not named, strong) | the AWS `ssmmessages` endpoint's public cert | **full kubectl** — raw TCP tunnel; kubectl does real end-to-end TLS to the apiserver and **verifies the real cluster CA, no cert substitution** | a tiny SSM-registered instance per VPC | does the egress gateway permit the SSM data-channel **websocket**? (short `aws` calls already pass; a long-lived websocket is untested) |

#### Recommendation (this is opinion, not a settled decision)

Two finalists. If you want **zero standing compute** and only need CRUD-ish kubectl,
the **NLB TLS-passthrough** is the cleanest pure-AWS-resource path — but solve the
IP-target refresh. If you want **full kubectl** (`exec`/`port-forward`/`logs -f`)
with the least cert fuss, the **SSM port-forward tunnel** is the most elegant
(kubectl verifies the real cluster CA; nothing internet-facing is added) — but it
must pass a one-time gateway-websocket test first. Lambda is the weakest finalist
(no `exec`/`port-forward`).

#### Validate before building it "for all clusters"

First step is a **throwaway proof on the existing hub** that the chosen mechanism's
TLS/handshake passes the egress gateway and that `kubectl get nodes` returns —
*before* wiring it into the Composition. For SSM: stand up one SSM-managed instance,
try `aws ssm start-session ... AWS-StartPortForwardingSessionToRemoteHost
host=<eks-endpoint> portNumber=443 localPortNumber=8443` from the sandbox, point
kubeconfig at `https://localhost:8443`. For NLB: one NLB + the ACM cert + a target
group at the hub endpoint. The gateway-websocket question is the single thing that
decides SSM-vs-NLB, so test it first.

#### Needed regardless of mechanism

- **Auth.** kubectl still needs a valid token: the sandbox has AWS creds, runs
  `aws eks get-token`, and the cluster needs an **EKS access entry** for the
  sandbox's IAM identity (`user/cloud_user`) with read RBAC — the same access-entry
  work already tracked for the CI identity (FINAL-PLAN §14.2 / owner-decision #2).
- **Security tradeoff.** A public-cert proxy adds an internet-facing kube-API
  surface — restrict it with the EKS public-access CIDR allowlist (to the gateway
  egress IPs, if they're stable) on top of IAM/access-entry auth. The **SSM tunnel
  adds no public listener** (IAM-gated, nothing inbound) — strictly better on this
  axis, another point in its favour.
- **"For all clusters."** Fold the chosen resource into the `XPlatformCluster`
  Composition next to the ACM `Certificate` it already provisions, so every hub and
  spoke gets it automatically.

#### Effort (descriptive, not hours)

Approach B is ruled out, so no work there. Approach A is a small, self-contained
build on top of existing AWS primitives plus the ACM cert the Composition already
mints: the **SSM-tunnel** variant is mostly configure-existing (one SSM instance +
IAM + a kubeconfig helper); the **NLB** variant is mostly AWS wiring plus the
IP-refresh wrinkle. The gateway-websocket spike that picks between them is a single
short throwaway test.

**If A's validation fails** (gateway blocks the SSM websocket *and* the NLB
IP-target proves too fragile): keep today's working path — `kube-diagnose` workflow
for kube reads + the ArgoCD REST API — and treat direct sandbox kubectl as
not-worth-the-cost.

---

> **[auto-012 — 2026-06-07 — SUPERSEDES auto-011 below.]** Full detail:
> `run-summary-auto-012.md` + `docs/open-issues.md` (OI-2026-06-07-1..5) + PR #165.
>
> **⚠️ AWS ACCOUNT EXPIRED — the `596430611165` account auto-012 ran on is GONE.**
> The next session gets a FRESH account (normal §8.4 rotation): all auto-012 LIVE
> state (the spoke cluster, the ArgoCD spoke registration, the RDS instance, the
> out-of-band IAM/SG/subnet changes) is destroyed. **What survives is the CODE in
> PR #165** (durable fixes + tests). The next session REBUILDS 0→1→3→5 on the fresh
> account; because PR #165's fixes are in the code path, the 8-link blocker chain
> below will not recur. Reminders: kube-API is private-CA blocked from the sandbox —
> `kube-diagnose` workflow (read-only) + AWS API for reads; the **in-cluster ArgoCD
> server** (REST `/api/v1/clusters`, `argocd app sync/patch-resource`,
> `argocd app actions run … restart`) + terraform apply for writes; NEVER sandbox
> kubectl (AGENTS §6.26/§6.27 + retro 2026-06-07-165 AGENTS-MD-66a8a93ecf).
>
> **PR #165 status:** OPEN at account expiry; carries all 8 durable fixes + tests.
> The chainsaw-verify gate was mid-dispatch when the account died — on the fresh
> account, re-dispatch `chainsaw.yml` for HEAD, confirm green, then merge so the
> rebuild includes the fixes.
>
> **What auto-012 did (PR #165, branch `claude/k8s-platform-phase3-5-m9evX`):**
> The inherited "just finish spoke registration" was understated — phase-3 had an
> 8-link chain of failing-closed blockers, all now fixed (durable code + live):
> 1. spoke EKS `authenticationMode` CONFIG_MAP→**API_AND_CONFIG_MAP** (AccessEntries).
> 2-3. crossplane IAM policy missing `iam:Tag/UntagOpenIDConnectProvider`,
>    `iam:UpdateAssumeRolePolicy`, `iam:GetRolePolicy` (live policy v2→v3).
> 4. hub→spoke EKS-API **security-group** ingress 443 (mgmt node SG → spoke cluster SG).
> 5. ArgoCD **application-controller SA** was missing the IRSA role-arn annotation
>    (only server had it) → all spoke syncs failed `argocd-k8s-auth exit 20`. Fixed
>    in `helm.tf` + applied (mgmt apply 27078501716).
> 6. `platform-spoke` AppProject missing cluster-scoped `IngressClass`.
> 7. shared-VPC ELB **subnets** not tagged `kubernetes.io/cluster/k8-platform-services`
>    → spoke cloud-provider couldn't place the ingress NLB. Tagged live.
>
> **(auto-012 verified end-to-end on the now-expired account before it died:**
> spoke registered, XSpokeAccess Ready=True, `https://hello.platform.<domain>` → 200
> with the ACM wildcard chain, RDS `available` + `keycloak-db` connection Secret
> published. That live proof is gone with the account; the rebuild reproduces it.)
>
> **DECISIONS RECORDED (apply these in the rebuild):** ADR
> `docs/decisions/0005-eso-for-lightweight-secrets-xplatformsecret-for-aws-grade.md`
> — ESO (`PushSecret`+`ExternalSecret`, `generatorRef`) is the default for secret
> movement/generation in EVERY cluster; `XPlatformSecret` is reserved for
> AWS-resource-grade secret management (KMS/replica/policy/tags); **do NOT retrofit
> working XPlatformSecret usages** (forward-looking only). OI-2026-06-07-1..5
> resolutions are folded into the tasks below.
>
> **═══ EXPLICIT TASKS FOR THE NEW SESSION (run AFTER the fresh AWS account is up) ═══**
>
> **⚠️ TEST DISCIPLINE — READ FIRST, APPLIES THROUGHOUT (OI-2026-06-07-6).** A static
> `yq`/`grep` assertion is a LINT, not a test — it never catches "we told the platform
> to create X but X was never actually created / doesn't work." That blind spot caused
> ALL 8 auto-012 blockers (found live, serially, only when a dependent tripped). So:
> **verify what you built, at the moment you build it — every time, coupled to the
> change, NOT on a schedule.** Every create step (claim/XR, IAM role/policy, helm
> release, ConfigMap/Secret, ArgoCD cluster registration, DNS record) is immediately
> followed — as part of that same step — by a real-cloud/cluster existence+function
> check against the REAL cluster (real Crossplane under the real IRSA role), using the
> `crossplane-claim-verify` skill at every claim and AWS-API / ArgoCD-API checks for
> the rest. If the resource didn't actually build, the step is NOT done. A static
> `yq`/`grep` "unit test" is a lint, not a test of behaviour; a green kind chainsaw is
> a syntax/render pre-flight, NOT evidence the thing builds. Do NOT defer real
> verification to a "nightly" or a gate that runs later — that decoupling is the bug
> that caused all 8 auto-012 blockers. Also add a hub→spoke integration test
> (provision→register→hello 200→Keycloak-on-RDS) and close the `[mgmt] e2e-verify`
> gaps (BOTH ArgoCD SAs, spoke registration, subnet tags, SG reachability). See
> OI-2026-06-07-6 for the full rationale.
>
> Do these in order; (1) gates everything else.
> 1. **Bring up the fresh account + merge PR #165.** Rebuild phases 0→1, then the
>    phase-3 cluster. Re-dispatch `chainsaw.yml` for PR #165 HEAD, confirm green,
>    merge #165 (its 8 fixes are prerequisites for a clean spoke bring-up).
> 2. **OI-2026-06-07-2 — make per-cluster facts + ESO part of the cluster XRD.**
>    Extend the **`XPlatformCluster`** abstraction (XRD/composition + its
>    provisioning path) so every cluster it creates ships:
>    (a) a **per-cluster ConfigMap** carrying cluster facts (domain, region, ACM cert
>        ARN, external-dns role ARN) that the add-ons read FROM — stop threading
>        these through per-app Helm `valuesObject` overlays;
>    (b) an **ESO install + IRSA-backed `ClusterSecretStore`** (AWS Secrets Manager)
>        on the cluster. ESO is a baseline component in EVERY cluster (hub + spokes),
>        not hub-only (ADR 0005).
>    Then rework `spoke-*` apps to source those values from the ConfigMap; make the
>    `hello` workload AWS-agnostic (no ARNs/region — at most a hostname from the
>    ConfigMap). This removes the bootstrap-selfHeal-vs-overlay conflict entirely, so
>    bootstrap stays fully auto-sync/self-heal (no pausing).
> 3. **OI-2026-06-07-1 — `platform-spoke` ArgoCD cluster Secret via plain ESO.**
>    Enable the EKS Cluster MR's connection secret → ESO `PushSecret` → Secrets
>    Manager → `ExternalSecret` with `target.template` assembling the cluster-secret
>    `config` (caData-in-JSON). NOT provider-kubernetes, NOT XPlatformSecret (ADR 0005).
> 4. **OI-2026-06-07-5 — cross-cluster Keycloak DB secret via plain ESO.** Hub
>    `PushSecret` (`keycloak-db` → SM) → spoke `ExternalSecret` → spoke `keycloak` ns
>    (chart's `existingSecret`). Depends on task 2's spoke-side ESO.
> 5. **OI-2026-06-07-3 — durable subnet tags.** In `terraform/base`, tag the
>    `kubernetes.io/role/elb` + `internal-elb` subnets
>    `kubernetes.io/cluster/<name>=shared` for every cluster the VPC hosts.
> 6. **OI-2026-06-07-4 — durable hub→spoke SG rule.** Add a `SecurityGroupIngressRule`
>    MR (443) to the platform-cluster Composition; mgmt SG from the extended
>    `cluster-network` EnvironmentConfig.
> 7. Verify end-to-end on the fresh account: hello 200 + Keycloak boots against RDS.
> All five OI entries in `docs/open-issues.md` carry the same resolutions + the
> "implement in a new session" note.

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
