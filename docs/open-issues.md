# Open Issues — durable register of undiagnosed problems

Anything observed that we did not fully diagnose goes here. Per AGENTS.md
§6.18 ("Never ignore an undiagnosed failure"), an open issue is a
hard requirement — we record what happened, what we ruled out, and the
next concrete diagnostic step. The list shrinks as items get closed
(with evidence) and grows as new ones surface.

Each entry uses the format below. Identifier `OI-YYYY-MM-DD-N` where N
is the sequence number for that date.

---

## OI-2026-06-07-1 — spoke ArgoCD cluster Secret has no durable (GitOps) form

**Status:** open — DECISION MADE (2026-06-07); implement in a new session (AWS account expired). See ADR `docs/decisions/0005-*` + `ai/handoff.md` task 3.
**Resolution:** plain ESO — enable the EKS Cluster MR connection secret → `PushSecret` → AWS Secrets Manager → `ExternalSecret` with `target.template` assembling the cluster-secret `config` (caData-in-JSON). NOT provider-kubernetes, NOT XPlatformSecret.
**Surfaced:** 2026-06-07, auto-012, phase-3 spoke registration.

**What happened:** the `platform-spoke` ArgoCD cluster Secret was created LIVE via
the ArgoCD REST API (`POST /api/v1/clusters`, awsAuthConfig.clusterName +
tlsClientConfig.caData from `aws eks describe-cluster`). The hub app-controller
authenticates with its IRSA role (now annotated — see auto-012) against the EKS
AccessEntry. Registration `connectionState: Successful`, serverVersion 1.32.

**Why it is not durable:** the endpoint+CA are account-ephemeral (§8.1, uncommittable)
and the EKS Cluster MR publishes NO connection secret (writeConnectionSecretToRef
empty), so there is nothing for a provider-kubernetes Object to reference, and the
ArgoCD cluster-secret `config` requires caData embedded in a JSON string (which
provider-kubernetes references cannot assemble — only a Crossplane Composition's
`CombineFromComposite` fmt can). The cluster Secret will not be re-created on a
fresh account.

**Recommended durable mechanism:** add a provider-kubernetes `Object` to the
XSpokeAccess Composition that builds the cluster Secret, assembling `config` JSON
via `CombineFromComposite` from the cluster endpoint + caData overlaid onto the XR
(same overlay pattern as `spec.oidcIssuer`), + RBAC for the provider-kubernetes SA
to write Secrets in `argocd` ns (same class as the ESO ClusterRole, #160). Needs
render fixtures + chainsaw (§6.8 — new Object kind in a v2 composition).

**Next step:** author the Composition Object + RBAC; delete the REST-bootstrapped
secret at cutover so the Object owns it.

---

## OI-2026-06-07-2 — registration-time ephemeral overlays fought by bootstrap selfHeal

**Status:** open — DECISION MADE (2026-06-07); implement in a new session. See ADR `docs/decisions/0005-*` + `ai/handoff.md` task 2.
**Resolution:** make this part of the `XPlatformCluster` XRD: every cluster ships (a) a per-cluster ConfigMap of cluster facts (domain/region/cert-ARN/external-dns-role-ARN) the add-ons read from — NOT per-app Helm overlays — and (b) ESO + an IRSA `ClusterSecretStore` (ESO baseline in every cluster). Workloads (`hello`) stay AWS-agnostic. This removes the bootstrap-selfHeal-vs-overlay conflict (no pausing bootstrap).
**Surfaced:** 2026-06-07, auto-012.

**What happened:** the spoke apps (`spoke-hello`, `spoke-ingress-nginx`,
`spoke-external-dns`, `spoke-keycloak`) carry committed PLACEHOLDER helm values
(domain, cert ARN, external-dns role ARN, region) that auto-008 designed to be
"overlaid at registration" into the Application's helm valuesObject/parameters.
But the `bootstrap` app-of-apps has `selfHeal: true` and manages those Application
objects from `main`, so it reverts any `argocd app set` overlay within its
reconcile interval. The values are account-ephemeral (§8.1) so they cannot be
committed to satisfy bootstrap. This is the auto-008 "finalize live" gap.

**Workaround used this run:** paused bootstrap (`argocd app set bootstrap
--sync-policy none`) during the finalize-live window. MUST be re-enabled.

**Candidate durable mechanisms (decision needed):**
1. **ApplicationSet cluster-generator** — store the ephemeral values as annotations
   on the `platform-spoke` cluster Secret; generate the spoke apps from an
   ApplicationSet that templates `{{.metadata.annotations.*}}` into valuesObject.
   Idiomatic; survives selfHeal; refactors 3-4 apps.
2. **bootstrap `ignoreDifferences` + `RespectIgnoreDifferences`** on the child
   Applications' helm value fields (targeted by app name). Minimal; lets the
   registration overlays persist as out-of-band drift bootstrap won't revert.
3. **Composition-written ConfigMap on the spoke** consumed by the charts (poor fit
   — charts need literals for Service/SA annotations).

**Next step:** decision brief (Round 1+2 adversarial) → implement.

---

## OI-2026-06-07-3 — shared-VPC subnets not tagged for the spoke cluster (LB + general)

**Status:** open — DECISION MADE (2026-06-07, concur with recommendation); implement in a new session. See `ai/handoff.md` task 5. (The live tag is gone with the expired account.)
**Surfaced:** 2026-06-07, auto-012, spoke ingress-nginx NLB never provisioned.

**What happened:** mgmt + spoke share VPC `vpc-…`. The ELB-role subnets are tagged
`kubernetes.io/cluster/k8-platform-mgmt` but NOT `…/k8-platform-services`, so the
spoke's in-tree AWS cloud provider excluded them (they "belong" to another cluster)
and could not find subnets for the internet-facing ingress NLB. EKS only tags the
subnets in a cluster's own vpcConfig (the spoke uses private node subnets), so the
public ELB subnets were never tagged for the spoke.

**Fix applied live:** `aws ec2 create-tags … Key=kubernetes.io/cluster/k8-platform-services,Value=shared`
on the public (role/elb) and internal-elb subnets.

**Durable form:** terraform/base should tag the shared ELB subnets `shared` for
every EKS cluster the VPC hosts (or the platform-cluster Composition should add the
spoke tag). Base does not currently know spoke cluster names — a small list/var.

**Next step:** add the spoke cluster tag to terraform/base subnet tagging.

---

## OI-2026-06-07-4 — hub→spoke EKS-API security-group rule has no durable form

**Status:** open — DECISION MADE (2026-06-07, concur with recommendation); implement in a new session. See `ai/handoff.md` task 6. (The live rule is gone with the expired account.)
**Surfaced:** 2026-06-07, auto-012.

**What happened:** the hub ArgoCD app-controller (mgmt node SG `sg-…`) could not
reach the spoke EKS API (private endpoint) — the spoke EKS cluster SG had no inbound
443 from the mgmt nodes. Added live:
`authorize-security-group-ingress` 443 from the mgmt node SG to the spoke cluster SG.

**Durable form:** a `SecurityGroupIngressRule` MR in the platform-cluster
Composition (groupId from the Cluster MR's clusterSecurityGroupId, source = mgmt SG
from an extended `cluster-network` EnvironmentConfig).

**Next step:** add the mgmt SG to the EnvironmentConfig + the ingress-rule MR.

---

## OI-2026-06-07-5 — phase-5 RDS connection secret is hub-local; Keycloak runs on the spoke

**Status:** open — DECISION MADE (2026-06-07); implement in a new session. See ADR `docs/decisions/0005-*` + `ai/handoff.md` task 4.
**Resolution:** plain ESO cross-cluster — hub `PushSecret` (`keycloak-db` → Secrets Manager) → spoke `ExternalSecret` → spoke `keycloak` ns. Depends on the spoke-side ESO + `ClusterSecretStore` from OI-2026-06-07-2 / ADR 0005. NOT XPlatformSecret.
**Surfaced:** 2026-06-07, auto-012, phase-5.

**What happened:** the `keycloak-db` XDatabase XR is processed by the HUB crossplane
(crossplane runs on the hub), so the RDS connection Secret `keycloak-db` lands in
the HUB's `keycloak` namespace (verified: keys address/host/port/username/password,
RDS Instance Ready=True, endpoint on :5432). But Keycloak (spoke-keycloak app) runs
on the SPOKE and reads `existingSecret: keycloak-db` there. The secret is not
delivered cross-cluster, so Keycloak cannot yet consume it.

**Also note (RDS networking):** the Instance MR sets no DB subnet group, so RDS
landed in the default subnet group; reachability from the spoke nodes is unverified.

**Candidate mechanisms:** ESO PushSecret hub→spoke; a provider-kubernetes Object
writing the secret to the spoke; or applying the XDatabase XR on the spoke (needs
crossplane on the spoke). Decision needed.

**Next step:** decide + implement cross-cluster delivery, then verify Keycloak boots
against RDS.

---

## OI-2026-06-05-5 — live ArgoCD sync unreachable from the Claude-Code-web sandbox

**Status:** **open — environmental blocker characterized, not a code bug.**
**Surfaced:** 2026-06-05, auto-007. Needed to sync `platform-cluster-claim` to
provision the phase-3 platform EKS cluster.

**Symptom / observations (§6.17):**
- **Observation:** sandbox `curl https://argocd.management.<domain>/healthz` →
  **503** on every path (`/`, `/healthz`, `/api/version`), with a clean TLS
  handshake (public ACM cert). Persisted >10 min.
- **Exclusion (by CI evidence):** `management verify` (run 27037148562)
  **succeeded**, and its `[mgmt] e2e-verify` curls ArgoCD expecting HTTP 200 — so
  **ArgoCD is healthy from CI/internet**; the 503 is sandbox-egress-specific (the
  same sandbox 403s `api.github.com`). The handoff's "sandbox has permissive
  egress; call ArgoCD directly" was true in a prior sandbox, FALSE here.
- **Exclusion:** sandbox `kubectl` to the EKS API fails TLS (`x509: certificate
  signed by unknown authority`) — the private cluster CA can't be validated
  through the sandbox proxy. Known per handoff ("only the EKS kube-API needs CI").

**What's ruled out:** ArgoCD being down (CI sees 200); stale creds (base+mgmt
applies green); a code bug.

**Why it blocks:** the only sandbox-reachable trigger for the manual-sync
`platform-cluster-claim` app is ArgoCD, which the sandbox can't reach. Worsened by
**OI-2026-06-05-6** (can't create a CI sync workflow).

**Next diagnostic / fix:** drive the sync from CI (§10.1). The reusable workflow is
authored at `docs/runbooks/argocd-sync-from-ci.md` (couldn't be committed under
`.github/workflows/` — see OI-2026-06-05-6). Once it's on main, dispatch it for
`platform-cluster-claim`, then follow `decisions/auto-009-phase3-live-completion-runbook.md`.

---

## OI-2026-06-05-6 — cannot create/modify GitHub Actions workflows in this environment

**Status:** **open — environmental constraint.**
**Surfaced:** 2026-06-05, auto-007, trying to add `.github/workflows/argocd-app-sync.yml`.

**Observations:**
- `git push` of a branch containing a new workflow file → **rejected**: *"refusing
  to allow an OAuth App to create or update workflow … without `workflow` scope."*
- `mcp__github__create_or_update_file` on a `.github/workflows/*.yml` path → **404
  Not Found** (the GitHub App backing the MCP also lacks the `workflows`
  permission; GitHub returns 404 rather than 403 for this).

**Impact:** no new CI workflow can be added, and existing workflows
(`terraform-test.yml`, etc.) cannot be edited, from this session. This is why the
argocd-sync mechanism (OI-2026-06-05-5) is delivered as a runbook doc with the YAML
inline for a human/another context to add, rather than as a committed workflow.

**Next step:** a maintainer adds `docs/runbooks/argocd-sync-from-ci.md`'s YAML to
`.github/workflows/argocd-app-sync.yml` on main (or the run is performed from a
context whose token carries the `workflow` scope).

---

## OI-2026-05-28-1 — `composition-drift` first-scenario timeout on chainsaw

**Status:** **partially resolved** — Issue B (cleanup path bug) **RESOLVED**
(fix landed in PR #129; verified in code 2026-05-29); Issue A (first-scenario
XR-Ready timeout) still **open**, hypothesis-level.
**Surfaced:** 2026-05-28, PR #125 chainsaw dispatch (run id `26552671925`,
HEAD SHA `b31cc87`).
**Re-dispatch:** 2026-05-28, run `26553581065` against the same SHA produced
a DIFFERENT failure pattern, which is what surfaced Issue B.

### Issue B — `composition-drift` cleanup silently fails to restore the mutated Composition

**Status:** **RESOLVED** (verified 2026-05-29, auto-004). The fix already
landed via PR #129 (commits `0e31154` "restore Composition from /tmp
snapshot, not cwd-relative on-disk path" + `e834a8a` "strip read-only
fields from pristine snapshot"). `tests/chainsaw/_meta/composition-drift/chainsaw-test.yaml`
now snapshots the pristine Composition to `/tmp/composition-pristine.yaml`
in the mutate step and restores from that path (CWD-independent) guarded by
`if [ -f ... ]` with **no `|| true`** — so a future restore failure exits
non-zero immediately instead of cascading. The register entry below was
stale; closing it. Real-AWS chainsaw re-confirmation is the last step.
**Root cause (historical):** The composition-drift scenario's
"restore the Composition (cleanup)" script runs:
```sh
kubectl apply -f crossplane/compositions/platform-secret.yaml || true
```
Chainsaw runs scripts with its own CWD (under `tests/chainsaw/`), not the
repo root, so the relative path doesn't resolve. The `|| true` swallows the
error. Verbatim from run `26553581065` log:
```
error: the path "crossplane/compositions/platform-secret.yaml" does not exist
```
**Consequence:** When `composition-drift` reaches the mutation step (which
it did in run `26553581065` but not in run `26552671925`, see Issue A), the
on-cluster Composition stays at `recoveryWindowInDays: 7`. All subsequent
scenarios (`claim-creates-secret`, `claim-rotation`, `claim-deletion-cleanup`)
reconcile against the mutated Composition. Their goldens assert
`recoveryWindowInDays: 0` and fail with diff at the chainsaw assert timeout
(~249-253s). This is the cascading triple-failure observed in run `26553581065`.
**Fix:** (1) compute the composition path absolutely (e.g. `$(git rev-parse
--show-toplevel)` or chainsaw's `$CHAINSAW_ROOT` if it sets one); (2) drop
the `|| true` so the next time the apply fails, the cleanup step exits
non-zero and the failure is visible immediately rather than cascading.
**Next action:** open a stacked PR (Task 6) with the fix. Hold pending
user confirmation per §6.5.

### Issue A — `composition-drift`'s XR takes >245s to become Ready (first run only)

**Status:** still hypothesis-level. The Issue B diagnosis does NOT explain
Issue A — in run `26552671925` the XR was Unready at `wait for XR Ready`'s
245s timeout BEFORE composition-drift could reach the mutation step. The
asm-secret MR had `status.Ready=False, reason=Creating`. In run
`26553581065` the same XR became Ready in time. Both runs were on the same
SHA, same composition, fresh kind cluster per run.
**Hypotheses (UNCONFIRMED — no positive evidence):**
- AWS-provider cold start that varies between dispatches.
- IAM permission propagation lag on the freshly-issued GHA access key
  (a few-minutes window where the key works for some calls and not
  others).
- Transient AWS API throttling or upstream provider hiccup.
**Ruled out:**
- Stale credentials (`§8.2`): later scenarios in the FIRST run authenticated
  and provisioned ASM secrets successfully via the AWS CLI; later scenarios
  in the SECOND run also authenticated (their failure was the
  recoveryWindowInDays diff, not an AWS API error).
- Regression from Task 2: `git diff main chore/audit-wiring-fixes-2026-05-02
  -- crossplane/ tests/chainsaw/` is empty.
**Next diagnostic step:** the catch block now uses `-A` (post the
chore/audit-wiring-fixes-2026-05-05 fix) so the asm-secret MR's
`status.conditions` and `status.atProvider` will be captured on the next
occurrence. Re-dispatch only after Issue B is fixed (so subsequent
scenarios don't cascade-fail and obscure Issue A).
**Owner / next action:** Issue A defers; Issue B is the immediate fix.

**2026-05-29 update (auto-004, NEW POSITIVE EVIDENCE — run `26621695077`):**
Recurred on a fresh account, this time on the **`claim-rotation`** scenario
(not composition-drift). 5/6 real-AWS scenarios passed
(`claim-creates-secret` in 10.7s, `claim-deletion-cleanup`, `composition-drift`,
`xrd-establishes`, `_smoke`); only `claim-rotation` failed at the
`wait for claim Ready` 240s timeout. The catch block captured the actual
provider error (the earlier occurrences only showed `Ready=False,
reason=Creating`):
```
CannotCreateExternalResource ... ResourceExistsException: The operation
failed because the secret k8-platform/<xr-uid> already exists.
```
This **sharpens the hypothesis** from "XR is just slow" to a **CreateSecret /
Observe double-create race**: the AWS provider issues `CreateSecret`, then a
second reconcile re-issues `CreateSecret` before the first is observable
(AWS Secrets Manager read-after-write lag) → `ResourceExistsException`, and
the MR can get stuck re-attempting create rather than adopting the existing
secret, so the XR never reaches Ready within 240s. Consistent with
"flaky / load-dependent" (the same Composition's `claim-creates-secret`
passed in 10.7s in the same run). Still **hypothesis**, not confirmed —
candidate fixes to evaluate if it recurs deterministically:
(a) run chainsaw scenarios serially (reduce parallel provider load),
(b) raise `claim-rotation`'s assert timeout above 240s,
(c) investigate the provider's external-name persistence after first
    CreateSecret (the real fix if the MR never self-heals).
Also noted: `tests/chainsaw/run.sh`'s cleanup trap deletes by
`ASM_PREFIX="k8-platform-chainsaw"`, but the Composition names secrets
`k8-platform/<uid>` — so scenario secrets are NOT swept by the prefix
cleanup (they linger until manually removed). Separate minor issue; logged
here for the next session. **Next action:** re-kicked chainsaw once to test
the flake hypothesis (auto-004).

---

## OI-2026-06-05-1 — `yq/awk | grep -q` under `set -o pipefail` flakes unit tests

**Status:** **RESOLVED** (diagnosed + fixed, auto-005 long-run).
**Surfaced:** 2026-06-05, full local `tests/unit/run.sh` run during the
auto-005 audit — `test_platform_cluster_composition.sh`'s
`composition_policy_AmazonEKSWorkerNodePolicy` assertion failed
intermittently (`missing policyArn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy`).

**Root cause (CONFIRMED by repro + fix, not hypothesis):** the assertion ran
`yq -r "...resources[]...policyArn..." "$COMP" | grep -qF "$arn"` under
`set -uo pipefail`. `grep -q` exits on its first match and closes the pipe;
the still-writing `yq` then takes `SIGPIPE` (exit 141), and `pipefail`
propagates that 141 as the pipeline's status, so the `if` intermittently
takes the `else` branch and emits a false FAIL. Measured **~10% (2-3/20-30)**
before the fix.

**Fix:** capture the producer's output to a variable, then `grep -q … <<<"$var"`
(here-string — no upstream process to receive SIGPIPE). Applied to every
instance of the class found in `tests/unit/`:
- `test_platform_cluster_composition.sh` (the observed one),
- `test_argocd_bootstrap.sh` (2 sites, `awk … | grep -q`),
- `test_diag_component.sh` (2 sites, `awk … | grep -q`).
`yq --version | grep -q mikefarah` sites were left as-is (single-line output,
producer already exited — no SIGPIPE window).

**Verification:** the previously-flaky test ran **0/30** failures after the
fix (was ~3/30). All three touched tests pass standalone.

**Prevention note (candidate AGENTS rule / lint):** "Never `producer | grep
-q` under `pipefail` when the producer emits more than one line — capture and
`grep -q <<<"$var"`." Surfaced for the retro.

---

## OI-2026-05-28-1 Issue B-adjacent — ASM cleanup-trap gap: **RESOLVED**

**Status:** **RESOLVED** (auto-005 long-run). The "Also noted" item in
OI-2026-05-28-1 below — `tests/chainsaw/run.sh` swept ASM secrets by
`${ASM_RUN_PREFIX}/` (`k8-platform-chainsaw-<id>/`) while the Composition
names them `k8-platform/<uid>`, so they never matched and leaked — is fixed.
The cleanup now enumerates the real names from the Secret MRs in the live
kind cluster (`tests/chainsaw/_lib/asm-cleanup.sh`) and deletes exactly
those, before `kind delete`. Behavioral unit test:
`tests/unit/test_chainsaw_asm_cleanup.sh`. (Issue A — the
`ResourceExistsException` rotation race itself — remains open; see decision
brief `decisions/auto-006-asm-external-name-fix.md`.)

---

## OI-2026-06-05-2 — `charts.crossplane.io` 403s the GitHub Actions runner

**Status:** **mitigated** (chart vendored); root cause still **hypothesis**.
**Surfaced:** 2026-06-05 auto-005 long-run — `phase=management
apply-and-verify` failed twice in a row (runs 27021786260, 27022894643), both
ONLY on `helm_release.crossplane`:
```
Error: could not download chart: looks like "https://charts.crossplane.io/stable"
is not a valid chart repository or cannot be reached: failed to fetch
https://charts.crossplane.io/stable/index.yaml : 403 Forbidden
```
Everything else applied (EKS cluster, ArgoCD, ESO, Kyverno, ingress-nginx,
external-dns, the bootstrap + argocd-admin-password provisioners).

**Evidence:**
- The same URL returns **HTTP 200** from the sandbox (and `master/index.yaml`
  too), and the index still lists `crossplane-2.3.0.tgz` — so the repo is up
  and the chart was NOT migrated/yanked.
- Two deterministic failures 4 min apart rule out a one-off transient.
- The prior successful management build (2026-05-29, run 26621556820) used the
  same URL — so this is a recent change in how the CDN treats the runner.

**Hypothesis (labelled, §6.17):** the CDN fronting `charts.crossplane.io`
(S3/CloudFront-class) is returning 403 to the GitHub-hosted runner egress
range specifically (IP/geo/UA based or rate-limited), while other networks get
200. NOT confirmed — I cannot curl from the runner directly. No public incident
found via web search.

**Mitigation applied:** vendored the digest-verified chart into
`terraform/management/vendor/crossplane-2.3.0.tgz` (sha256
`2ceff920…cd7f`, matches the upstream index digest) and switched
`helm.tf`'s `helm_release.crossplane` to install from that local path. The
apply is now hermetic and independent of the CDN. `terraform validate` passes.

**Next / revert:** if the CDN restriction lifts (re-check from a runner via a
probe step), restore the `repository`/`version` form and delete the tarball.
Consider asking Crossplane to publish the chart via OCI (xpkg/ghcr) — neither
`oci://xpkg.crossplane.io/crossplane/crossplane` nor `oci://ghcr.io/crossplane/
crossplane` exists today, so OCI was not an option.

---

## OI-2026-06-05-3 — provider-family-aws install races the package manager on fresh Crossplane

**Status:** **RESOLVED** (fix landed; pending live re-confirmation on the re-run).
**Surfaced:** 2026-06-05 auto-005 — management `apply-and-verify` run
27023573285 (branch ref, vendored-chart fix applied) failed at
`terraform_data.crossplane_aws_provider` (helm.tf:232):
```
deploymentruntimeconfig.../aws-provider-config created
provider.../provider-family-aws created
No resources found ... ERROR: expected SA upbound-provider-family-aws, got: MISSING
```
**Root cause (CONFIRMED by reading the log):** the provisioner applied the
`DeploymentRuntimeConfig` + `Provider`, then immediately `delete deploy -l … --wait=false`
and `kubectl rollout status -l …`. On a **fresh** Crossplane install the package
manager has not yet pulled the package image and created the provider's
Deployment + ServiceAccount, so `rollout status -l <sel>` returns "No resources
found" (non-zero) **immediately** (it does not wait for a matching resource to
appear), and the SA post-check then fails with `MISSING`. The prior successful
build (2026-05-29) won the race by luck (faster pull).

**Fix (helm.tf):** (1) `kubectl wait --for=condition=Healthy
provider.pkg.crossplane.io/provider-family-aws --timeout=300s` BEFORE the delete
(guarantees the Deployment+SA exist); (2) after the delete, poll for the
Deployment to reappear (the package manager doesn't recreate it instantly)
before `rollout status`. POSIX /bin/sh. `terraform validate` passes. Handles
both fresh-install and DRC-change-upgrade cases.

---

## OI-2026-06-05-4 — v2.5.0 family-provider Deployment lacks the `pkg.crossplane.io/provider` label the provisioner selected on

**Status:** **mitigated** (provisioner no longer depends on the label).
**Surfaced:** 2026-06-05 auto-005, run 27023830973 — with the OI-2026-06-05-3
Healthy-wait in place, the log showed:
```
provider.pkg.crossplane.io/provider-family-aws condition met   (Healthy)
No resources found                                             (delete -l … matched nothing)
ERROR: provider Deployment never reappeared after delete
```
**Root cause:** `terraform_data.crossplane_aws_provider`'s provisioner did
`kubectl -n crossplane-system delete deploy -l pkg.crossplane.io/provider=provider-family-aws`
and `kubectl rollout status -l <same>`. The Provider is Healthy (so its
Deployment+SA exist) but **nothing in crossplane-system carries that label** on
the Upbound v2.5.0 family provider — `kubectl rollout status -l <sel>` /
`delete -l <sel>` therefore match nothing. This delete+rollout-by-label was a
re-roll mechanism for a DRC SA-name *change*; it is unnecessary on a fresh
install (the DRC is applied WITH the Provider, so the Deployment is created with
the pinned SA from the start). It is also where OI-2026-06-05-3's first fix still
failed.
**Fix:** drop the by-label delete/rollout. Keep `kubectl wait
--for=condition=Healthy provider/provider-family-aws`, add a label-agnostic poll
for the `upbound-provider-family-aws` SA to materialise, and a diagnostics dump
(`get deploy,sa --show-labels`, pod serviceAccounts, providers/providerrevisions)
so the real labels are visible in the log. The existing hard gate (SA object
name == `upbound-provider-family-aws`) is retained. The diagnostics will reveal
the actual provider-Deployment label for a future, precise re-roll if a DRC
SA-name change is ever needed. terraform validate passes.

---

## OI-2026-06-06-3 — XDatabase RDS `<xr>-master` password Secret is not GC'd on XR delete

**Status:** **open — characterized, low-severity cleanup gap; not blocking phase 5.**
**Surfaced:** 2026-06-06, phase-5 finalization (XDatabase XRD + RDS Composition,
`crossplane/compositions/xdatabase.yaml`). Found during the adversarial review of
the Composition's connection-secret wiring.

**Symptom / observations (§6.17):**
- **Observation:** the RDS Composition sets `spec.forProvider.autoGeneratePassword:
  true` with `spec.forProvider.passwordSecretRef.{name,key}` patched to
  `<xr-name>-master` / `password`. The Upbound `provider-aws-rds` Instance
  controller GENERATES that Secret in the Instance MR's namespace (= the XR
  namespace). It holds the master DB password.
- **Observation:** that `<xr>-master` Secret is created by the provider, not by
  the Composition's `function-patch-and-transform` resource list. It therefore
  carries NO `ownerReference` back to the XR or the Instance MR — Crossplane's
  composed-resource GC only reaps resources it composed, and the connection
  Secret (`writeConnectionSecretToRef`) is handled by the standard connection-
  secret lifecycle, but the generated `passwordSecretRef` Secret is not.
- **Hypothesis (labelled, not confirmed — no live RDS run yet):** on
  `kubectl delete xdatabase keycloak-db`, the XR → Instance MR → RDS instance
  tear down (managementPolicies includes Delete), and the connection Secret is
  removed, but the `keycloak-db-master` Secret is LEFT BEHIND as an orphan in the
  keycloak namespace.

**What's ruled out:** the connection Secret itself orphaning — that one IS owned
via `writeConnectionSecretToRef` and is asserted gone by the
`02-deletion-cleanup` chainsaw scenario. This entry is ONLY about the separate
`-master` generated Secret.

**Why it does not block phase 5:** the orphan is a single empty-after-DB-gone
Secret in the consumer namespace; it leaks no live cloud resource and no cost.
The `02-deletion-cleanup` chainsaw scenario asserts both the connection Secret
AND the `-master` Secret are gone, so this gap is OBSERVABLE in CI the moment a
real-AWS run executes (the scenario will fail on the `-master` assert if the
orphan is real — turning this hypothesis into a confirmed bug with evidence).

**Next diagnostic / fix:** (1) run the real-AWS `02-deletion-cleanup` scenario to
confirm/deny the orphan. (2) If confirmed, the clean fix is to compose the
`-master` Secret as an explicit `kubernetes` provider Object (or a Composition
resource) carrying the owner reference, OR to add a finalizer/cleanup step; do
NOT hand-delete in the scenario (that would mask the gap per §6.24). Track the
fix as its own PR.

---

## OI-2026-06-06-1 — `crossplane render` defaulted to a floating `:stable` orchestrator image → `unexpected argument internal`

**Status:** **RESOLVED** (root-caused + fixed + verified green with the real
tools this session).
**Surfaced:** every push — `unit-tests.yml` `test_composition_render_fixtures.sh`
failed its 2 `*_render_matches_golden` subtests on `main` (e.g. run 27050411763,
HEAD `f39fee40`):
```
crossplane: error: cannot render composite resource: cannot run crossplane
internal render in Docker: container exited with status 1: crossplane: error:
unexpected argument internal
```

**Root cause (CONFIRMED, not hypothesis — reproduced locally with `--verbose`):**
`crossplane render` does the actual composition rendering by running
`crossplane internal render` inside a **Crossplane Docker image**, separate from
the function container. That orchestrator image defaults to the FLOATING tag
`xpkg.crossplane.io/crossplane/crossplane:stable`, which currently resolves to
**v1.20.9** (the v1.x stable line). v1.20.9 has no `internal render` subcommand,
so it rejects the args with `unexpected argument internal`. The function image
(`function-patch-and-transform:v0.10.6`) was never the problem; the breakage was
purely the un-pinned orchestrator image drifting. It was NOT a CLI-version drift
(reproduced identically with the CLI pinned to v2.3.0) and NOT any manifest bug.

**Fix:**
1. `scripts/composition-render.sh` now passes `--crossplane-version v${CROSSPLANE_CHART_VERSION}`
   (→ `v2.3.0`) to `crossplane render`, pinning the orchestrator image to the
   SAME Crossplane the management cluster runs (`read_crossplane_version()` reads
   the existing `versions.env` pin — single source of truth, cannot drift from
   the chart).
2. `.github/workflows/unit-tests.yml` now installs the crossplane CLI pinned to
   `v${CROSSPLANE_CHART_VERSION}` from the releases `crank` binary, instead of
   `install.sh` from `main` (the flag-parsing CLI must also be pinned).

**Verification:** with mikefarah `yq` v4.44.3 + crossplane CLI v2.3.0 + a running
dockerd, `bash tests/unit/test_composition_render_fixtures.sh` → **12/12 pass**
(both goldens match, both determinism sub-tests pass). The existing render test
is the regression catcher: if the pin is removed the floating image returns and
the test reds again.

**Note:** the sandbox ships the Python `yq` (kislyuk) by default, which silently
breaks `normalize_stream`'s mikefarah syntax and produces spurious golden
mismatches locally — install mikefarah/yq v4.44.3 before running the render test
in the sandbox (CI already does).

## OI-2026-06-06-2 — mgmt provider bootstrap: every AWS provider revision stuck `HEALTHY=False` with no runtime Deployment; two `provider-family-aws` Provider objects from one package

**Status:** **fix refined (orphan cleanup), re-validating** — Option A (rename +
ordering + diagnostics) on branch `fix/auto-009-mgmt-provider-sa` passed Round-1
adversarial review (all accept-with-amendment). Live validation 1 (run
`27055996205`) **CONFIRMED the root cause** (see "Confirmed root cause" below)
but FAILED in-place because the OLD-named Provider from the first failed run
lingered on the wedged cluster and `kubectl apply` of the renamed Provider does
not prune it — both objects co-owned the package and the Lock DAG stayed
unbuildable. The fix is now refined with an idempotent **pre-apply orphan
cleanup** of the stray `provider-family-aws` Provider, so it self-heals a wedged
cluster without a `terraform destroy`. DO NOT MERGE until the re-validation
`management apply-and-verify` run is green on the branch.
**Surfaced:** 2026-06-06, `terraform-test.yml phase=management action=apply-and-verify`
run `27054926075`, main SHA `c3a6cb3`, account `211125540973`. FAILED at
`terraform_data.crossplane_aws_provider` (helm.tf:241).

### Verbatim symptom
The Healthy-wait timed out, then the diagnostics dump and the hard SA gate fired:
```
2026-06-06T06:43:38Z  error: timed out waiting for the condition on providers/provider-family-aws
2026-06-06T06:47:07Z  ERROR: expected SA upbound-provider-family-aws, got: MISSING
2026-06-06T06:47:07Z  DRC serviceAccountTemplate.metadata.name override appears ineffective.
2026-06-06T06:47:07Z  Error: local-exec provisioner error ... on helm.tf line 241
```

### Evidence (Observation — quoted from the run log)
1. **No provider revision EVER reached Healthy.** The diagnostics `kubectl get
   providers,providerrevisions` (captured at +5m, just before the gate) shows
   all six AWS providers `INSTALLED=True  HEALTHY=False` and all six revisions
   `HEALTHY=False  RUNTIME=False  STATE=Active`:
   ```
   provider.../provider-aws-acm/eks/iam/route53        True   False  ...:v2.5.0  5m3s
   provider.../provider-family-aws                      True   False  ...:v2.5.0  5m3s
   provider.../upbound-provider-family-aws              True   False  ...:v2.5.0  4m57s
   providerrevision.../provider-family-aws-604659292671          False False ...v2.5.0 Active 5m1s
   providerrevision.../upbound-provider-family-aws-604659292671  False False ...v2.5.0 Active 4m55s
   ```
2. **No provider runtime Deployment or ServiceAccount was ever created.** The
   `kubectl -n crossplane-system get deploy,sa --show-labels` dump lists ONLY
   the Crossplane core runtime — there is no `provider-*` Deployment and no
   `upbound-provider-family-aws` SA at all:
   ```
   deployment.apps/crossplane                        1/1 ... 5m26s
   deployment.apps/crossplane-rbac-manager           1/1 ... 5m26s
   deployment.apps/function-environment-configs-...  1/1 ... 4m51s
   serviceaccount/crossplane / default / rbac-manager / function-environment-configs-...
   ```
   The pinned `upbound-provider-family-aws` SA is therefore `MISSING` not
   because the DRC override was *ignored* (the comment in helm.tf hypothesises
   that), but because **no provider runtime was ever stood up to own a SA.**
3. **TWO Provider objects reference the same package**, `xpkg.upbound.io/upbound/
   provider-family-aws:v2.5.0`: `provider-family-aws` (declared in helm.tf, age
   5m3s) and `upbound-provider-family-aws` (age 4m57s — created ~6s later, as a
   **dependency** auto-resolved by the four child providers in
   `crossplane-phase3.tf`; Crossplane derives the dependency Provider's name
   from the package's own `metadata.name`, `upbound-provider-family-aws`).
4. **Timeline.** Family Provider applied at +0s (06:38:33); child providers
   applied in the SAME parallel terraform batch (06:38:38) — there is no
   `depends_on` ordering between the phase3 child providers and the family
   Provider. Healthy-wait ran the full `--timeout=300s` (06:38:33→06:43:38) and
   never met the condition. Providers had **~8m30s** of cluster time before the
   gate fired (06:38:38 create → 06:47:07 gate); none became Healthy in that
   window.
5. **The OI-2026-06-05-3 / -4 / #142-class fix IS already on main** (commits
   `e635a1e` "wait for provider package install before SA check" + `2fe3f14`
   "drop by-label provider delete/rollout"). helm.tf:255-257 already does the
   Healthy-wait, helm.tf:280-285 the label-agnostic SA poll. That fix addressed
   a *package-manager-lag* race; it does not address this failure, where the
   provider runtime never comes up at all.

### Labelled root-cause (§6.17)
- **Exclusion — NOT a pure timeout.** With ~8.5 min of cluster time, zero of six
  revisions advanced past `RUNTIME=False` and zero provider Deployments were
  created. A longer wait or larger `--timeout` would have changed nothing — the
  package manager was not making progress, it was stuck. Bumping the timeout is
  excluded as the fix.
- **Exclusion — NOT the DRC SA-name override being ignored.** The helm.tf
  in-line comment and the error string both blame a silently-ignored
  `serviceAccountTemplate.metadata.name`. That is excluded: the SA is absent
  because *no provider Deployment exists to own any SA*, default-named or
  pinned. The override's effectiveness cannot be the cause when the runtime
  layer never materialised.
- **Conclusion (structural):** the bootstrap declares the family provider
  **twice under two different Provider object names from one package** —
  `provider-family-aws` (explicit, helm.tf:206-215) and
  `upbound-provider-family-aws` (implicit dependency created by the
  `provider-aws-{eks,iam,acm,route53}` child Providers in crossplane-phase3.tf).
  Two `Provider` objects owning **revisions of the same package** is a
  package-manager conflict: each revision wants to install the same package's
  CRDs/runtime, activation does not converge, and the revisions sit
  `Active / HEALTHY=False / RUNTIME=False` with no Deployment. The wait in
  helm.tf is keyed on the explicit `provider-family-aws` object, which is one of
  the two contending parties, so it can never go Healthy.
  - **Hypothesis (mechanism, not yet positively tested):** the precise failure
    mode is duplicate-package revision contention / CRD ownership conflict
    between the two Provider objects. *Consistent with* all six AWS providers
    (which all transitively depend on the family package) being stuck, while the
    Crossplane core + function runtimes (independent of the family package) came
    up fine. Confirming requires the provider/revision `status.conditions`
    + crossplane-system controller logs, which this run did not capture.

### Confirmed root cause (live validation 1, run 27055996205)
The hypothesis above is **now CONFIRMED** — it is no longer a hypothesis. The
`management apply-and-verify` run `27055996205` on `fix/auto-009-mgmt-provider-sa`
FAILED, but its broadened diagnostics captured the decisive evidence: the
crossplane package-manager `Lock` condition read
```
reason: DependencyResolutionFailed
message: 'cannot build DAG: node xpkg.upbound.io/upbound/provider-family-aws already exists'
```
with BOTH `provider.pkg.crossplane.io/provider-family-aws` AND
`provider.pkg.crossplane.io/upbound-provider-family-aws` present
(`INSTALLED=True`, `HEALTHY=False`, same package, ~48m old). The two Provider
objects co-owning `xpkg.upbound.io/upbound/provider-family-aws` make the Lock's
dependency DAG **unbuildable** (`already exists`) → no provider runtimes → no
Deployment → no SA. The rename to a single object is therefore the correct fix.
It could not take effect in-place because this was a NON-fresh (wedged) cluster:
the OLD `provider-family-aws` object from the first failed run lingered, and
`kubectl apply` of the renamed Provider does not prune it. **Refinement added:**
an idempotent pre-apply `kubectl delete provider.pkg.crossplane.io
provider-family-aws --ignore-not-found` (+ wait-until-gone loop) in the
`terraform_data.crossplane_aws_provider` provisioner, so the Lock can rebuild the
DAG and the fix self-heals in place.

### Proposed fix (specific)
**Collapse the family provider to a single Provider object so one package is
owned by one Provider.** The minimal, lowest-risk form: in helm.tf:208 **rename**
the explicit Provider's `metadata.name` from `provider-family-aws` →
`upbound-provider-family-aws` (the name the child providers' dependency
resolver already uses, derived from the package's own `metadata.name`). Then the
child providers de-dupe onto the existing object instead of spawning a second
one, and the explicit object keeps the `runtimeConfigRef: aws-provider-config`
that carries the pinned SA + IRSA annotation. Required companion edit:
- helm.tf:256 — change the Healthy-wait target from
  `provider.pkg.crossplane.io/provider-family-aws` →
  `.../upbound-provider-family-aws` so the wait watches the surviving object.
- helm.tf:281 / :299 already poll/assert the SA name `upbound-provider-family-aws`
  — unchanged.
- irsa.tf:140 (`crossplane-system:upbound-provider-family-aws`) already matches —
  unchanged.

See `decisions/auto-009-mgmt-provider-sa-fix.md` for the ≥2 alternatives +
adversarial-review framing — this is a load-bearing bootstrap change.

### Next concrete diagnostic step (before applying)
Capture the missing positive evidence to confirm the duplicate-package mechanism
vs. a generic provider-runtime stall: on the next failed (or a probe) run, dump
`kubectl describe providerrevision provider-family-aws-604659292671
upbound-provider-family-aws-604659292671` and
`kubectl -n crossplane-system logs deploy/crossplane` around revision activation.
If both revisions report a CRD-ownership / "already managed by" conflict, the
structural conclusion is positively confirmed and the rename is the fix. If
instead the revisions report image-pull / RBAC errors, the duplicate-Provider
point is contributing-but-not-sole and the fix must also address a runtime stall.

**Owner / next action:** fix authored on `fix/auto-009-mgmt-provider-sa`
(rename explicit Provider → upbound-provider-family-aws + `depends_on`
ordering on the child providers + broadened SA-gate diagnostics + one-Provider
assertion + chainsaw name alignment). Next: dispatch
`terraform-test.yml phase=management action=apply-and-verify` against the
branch and confirm exactly one family Provider reaches Healthy with the pinned
SA present, then merge. Decision brief + Round-1 adversarial review in
`decisions/auto-009-mgmt-provider-sa-fix.md`.

<!-- New entries go above this line, newest first. -->

<!-- appended auto-010 -->
### OI-2026-06-06-4 — phase-5 xdatabase real-AWS chainsaw scenarios are nightly-gated (RESOLVED-config)
**Status:** resolved (config). The `xdatabase/01-claim-creates-rds` and
`02-deletion-cleanup` chainsaw scenarios provision a live RDS instance and need
provider-aws-rds + IRSA the per-PR kind harness does not install. They now carry
a `REAL-AWS / NIGHTLY` header and `tests/chainsaw/run.sh` excludes them unless
`CHAINSAW_INCLUDE_REALAWS=1` (run 27072199866 had run them in the kind matrix →
fast FAIL). Author-time coverage: render-fixtures + `test_xdatabase_rds_composition.sh`.
Live coverage: the phase-5-live step (sync the `keycloak-db` XR on the spoke and
verify the RDS Instance), or a nightly real-AWS chainsaw with
`CHAINSAW_INCLUDE_REALAWS=1`. Guard: `test_chainsaw_realaws_gated.sh`.

### OI-2026-05-28-1 recurrence note (auto-010)
`claim-creates-secret` timed out at 246s again on chainsaw run 27072199866
(ASM `CannotCreateExternalResource` / "asm-secret not yet ready" — the known
flake). Established remedy: re-kick. Durable fix still pending per the existing
OI-2026-05-28-1 entry (external-name change).
