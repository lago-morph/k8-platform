# auto-008 — How spoke clusters receive their add-on stack via GitOps

**Status:** Round 2 (final pending 2nd wave). Round 1 SUPERSEDED — see below.
**Run:** auto-007 long run, phase-3 spoke foundation.
**Blocks:** phase-3 spoke (ingress-nginx, ExternalDNS, hello), and by extension
phases 4 (observability), 5 (Keycloak), 6 (workload cluster) — every spoke
service is a third-party Helm chart deployed to a non-management cluster.

---

## Question

The management (hub) cluster installs ingress-nginx / ExternalDNS via Terraform
`helm_release`. The **platform (spoke) cluster cannot use Terraform** (REQ-NF-02:
GitOps only after management bootstrap). So the spoke's add-ons must be delivered
by ArgoCD from the hub. But the existing `k8-platform` AppProject
(`argocd/projects/k8-platform.yaml`) is deliberately locked down:

- `sourceRepos: [this repo only]` — comment: *"no third-party charts via Argo —
  those go through Crossplane/Helm in terraform."*
- `destinations: [https://kubernetes.default.svc, ns *]` — management only;
  comment: *"workload clusters get their own Project later."*
- `clusterResourceWhitelist` / `namespaceResourceWhitelist` cover only XRDs,
  ClusterSecretStore, ClusterPolicy, Namespace, external-secrets.io, and
  platform.k8-platform.io kinds — **not** Deployment/Service/Ingress/etc.

So: **what is the GitOps delivery mechanism for spoke add-ons, and how is the
dynamic cross-cluster data (cert ARN from `XPlatformCluster.status.certificateArn`,
the ephemeral root domain, the spoke subdomain) injected into it?**

A related constraint from history: **OI-2026-06-05-2** — `charts.crossplane.io`
returned 403 to the GitHub runner, forcing the Crossplane Helm chart to be
vendored as a digest-pinned tarball. Egress to public chart CDNs is NOT reliably
available in this environment (at least from the runner; ArgoCD-on-cluster egress
is untested).

## Alternatives

**A — Dedicated `platform-spoke` AppProject + ApplicationSet (cluster generator),
Applications reference UPSTREAM Helm charts (multi-source: chart repo + in-git
values), cert ARN/subdomain injected from the spoke cluster-Secret annotations.**
- Canonical ArgoCD hub-spoke pattern. Values live in git; chart pulled from
  upstream by ArgoCD running on the cluster.
- New AppProject scoped to the spoke destination + the specific chart repos +
  the workload kinds. Leaves `k8-platform` untouched (its lockdown intent holds).
- Cross-cluster data: the registration step annotates the spoke cluster Secret
  (`certArn`, `subdomain`, `domain`); the ApplicationSet cluster generator
  templates those into each Application's `helm.valuesObject` via `goTemplate`.
- Risk: depends on ArgoCD-on-cluster egress to chart CDNs (OI-2026-06-05-2 says
  the *runner* is blocked; the cluster may differ — untested).

**B — Vendor rendered manifests into this repo** (helm template at author time →
commit plain YAML under `platform-services/<svc>/manifests/`), ArgoCD syncs the
rendered YAML from THIS repo (sourceRepos stays this-repo-only).
- Matches the "no third-party charts via Argo" principle + the vendored-chart
  precedent (OI-2026-06-05-2). No cluster egress to CDNs needed.
- Heavier maintenance: every chart bump = re-render + re-commit; values are
  baked, so dynamic cert ARN/domain need a kustomize/replacement layer or a
  post-render substitution (ApplicationSet still injects via a kustomize patch).
- Bloats the repo with thousands of lines of rendered YAML per service.

**C — Crossplane provider-helm Releases on the spoke** (the hub's Crossplane
creates `Release` MRs targeting the spoke via a ProviderConfig built from the
spoke kubeconfig).
- Keeps everything in the Crossplane control plane; no second AppProject.
- Adds provider-helm + provider-kubernetes to the install; mixes the "ArgoCD
  deploys apps, Crossplane provisions infra" separation the design draws.
- Cross-cluster auth (spoke ProviderConfig) is as much work as ArgoCD spoke
  registration, plus a new provider surface.

## Decision (Round 1, best call)

**Option A** — `platform-spoke` AppProject + cluster-generator ApplicationSet,
upstream charts via multi-source Applications, dynamic data from spoke
cluster-Secret annotations — **with Option B (vendoring) as the pre-identified
fallback** if live ArgoCD egress to a chart CDN fails (same remedy as
OI-2026-06-05-2, applied per-chart only where needed).

Reasoning:
- The "no third-party charts via Argo" rule was written for the *management*
  cluster, which is Terraform-managed by design. The spoke is GitOps-only by
  REQ-NF-02 — it *must* get charts via Argo or via Crossplane; (A) is the
  smaller, more conventional surface than (C).
- A separate AppProject honors the existing `k8-platform` lockdown intent rather
  than broadening it — the project comment literally pre-authorizes "workload
  clusters get their own Project later."
- Values-in-git + annotation injection keeps the ephemeral cert ARN/domain out
  of committed files (AGENTS §8.1) while staying declarative.
- Vendoring (B) is strictly more work and repo bloat; adopt it surgically only
  if egress proves blocked, not preemptively for every chart.

## Downstream impact

- Phases 4/5/6 reuse the `platform-spoke` project + ApplicationSet pattern; each
  new service is one more Application (or ApplicationSet matrix entry) + an
  in-git values file. The decision here is the template for all of them.
- The spoke registration step must annotate the cluster Secret with `certArn`,
  `subdomain`, `domain` (the injection source of truth).

## Round-1 if-user-overrides rewind point

Revert the `auto-008` brief commit + the `argocd/projects/platform-spoke.yaml`
commit. No live resources are created by the project authoring itself.

---

## Round 2 — revised decision (folds in 3 adversarial reviewers)

Three real adversarial subagents (ArgoCD-expert, AWS/egress-expert,
simplicity/blog-expert) reviewed Round 1 cold and **converged** on a materially
better design. Round 1's "Option A as written" is superseded:

### Final decision

1. **Keep the new `platform-spoke` AppProject** (all 3 agreed) — but it must
   enumerate (a) `sourceRepos` = this repo **+ every upstream chart repo used**
   (ingress-nginx, external-dns, later kube-prometheus-stack/loki/alloy/keycloak),
   and (b) `clusterResourceWhitelist`/`namespaceResourceWhitelist` for the real
   workload kinds: Deployment, Service, Ingress, ConfigMap, Secret,
   ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding,
   CustomResourceDefinition, plus the destination scoped to the spoke
   (NOT `https://kubernetes.default.svc`). Leaves `k8-platform` lockdown intact.

2. **Phase 3 uses PLAIN per-service ArgoCD Applications** (`argocd/apps/spoke/`)
   with `destination.name: platform-spoke`, NOT an ApplicationSet (reviewers 1 &
   3). Rationale: exactly one spoke exists in phase 3; a cluster-generator buys
   zero fan-out and risks accidentally targeting the hub in-cluster destination
   (reviewer 1 F1). The **ApplicationSet refactor lands in phase 6** when the
   workload cluster makes fan-out real — and that refactor is its own blog post
   (before/after duplication). De-risks the egress fallback too (plain Apps
   re-point to vendored YAML trivially).

3. **Spoke AWS trust + IRSA are created by Crossplane MRs on the HUB**, not
   Terraform (reviewer 2 F2, keeps GitOps + Crossplane-first):
   - `OpenIDConnectProvider` MR (provider-aws-iam) against `status.oidcIssuer`
     — the spoke's IRSA anchor, which the cluster Composition deliberately omits
     (XRD header). `crossplane_aws` IRSA already grants
     `iam:CreateOpenIDConnectProvider` (irsa.tf:67) — no Terraform change needed.
   - external-dns IAM `Role` + `Policy` + attachment MRs, trust = spoke OIDC +
     `external-dns:external-dns` SA, Route53 scoped to the zone.
   - An EKS **`AccessEntry` + `AccessPolicyAssociation`** MR mapping the
     `${cluster_name}-argocd` IAM role to `AmazonEKSClusterAdminPolicy` on the
     spoke, so the ArgoCD application-controller can actually sync to it
     (reviewer 1 F5, reviewer 2 F6).

4. **Spoke ArgoCD cluster Secret** is built from the **EKS Cluster MR's
   `writeConnectionSecretToRef`** (endpoint + CA), with `aws`/exec auth using
   the argocd role (v2 has no XR connection secret — XRD lines 78-81). Labelled
   `argocd.argoproj.io/secret-type: cluster` + `k8-platform.io/cluster-role:
   spoke`.

5. **cert ARN reaches the spoke from the Composition**, decoupled from
   registration timing (reviewer 3 F2, reviewer 1 F2 race). The ingress-nginx
   Application's `aws-load-balancer-ssl-cert` value is sourced from a small
   ConfigMap/Secret the Composition (or a follow-on MR) writes into the spoke
   once `status.certificateArn` is populated (post-ISSUED), referenced by the
   ingress values — NOT a committed literal (ephemeral, AGENTS §8.1). Finalized
   live against the real cluster.

6. **ExternalDNS dual-instance fix (TDD per §6.2 — real latent bug):**
   - Spoke external-dns: `--txt-owner-id=k8-platform-platform`,
     `--domain-filter=platform.<domain>`, distinct `--txt-prefix` (e.g.
     `_edns-platform-`), `--policy=upsert-only`.
   - **Narrow the HUB external-dns** `domainFilters` from `var.domain` (whole
     zone) to `management.<domain>` — today it claims the entire zone and would
     clobber spoke records. Add a unit-test assertion that hub + spoke filters
     are disjoint.

7. **Egress is probed, not assumed** (reviewers 1 & 2): a one-shot probe Job on
   the live cluster hits the chart repos AND `registry.k8s.io` (image pulls are a
   separate egress path the brief missed) before committing to upstream charts
   for phases 4-6. OI-2026-06-05-2 was a CDN reputation-403 on the *runner* IP,
   NOT a network block — the cluster behind the NAT GW has different egress
   reputation, so Option A is likely fine; the probe confirms. Option B
   (vendoring) stays the per-chart fallback.

8. **Re-justify Option C's rejection** (reviewer 3 F3): not "mixing concerns" —
   C collapses the two-tool pedagogical split (ArgoCD deploys apps, Crossplane
   provisions infra) the blog series is built around, and adds provider-helm +
   provider-kubernetes for no capability ArgoCD lacks. Stays rejected.

### Round-2 downstream impact

Phases 4/5/6 inherit: the `platform-spoke` AppProject (extend `sourceRepos` per
chart), plain Applications in phase 4/5 → ApplicationSet refactor in phase 6, the
Crossplane-MR spoke-IRSA pattern (one Role MR per add-on that touches AWS), and
the Composition-sourced ephemeral-value pattern.

### Round-2 rewind point

Each artifact is its own commit on its own stacked branch; the morning summary
maps SHAs. No live AWS resource is created until the platform-cluster sync +
spoke registration, so all authoring is pure-git-reversible until then.

### Round-2 second adversarial wave

Dispatched on the revised design (2 reviewers, different angles: a
Crossplane-composition specialist + a security/blast-radius reviewer). Findings
folded into the implementing PRs.
