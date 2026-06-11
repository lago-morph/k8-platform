# Open Issues — durable register of undiagnosed problems

Anything observed that we did not fully diagnose goes here. Per AGENTS.md
§6.18 ("Never ignore an undiagnosed failure"), an open issue is a
hard requirement — we record what happened, what we ruled out, and the
next concrete diagnostic step. The list shrinks as items get closed
(with evidence) and grows as new ones surface.

Each entry uses the format below. Identifier `OI-YYYY-MM-DD-N` where N
is the sequence number for that date.

---

## Status index (audited 2026-06-09, auto-016)

**TRULY OPEN — real work outstanding:**

| ID | One-line | Note |
|----|----------|------|
| OI-2026-06-07-2 | placeholder overlays fought by bootstrap selfHeal | **RESOLVED — 1× clean-build evidence 2026-06-10** (ADR-0010 consumer+producer; SUBSTRATE row 4): all 7 ApplicationSets generated from the registration Secret's contract on clean build #1, no overlay surface remains |
| OI-2026-06-07-1 | spoke ArgoCD cluster Secret has no GitOps form | **RESOLVED — 1× clean-build evidence 2026-06-10** (SUBSTRATE row 5): Composition-produced Secret, full contract, `spoke-cluster-secret-live.sh` PASS on clean build #1 |
| OI-2026-06-07-3 | shared-VPC ELB subnet tags | **RESOLVED — 1× clean-build evidence 2026-06-10** (SUBSTRATE row 3): spoke NLB placed with zero create-tags on clean build #1 |
| OI-2026-06-07-4 | hub→spoke EKS-API SG rule | **RESOLVED — 1× clean-build evidence 2026-06-10** (SUBSTRATE row 2): hub ArgoCD synced the spoke with zero authorize-sg-ingress on clean build #1 |
| OI-2026-06-07-5 | cross-cluster Keycloak DB secret | open; Keycloak not yet booted against RDS |
| OI-2026-06-07-6 | **static assertions masquerade as tests** | umbrella — the test overhaul executes against this; not a single bug |
| OI-2026-06-07-7 | P0-spike `resourceRefs`⇒AccessDenied not confirmed | needs a provisioned XR |
| OI-2026-06-07-8 | jentic workflow-integration capstone deferred | not started |
| OI-2026-06-06-3 | XDatabase `<xr>-master` secret not GC'd | open, low-severity cleanup |

**IN FLIGHT (open but actively closing — auto-016 PRs):**

| ID | One-line | Note |
|----|----------|------|
| OI-2026-06-11-1 | **NEW** — CI-harness hardening queue (retro 2026-06-11-224 R2/R3/R4) | deferred deliberately: a concurrent session is live against these workflows; see entry |
| OI-2026-06-10-1 | **NEW** — ACM provider v2.5.0 leaves Certificate `crossplane.io/external-name` EMPTY → `certificateArnSelector` never resolves | Composition fix MERGED (#223) + validated on clean build #1 (the stuck MR resolved via GitOps propagation, XR Ready=True); WHY external-name stays empty remains undiagnosed — see entry |
| OI-2026-06-09-1 | **NEW** — narrowed `iam:GetRole` broke EKS nodegroup SLR create | **FIXED** PR #213, proven live (nodegroup ACTIVE after fix); pending merge |
| OI-2026-06-08-1 | Crossplane `Resource:"*"` (RDS/EC2) follow-up | IAM resolved (#203); RDS PR #211 (applied live, ongoing-reconcile green), EC2 PR #212 (draft) |
| OI-2026-06-08-2 | hub→spoke e2e not behaviorally tested | **RESOLVED 2026-06-10**: first execution of `hello-e2e-live.sh` PASS on clean build #1 (SUBSTRATE row 8) |

**ENVIRONMENTAL / MITIGATED (known limitations, not active bugs):**

| ID | One-line | Note |
|----|----------|------|
| OI-2026-06-05-6 | can't create/modify `.github/workflows` here | environmental; workaround = jentic Contents-PUT |
| OI-2026-06-05-2 | `charts.crossplane.io` 403 on the runner | mitigated (vendored chart); root cause still hypothesis |

**RESOLVED (kept for the rationale record):**

| ID | One-line | Resolved by |
|----|----------|-------------|
| OI-2026-06-06-4 | real-AWS chainsaw nightly-gating | mechanism EXCISED (auto-014 #188); verified gone from `tests/` in auto-016 |
| OI-2026-05-28-1 (Issue A) | chainsaw claim-deletion-cleanup flake | bounded-poll fix (#184); verified present in `01-claim-deletion-cleanup` in auto-016 |
| OI-2026-06-05-5 | ArgoCD unreachable from sandbox | `*.management` ACM cert (auto-007 #149) — re-confirmed reachable (argocd login + healthz 200) |
| OI-2026-06-05-3 | provider-family-aws install race | #156 — re-confirmed (providers healthy, XSpokeAccess MRs reconciled) |
| OI-2026-06-05-4 | v2.5.0 family-provider Deployment label | provisioner no longer depends on the label |
| OI-2026-06-06-2 | mgmt provider bootstrap deadlock | #156 — re-confirmed (single provider, all AWS MRs reconciled) |
| OI-2026-06-06-1 | `crossplane render` floating `:stable` | #153 (version pin) |
| OI-2026-06-05-1 | `yq/awk \| grep -q` pipefail flake | here-string fix (auto-005) |
| OI-2026-05-28-1 (Issue B + B-adjacent) | chainsaw cleanup-path / ASM trap | auto-004/005 |

> Convention reminder: RESOLVED entries are retained here as the rationale record;
> prune them once they've been stable across a couple of account rebuilds.


---

## auto-016 update (2026-06-09) — fresh-account bring-up surfaced 1 regression + 3 recurrences

A clean fresh-account bring-up with the auto-015 narrowed Crossplane policy applied
**from the start** (account `471112679140`) brought base + hub + spoke EKS up and <!-- noqa: account-id - historical run provenance; account rotated -->
**re-validated OI-2026-06-08-1's identity narrowing on the CREATE path** (spoke OIDC
provider + Roles + RolePolicy + AccessEntries + AccessPolicyAssociations all
`Ready=True` under the narrowed policy). It also surfaced:

- **OI-2026-06-09-1 (NEW, FIXED) — narrowed `iam:GetRole` broke EKS nodegroup
  create.** `iam:GetRole` was scoped to `role/k8-platform-*`, but EKS
  `CreateNodegroup` validates the SLR `AWSServiceRoleForAmazonEKSNodegroup` via
  `iam:GetRole` on `role/aws-service-role/eks-nodegroup.amazonaws.com/*` → fail-closed,
  spoke came up with **0 nodes**. auto-015 only validated the spoke-*access* path
  (no nodegroup SLR). Fixed: PR #213 adds an `EKSServiceLinkedRoles` Sid scoped to
  the EKS SLR path; proven live (nodegroup ACTIVE immediately after). Merge #213.
- **OI-2026-06-08-1 RDS/EC2 follow-up** — RDS narrowed (PR #211, applied live, clean
  plan diff, ongoing-reconcile green under it; pristine CREATE proof deferred — the
  Instance pre-existed the narrowing). EC2 narrowed (PR #212, draft; one reviewer
  recommends defer). Both sentinel-gated drafts.
- **OI-2026-06-07-4 (hub→spoke SG) — RECURRED.** Composition only admits the SSM
  relay to the spoke API, NOT the hub nodes → ArgoCD `dial tcp …:443 i/o timeout`.
  Live-fixed (authorized 443 hub-SG + VPC-CIDR → spoke cluster SG). **Durable
  Composition fix still owed.**
- **OI-2026-06-07-3 (ELB subnet tags) — RECURRED.** Shared ELB subnets not tagged
  `kubernetes.io/cluster/k8-platform-services=shared` → NLB "could not find any
  suitable subnets". Live-fixed (tagged 6 subnets). **Durable base-terraform fix still owed.**
- **OI-2026-06-07-2 (overlay vs bootstrap) — RECURRED, now BLOCKING.** Spoke apps
  carry placeholders (`domain`, `aws-load-balancer-ssl-cert` = `PLACEHOLDER_…`)
  meant to be overlaid at registration, but `bootstrap` self-heal reverts the
  overlays. Hand-overlaying domain + cert did NOT stick → the spoke NLB never gets a
  valid cert → `hello.platform.<domain>` unreachable. **This blocks the OI-2026-06-08-2
  hello e2e from a clean-build validation.** 2026-06-10: mechanism decided +
  consumer half implemented as ADR-0010 (ApplicationSets templating
  cluster-Secret fact annotations — the ADR-0005 "ConfigMap" wording proved
  infeasible for annotation-borne facts and is superseded); the producer half
  rides OI-2026-06-07-1.
- **OI-2026-06-08-2 (hello e2e)** — the HARD bounded-poll check is authored + merge-ready
  (PR #210), but CANNOT be clean-build-validated until OI-2026-06-07-2 is fixed
  (placeholders won't overlay durably). Also a transient: a Kyverno webhook blip
  (`kyverno-svc: no endpoints`) briefly errored the xdatabase XR reconcile (not a
  code bug; the RDS Instance itself is `Ready`).

---

## OI-2026-06-11-1 — CI-harness hardening queue (retro 2026-06-11-224 remedies R2/R3/R4)

**Status:** queued — owner-approved 2026-06-11; deferred ONLY because a
concurrent session was actively dispatching against these workflows (changing
verifier/chainsaw behavior mid-flight, or pushing R4's throwaway probe
branches, would interfere with it). Implement in the next session with no
concurrent CI consumer. Full designs: `retrospective/2026-06-11-224.md` Part 3.

1. **R2 — chainsaw-verify waits for an in-flight run.** Extract the lookup
   into `.github/scripts/` (hermetically unit-tested, like the live-evidence
   gate), bounded poll ~10 min: green run → pass; queued/in-progress run for
   the HEAD SHA → wait; nothing/terminal-failure only → fail with the dispatch
   instructions. Observed race: verifier red at PR-open, 4 min before the
   already-dispatched chainsaw run (27310302147) went green; remedy was a
   manual lookup re-run.
2. **R3 — pin the kind download to GitHub releases.** `chainsaw.yml`:
   `kind.sigs.k8s.io/dl/...` → `github.com/kubernetes-sigs/kind/releases/download/...`
   (+ `--retry 3`), version still from versions.env. Observed: a 268s connect
   timeout killed run 27301407702 before any scenario executed.
3. **R4 — diagnose verifier non-trigger on new-branch first pushes.**
   Inconsistent observation (3 stack branches: zero verifier runs on first
   push despite matching paths; #223's branch: triggered fine). Reproduce
   with a throwaway branch BEFORE changing anything; likely fix = add
   `pull_request` triggers with the same path filters.

Routing note: R2/R3 edit `.github/workflows/**` — the push token and the
GitHub MCP write tools refuse those paths; route through the jentic
`ext-github` bridge. R2's script logic gets a unit test in the same PR
(audit-before-enforce).

---

## OI-2026-06-10-1 — ACM Certificate external-name left empty by provider v2.5.0; selector-based references to it never resolve

**Status:** Composition-level fix BUILT 2026-06-10 (direct `status.certificateArn` patch via the composite, replacing `certificateArnSelector`) — the *provider anomaly itself* remains open/undiagnosed.
**Surfaced:** 2026-06-10, the first S1 clean build (fresh account 341221860475 <!-- noqa: account-id - run provenance, account rotates -->).

**What happened (observation):** the platform cluster XR stalled at `Ready=False,
Unready resources: cluster-cert-validation` for 50+ minutes. The real ACM cert
was ISSUED and its Certificate MR was `Synced=True, Ready=True` with
`status.atProvider.arn` populated — but its `crossplane.io/external-name`
annotation was **empty**. The CertificateValidation's `certificateArnSelector`
reference extractor reads exactly that annotation, so resolution retried
forever with "referenced field was empty (referenced resource may not yet be
ready)". Same v2.5.0 resource-identity bug class as the SecurityGroupIngressRule
observation (tf-aws#45303, docs/decisions/0008) — identity works internally,
external-name never written back.

**Durable fix (shipped):** the Composition patches
`spec.forProvider.certificateArn` directly from `status.certificateArn`
(Required policy; the composite-routed idiom the sibling validation Record
already uses). No live object was hand-edited; GitOps propagation of the
Composition unsticks the live MR.

**Still open (hypothesis, undiagnosed):** whether the empty external-name harms
the Certificate MR's own lifecycle (update/delete paths) on v2.5.0, and whether
other selector-based references in the estate can hit the same class. Next
step: check upstream provider-aws issues for the ACM identity fix; audit the
Compositions for remaining `*Selector` references to provider-identity fields
(`grep -n 'Selector:' crossplane/compositions/` — the remaining uses are
roleArnSelector/clusterNameSelector/nodeRoleArnSelector/certificateArnSelector-
class; each is a candidate for the same composite-routed replacement if it
bites).

---

## OI-2026-06-07-1 — spoke ArgoCD cluster Secret has no durable (GitOps) form

**Status:** durable producer BUILT 2026-06-10 (ADR-0010 PR-2) — **`pending clean-build verification`** (SUBSTRATE row 5; no live evidence exists until a from-scratch bring-up).
**Resolution (final, ADR-0010 PR-2 — supersedes the 2026-06-07 "plain ESO" line below):** two provider-kubernetes Objects in the `xspokeaccess-aws` Composition — a cluster-facts OBSERVE Object reading the paired XPlatformCluster XR (same name/namespace; also retires the `spec.oidcIssuer` placeholder overlay), and the `spoke-cluster-secret` writer assembling the registration Secret (five-fact contract annotations + selector labels + `awsAuthConfig`/`caData` config via `CombineFromComposite`), complete-or-absent via Required-policy patches. Hub `kubernetes.m.crossplane.io ClusterProviderConfig` (InjectedIdentity) + pinned `provider-kubernetes` SA + namespace-scoped RBAC (`crossplane/rbac/02-*`). Fork rationale + ESO capability verification: ADR-0010 "PR-2 resolutions" + `planning/adr-0010-cluster-facts/adr0010-pr2-producer-brief.md` (ESO *can* template annotations from remote data; decided on data flow — the facts are hub-local).
**Resolution (original 2026-06-07, superseded for THIS secret):** plain ESO — enable the EKS Cluster MR connection secret → `PushSecret` → AWS Secrets Manager → `ExternalSecret` with `target.template` assembling the cluster-secret `config` (caData-in-JSON). NOT provider-kubernetes, NOT XPlatformSecret. (ADR-0005's Alternatives rejection of provider-kubernetes is amended in place — its premise assumed the JSON assembly happened in provider references, not the Composition.)
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

**Recommended durable mechanism (2026-06-07; now IMPLEMENTED as refined by
ADR-0010 PR-2):** a provider-kubernetes `Object` in the XSpokeAccess
Composition assembling the `config` JSON via `CombineFromComposite` — with one
refinement: endpoint/caData are not *overlaid* onto the XR (overlays are the
banned pattern) but OBSERVED from the paired XPlatformCluster via a second,
Observe-only Object. RBAC + render fixtures + chainsaw shipped with the
implementation; live oracle authored at
`tests/live/checks/after/spoke-cluster-secret-live.sh`.

**Next step:** clean-build verification (SUBSTRATE order of operations) — a
fresh bring-up from committed source must produce the labeled Secret with the
full contract and a Successful ArgoCD connection, with zero manual steps. On a
previously hand-bootstrapped hub, delete the REST-bootstrapped secret at
cutover so the Object owns it.

---

## OI-2026-06-07-2 — registration-time ephemeral overlays fought by bootstrap selfHeal

**Status:** consumer half IMPLEMENTED (2026-06-10, ADR-0010) — `pending clean-build verification`, blocked on the producer (OI-2026-06-07-1).
**Resolution (final, ADR-0010 — supersedes the 2026-06-07 ConfigMap wording below):** the per-cluster facts (domain / subdomain / cert-ARN / external-dns-role-ARN / region) ride the spoke's ArgoCD cluster Secret as `k8-platform.io/*` labels+annotations; the spoke apps are per-add-on **ApplicationSets** whose cluster generators template those facts into helm values. NOT per-app Helm overlays; workloads (`hello`) stay AWS-agnostic (domain+subdomain only); no pausing bootstrap. The 2026-06-07 resolution's "per-cluster ConfigMap read by add-ons" carrier was found infeasible on tree-grounded review (cert/role facts land in chart-rendered Service/SA *annotations*, which cannot read ConfigMaps) — its principle is preserved, its carrier replaced. The ESO-baseline corollary (b) stands unchanged.
**Resolution (original, 2026-06-07 — carrier superseded):** make this part of the `XPlatformCluster` XRD: every cluster ships (a) a per-cluster ConfigMap of cluster facts (domain/region/cert-ARN/external-dns-role-ARN) the add-ons read from — NOT per-app Helm overlays — and (b) ESO + an IRSA `ClusterSecretStore` (ESO baseline in every cluster). Workloads (`hello`) stay AWS-agnostic. This removes the bootstrap-selfHeal-vs-overlay conflict (no pausing bootstrap).
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

**Status:** durable form BUILT 2026-06-10 — **`pending clean-build verification`** (SUBSTRATE row 3; recurred live in both auto-012 and auto-016 before this).
**Surfaced:** 2026-06-07, auto-012, spoke ingress-nginx NLB never provisioned.

**What happened:** mgmt + spoke share VPC `vpc-…`. The ELB-role subnets are tagged
`kubernetes.io/cluster/k8-platform-mgmt` but NOT `…/k8-platform-services`, so the
spoke's in-tree AWS cloud provider excluded them (they "belong" to another cluster)
and could not find subnets for the internet-facing ingress NLB. EKS only tags the
subnets in a cluster's own vpcConfig (the spoke uses private node subnets), so the
public ELB subnets were never tagged for the spoke.

**Fix applied live:** `aws ec2 create-tags … Key=kubernetes.io/cluster/k8-platform-services,Value=shared`
on the public (role/elb) and internal-elb subnets.

**Durable form (implemented):** `terraform/base` merges
`kubernetes.io/cluster/<name>=shared` onto the public (role/elb) and private
(role/internal-elb) subnets for every name in the new `hosted_cluster_names`
variable (default: every committed XPlatformCluster spec.name —
`k8-platform-services`, `k8-platform-workload1`).
`tests/unit/test_base_subnet_cluster_tags.sh` cross-checks the default
against every XPlatformCluster XR under `clusters/` so a new hosted cluster
cannot silently miss the tag (the lint caught workload1 on its first run).

**Next step:** clean-build verification — a fresh bring-up must place the
spoke ingress NLB with zero `create-tags` hand-fixes.

---

## OI-2026-06-07-4 — hub→spoke EKS-API security-group rule has no durable form

**Status:** durable rule BUILT 2026-06-10 — **`pending clean-build verification`** (SUBSTRATE row 2; recurred live in both auto-012 and auto-016 before this).
**Surfaced:** 2026-06-07, auto-012.

**What happened:** the hub ArgoCD app-controller (mgmt node SG `sg-…`) could not
reach the spoke EKS API (private endpoint) — the spoke EKS cluster SG had no inbound
443 from the mgmt nodes. Added live:
`authorize-security-group-ingress` 443 from the mgmt node SG to the spoke cluster SG.

**Durable form (implemented):** a `hub-eks-api-ingress` MR in the
platform-cluster Composition — the classic **`SecurityGroupRule`**, not
`SecurityGroupIngressRule` as originally sketched (provider-aws-ec2 v2.5.0
cannot observe the latter — tf-aws#45303, same constraint the
kube-relay-ingress rule documents). securityGroupId from the Cluster MR's
clusterSecurityGroupId (via XR status), source = `managementNodeSecurityGroupId`
newly published in the `cluster-network` EnvironmentConfig from
`module.eks.node_security_group_id`. Gated by
`tests/unit/test_hub_spoke_api_ingress.sh` + the regenerated render golden.

**Next step:** clean-build verification — a fresh spoke bring-up must be
reachable from the hub ArgoCD with zero `authorize-security-group-ingress`
hand-fixes.

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

## OI-2026-06-07-6 — static assertions masquerade as "tests"; built resources are never verified against the real cloud until a dependent fails

**Status:** **open — HIGH PRIORITY; fix first in the new session.** This is the
root-cause finding behind the entire auto-012 blocker chain.
**Surfaced:** 2026-06-07, auto-012 (user observation).

**The problem.** Almost every "test" in `tests/unit/` is a STATIC file assertion
(`yq`/`grep` over committed YAML/terraform): "the composition has field X", "the IAM
fixture lists action Y". These are LINTS, not tests of the built artifact. They catch
**regressions of things a human already knew to assert** — never **discovery** that a
thing we told the platform to create was never actually created or never actually
works. So the whole "oops, when I told it to create something it never did" class
(missing IAM perms → MR fails closed; wrong EKS auth mode → AccessEntry rejected;
SA-name ≠ trust subject → AssumeRole denied; missing subnet tags → no NLB) stays
**invisible until a downstream dependent trips over it**, live, one at a time. That
is exactly how all 8 auto-012 blockers were found.

**The principle (the fix discipline).** *Verify what you built, at the moment you
build it.* Every step that CREATES a resource — a Crossplane claim/XR, an IAM
role/policy, a helm release, a ConfigMap/Secret, an ArgoCD cluster registration, a
DNS record — must be IMMEDIATELY followed by a verification that the resource actually
exists and functions **against the real cloud/cluster**, not a static manifest
assertion. The build step is not "done" until that verification passes. A static
`yq` check is acceptable as a fast pre-flight lint; it is NOT the test.

**Chainsaw is currently used WRONG (user correction, 2026-06-07).** Running chainsaw
against **kind** only answers "is this valid Kubernetes / does the composition render
and pass admission" — syntax + validity. It does NOT build a real EKS cluster and does
NOT prove the product works. Even the gated `CHAINSAW_INCLUDE_REALAWS` scenarios run on
kind with **static/admin creds**, NOT the restricted Crossplane **IRSA role**, so they
would have MASKED the exact permission gaps that bit us (the crossplane role's missing
`iam:Tag…`/`UpdateAssumeRolePolicy`/`GetRolePolicy`/`rds:*` only fail when the real
Crossplane pod, under the real IRSA role, calls AWS on the real cluster). kind chainsaw
is, at best, a fast pre-flight lint — keep it as that, but stop treating a green kind
run as evidence the thing builds.

**The rule (not a schedule — a coupling):** when you implement a step that CREATES
something, you verify THAT thing, against the real cluster/cloud, as part of the same
step, EVERY time. Not nightly, not a separate gate that runs later — coupled to the
change. If the resource didn't actually build, the step is not done. "Run real
verification nightly/gated" is wrong precisely because it decouples the test from the
implementation; that decoupling is the bug.

**The systemic fix (the create-and-verify loop, applied to every create-step):**
1. **Verify against a REAL cluster — real Crossplane under the real IRSA role, building
   the real AWS resources (EKS cluster, spoke, RDS) — at the moment you author the
   create-step, every time.** This is the only faithful test of "does it build" and the
   only thing that surfaces IRSA-permission gaps (kind uses static/admin creds and
   masks them). kind chainsaw stays ONLY as a fast syntax/render pre-flight; a green
   kind run is never evidence the thing builds.
2. **Add a real hub→spoke integration test** (the flow with 6 of the 8 blockers):
   provision spoke → register → `https://hello.platform.<domain>` 200 → Keycloak boots
   against RDS. `tests/integration/` is the home (claim waits via
   `scripts/wait-for-claim.sh`; SPEC-S7).
3. **Use the `crossplane-claim-verify` skill at EVERY claim/XR apply** (it already
   waits for Synced/Ready AND verifies the underlying cloud resource exists/healthy) —
   make it a required step, not optional. For non-claim creations (IAM/helm/secret/
   registration), do the equivalent immediate AWS-API / ArgoCD-API existence check.
4. **Close the `[mgmt] e2e-verify` gaps** so the mgmt-stack/networking class is
   covered: check BOTH ArgoCD SAs (server AND application-controller) carry IRSA, check
   spoke registration `connectionState`, check shared-VPC subnet tags, check hub→spoke
   SG reachability.
5. `crossplane-iam-policy-completeness-audit` (proposed in retro 2026-06-07-165) is a
   STATIC stopgap for the IAM class — useful pre-flight, but it is a proxy; #1 is the
   real answer.

**Why this is HIGH PRIORITY:** every account rebuild re-pays the cost of finding this
class live, one dependent-failure at a time. Standing up the real verification gate
once converts "discover live, serially" into "fail in CI, all at once."

---

## OI-2026-06-05-5 — live ArgoCD sync unreachable from the Claude-Code-web sandbox

**Status:** **RESOLVED** — fixed by the dedicated `*.management.<domain>` ACM cert (auto-007 #149) and **re-confirmed this session (2026-06-07, auto-012)**: `argocd login` + `/healthz` 200 worked from the sandbox throughout the run. (Kept for the rationale record.)
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

### Issue A — resolution plan (NEXT SESSION, own PR — owner-directed 2026-06-07)

**Confirmed flaky 3/3** on PR #184 chainsaw runs (`27103469257`, `27103634369`,
`27103982795`): `claim-deletion-cleanup` fails with
`FAIL: ASM secret k8-platform/<uid> still exists after claim delete`. The
offending step is a **one-shot** check in
`tests/chainsaw/platform-secret/01-claim-deletion-cleanup/chainsaw-test.yaml`
(step "assert ASM secret is gone (out-of-band aws CLI check)", ~line 98–114):
it runs `aws secretsmanager describe-secret` exactly once immediately after the
XR delete and fails if the secret is still present. AWS Secrets Manager deletion
is eventually-consistent (and a scheduled delete leaves the secret present with a
`DeletedDate` until the recovery window elapses), so the one-shot describe
intermittently still finds it.

**Fix (correct, NOT a weaken — keep the assertion, make it respect eventual
consistency):** replace the single describe with a bounded poll (~30×5s) that
treats **either** `describe-secret` returning NotFound **or** the returned JSON
carrying a `DeletedDate` (scheduled for deletion) as success; only FAIL if the
secret is still fully present (no `DeletedDate`) after the poll window. Sketch:
```sh
set -eu
key=$(cat /tmp/scenario01-asm-key.txt)
for i in $(seq 1 30); do
  out=$(aws secretsmanager describe-secret --secret-id "$key" \
        --region "${AWS_REGION:-us-east-1}" 2>/dev/null) \
    || { echo "OK: $key gone (NotFound)"; exit 0; }
  printf '%s' "$out" | grep -q '"DeletedDate"' \
    && { echo "OK: $key scheduled for deletion"; exit 0; }
  echo "  still present (attempt $i/30); waiting..."; sleep 5
done
echo "FAIL: ASM secret $key still fully present after claim delete"; exit 1
```
Then dispatch `chainsaw.yml` for the fix SHA, confirm green (esp.
`claim-deletion-cleanup`), open the PR, and — once merged — re-dispatch chainsaw
for PR #184 HEAD and re-run `chainsaw-verify` so #184's gate clears, then merge
#184. **Do this in a NEW session: the account that ran #184 timed out and is
gone, so the fix cannot be chainsaw-validated until a fresh account is up.**

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

**Status:** **RESOLVED** (auto-016 audit) — the flaky `claim-deletion-cleanup`
ASM-secret-gone check was made a bounded poll (NotFound **or** `DeletedDate` ⇒ pass)
folded into #184; verified present in
`tests/chainsaw/platform-secret/01-claim-deletion-cleanup/chainsaw-test.yaml`
and chainsaw went green (auto-014). Re-run on a fresh account if it recurs. The
historical hypothesis text is retained below as the rationale record.

**(historical)** still hypothesis-level. The Issue B diagnosis does NOT explain
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

**Status:** **RESOLVED** (fix #156) — **live re-confirmed this session (2026-06-07, auto-012)**: all AWS child providers healthy, XSpokeAccess + XDatabase MRs reconciled on the rebuilt cluster.
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

**Status:** **RESOLVED** — **live re-confirmed this session (2026-06-07, auto-012)**: 12 crossplane-system pods healthy, single `provider-family-aws`, all AWS MRs reconciled. Original fix: Option A (rename +
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
run `27054926075`, main SHA `c3a6cb3`, account `211125540973`. FAILED at <!-- noqa: account-id - historical run provenance; account rotated -->
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
   providerrevision.../provider-family-aws-604659292671          False False ...v2.5.0 Active 5m1s   # noqa: account-id - quoted live kubectl output (rotated account)
   providerrevision.../upbound-provider-family-aws-604659292671  False False ...v2.5.0 Active 4m55s   # noqa: account-id - quoted live kubectl output (rotated account)
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
`kubectl describe providerrevision` on both revisions (the `provider-family-aws-*`
and `upbound-provider-family-aws-*` names; suffixes are account-derived) and
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
### OI-2026-06-06-4 — phase-5 xdatabase real-AWS chainsaw scenarios were nightly-gated (REOPENED — nightly is the disease, excise it)
**Status:** **RESOLVED** (auto-016 audit) — the nightly-gating mechanism was EXCISED
in auto-014 #188 (deleted the `CHAINSAW_INCLUDE_REALAWS` exclusion block + the two
`REAL-AWS / NIGHTLY` `xdatabase/{01-claim-creates-rds,02-deletion-cleanup}`
scenarios). Verified in auto-016: `grep CHAINSAW_INCLUDE_REALAWS tests/` returns
nothing and `tests/chainsaw/xdatabase/` holds only `00-xrd-establishes`. The gating
RDS live check is carried by `tests/live/` (the live-suite capstone), not a nightly
lane. Historical detail retained below.

**(historical)** REOPENED 2026-06-07 (owner-directed). The previous "resolution" —
tagging `xdatabase/01-claim-creates-rds` + `02-deletion-cleanup` `REAL-AWS / NIGHTLY`
and excluding them from the gating run via `CHAINSAW_INCLUDE_REALAWS`, with
render-fixtures + a unit test standing in for behavioral coverage — **is exactly
the decoupled-from-build / lint-substituted antipattern ADR-0006 forbids** (and
AGENTS §6.36: no nightly, no non-gating lane). A nightly nobody blocks on is a
test everyone ignores. **Excise it** — this requires a test rewrite, so it is a
**next-session** task (needs a fresh account to chainsaw-validate; AGENTS §6.35):
- Delete `tests/chainsaw/run.sh`'s `CHAINSAW_INCLUDE_REALAWS` exclusion block
  (lines ~406-425), the `REAL-AWS / NIGHTLY` headers on the two `xdatabase`
  scenarios, the `test_chainsaw_realaws_gated.sh` guard, and the real-AWS/nightly
  exemption in `test_chainsaw_golden_files_present.sh`.
- The RDS behavioral coverage moves to the **gating** live suite (`tests/live/`,
  fail-closed, dispatch-coupled — registry already owes it as
  `rds.aws.m.upbound.io/Instance` `defended_by: pending:P2`), NOT a nightly. Build
  that live check and confirm it gates green on the fresh account.
- Net: every behavioral check gates at its proper surface; nothing runs on a
  schedule that doesn't block. Same coverage, no nightly.

### OI-2026-05-28-1 recurrence note (auto-010)
`claim-creates-secret` timed out at 246s again on chainsaw run 27072199866
(ASM `CannotCreateExternalResource` / "asm-secret not yet ready" — the known
flake). Established remedy: re-kick. Durable fix still pending per the existing
OI-2026-05-28-1 entry (external-name change).

---

## OI-2026-06-08-1 — Crossplane provider role `Resource:"*"` not tightened (§14.3 deny tests deferred)

**Surfaced:** 2026-06-08, auto-014, decision brief
`planning/test-overhaul/decisions/auto-014-002-resource-star-tightening.md`.

**What:** `terraform/management/irsa.tf` grants the Crossplane provider role
`Resource = "*"` on the EKS, EC2Networking, IAM, RDS, ACM, and Route53Read
statements. FINAL-PLAN §3.3/§14.3 recommends tightening toward derived per-ARN
lists and shipping deny tests (negatives that prove a now-forbidden action is
denied).

**Decision (deferred, reviewed — two adversarial rounds):** do NOT tighten in
auto-014. Rationale: a too-tight policy fails the *next* bring-up's reconcile, not
at apply time — a high-blast-radius, slow-to-surface failure on the real platform.
The sandbox cannot run a clean `terraform apply` + teardown-rebuild to verify a
tightening still provisions, and AGENTS.md §6.35 forbids marking such a change
done without clean-build verification. A deny test for a denial that isn't
configured would be a test that "can't fire" (FINAL-PLAN §7).

**What we ruled in (adversarial Round 1, security-hawk, repo-grounded):** the IAM
statement IS safely narrowable when a validation window exists — every IAM role
the Compositions create matches `arn:aws:iam::<acct>:role/k8-platform-*`
(`k8-platform-cluster-<name>`, `k8-platform-nodegroup-<name>`,
`k8-platform-<clusterName>-external-dns`), and OIDC providers to
`arn:aws:iam::<acct>:oidc-provider/*`. RDS/EKS/ACM Describe ARNs are
non-derivable / not resource-scopeable — leave at `*`.

**Recommended guards when the tightening is taken up (Round-1 reviewers):**
1. A regression-guard unit test asserting the *current* broad scope, so a future
   *silent* narrowing is caught (today nothing asserts resource scope —
   `test_iam_required_actions.sh` checks ACTIONS, not `Resource`).
2. `# lpe-justified: OI-2026-06-08-1 expires:<date>` annotations on each retained
   wildcard — but only once the FINAL-PLAN §3.3 ceiling-lint that PARSES them is
   built (it is not yet), else the annotation is a comment no test enforces.

**Next concrete step:** implement `scripts/derived-arn-inventory.sh` (stub committed
this run), obtain a teardown-rebuild validation window, narrow the IAM statement to
the `k8-platform-*` role prefix + `oidc-provider/*`, ship the paired deny test
(it fires against a static policy condition, no bring-up needed), add the scope
regression guard. A cheap PRE-CHECK to add in the tightening PR:
`iam:SimulatePrincipalPolicy` statically verifies the narrowed policy's allow/deny
for known ARNs (no bring-up) — but it does NOT prove provisioning completeness
(an unanticipated ARN the narrowed policy now denies), so still pair with the
clean bring-up.

**Owner / trigger (so this is time-bound, not open-ended):** next account-rebuild
session; gating condition = a clean `management apply-and-verify` green run from a
fresh account is available to validate the narrowing does not break the next
reconcile.

---

## OI-2026-06-08-2 — hub→spoke end-to-end (real request to a spoke workload) not behaviorally tested

**Surfaced:** 2026-06-08, auto-014, decision brief
`planning/test-overhaul/decisions/auto-014-003-hub-spoke-curl-e2e.md`.

**What:** spoke (`k8-platform-services`) resources are verified after-the-fact via
read-only AWS describes (eks Cluster/NodeGroup/AccessEntry/AccessPolicyAssociation
all PASS). The actual data path — a real request reaching a spoke workload through
ingress — is NOT behaviorally tested.

**Decision (deferred, reviewed — two adversarial rounds):** pure-defer; do NOT
ship a self-gating SKIP-until-reachable stub. An adversarial reviewer (infra-realist)
showed a self-gating stub re-introduces the exact "silent skip reads green" disease
ADR-0006 kills: it sits in `checks/after/` SKIPping for months while the suite reads
green on other checks (the all-skipped⇒RED floor is suite-level, not per-check, and a
non-`COVERS` SKIP never triggers expect-full promotion). Deferring keeps the gap
*visible* (this OI) rather than masked by a rotting stub.

**Valuable finding to pursue first (Round-1 coverage-maximalist):** the spoke's
ingress-nginx is an internet-facing NLB; `hello.platform.<domain>` (ExternalDNS +
ACM) may be reachable by a plain public HTTPS `curl` with NO kube-API access, NO SSM
relay, and NO CIDR allowlist — making the §14.2 preconditions (and brief 004) moot
for the e2e. Investigate this public-NLB path before assuming the curl e2e needs
spoke kube reachability.

**When built, it MUST (Round-1 determinism-skeptic):** be a bounded poll (reuse
`wait_for`, ≥300s, interval 10–15s) on HTTP 200 *with the expected response body* —
covering NLB warm-up + DNS TTL + cert issuance + pod-ready — with the reachability
SKIP-gate kept SEPARATE from the service-ready poll, and ship as a HARD check
(expect-full / exit non-zero on a reachable-but-failing curl), never a silent skip.

**Evidence (probe run 2026-06-08, auto-014, read-only):**
`curl https://hello.platform.878302603783.realhandsonlabs.net` → host does NOT <!-- noqa: account-id - historical run provenance; account rotated -->
resolve (**NXDOMAIN**). The public hello endpoint is not materialized — ExternalDNS
has not created the record (and/or the registration overlay supplying the ephemeral
domain+cert has not run). So the public-NLB curl path is not yet available; the
deferral is confirmed by observation, not hypothesis. Separately, the spoke kube-API
IS reachable via the SSM relay (confirmed: `kubectl get nodes` on k8-platform-services
→ 2 Ready nodes), so a relay-based spoke e2e is an available fallback.

**Caveat (what a curl proves):** a successful `curl hello.platform.<domain>` proves
spoke ingress+app LIVENESS only; it does NOT exercise the hub's GitOps role. The
eventual e2e must pair it with a hub-side ArgoCD `spoke-hello` App Synced/Healthy
assertion to actually test hub→spoke.

**Next concrete step:** once the spoke app stack + ExternalDNS record exist
(`hello.platform.<domain>` resolves), author the bounded-poll curl e2e (wait_for,
≥300s, HTTP 200 + expected body) as a P5 HARD check, paired with the hub ArgoCD App
status assertion.
