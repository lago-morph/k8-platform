# auto-004 — Phase 3 execution plan (platform-services cluster)

**Status:** DRAFT, gated on phase 1 + phase 2 confirmed green.
**Author:** auto-004 lead agent, 2026-05-29.

Phase 3 = DESIGN.md Iteration 3 / REQ-PLAT-01..06: Crossplane provisions the
platform-services EKS cluster via the `PlatformCluster` XRD (its **first
live invocation**), then ArgoCD deploys the standard platform stack to it
hub-spoke, ending with a test app reachable at `hello.platform.<domain>`
with automatic DNS + valid TLS.

## Current scaffolding (what exists)

- `crossplane/xrds/platform-cluster.yaml` + `crossplane/compositions/platform-cluster.yaml` — XRD + Composition, **render-validated offline this run** (9-doc golden: 2 IAM roles + 4 attachments + EKS Cluster + NodeGroup + XR). Never applied to live AWS yet.
- `clusters/platform/00-namespace.yaml` + `clusters/platform/platform-cluster-claim.yaml` — the `XPlatformCluster` XR, but with **`subnet-REPLACE-ME-AZ*` placeholders** that fail admission by design.
- `argocd/apps/platform-cluster-claim.yaml` — ArgoCD Application, **manual-sync only** (no `automated:`), targets `path: clusters/platform` on `main`.
- `platform-services/{ingress,external-dns,cert-manager,observability,keycloak,eso}/` — all empty `.gitkeep`. **The entire platform stack is unauthored.**

## Live inputs (account 975049983446, queried this run)

- VPC `vpc-0670ddff37608b82c` (10.0.0.0/16).
- Private subnets: `subnet-05e6d645fcb6f33c5` (us-east-1a), `subnet-02536846b210de89f` (us-east-1b), both named `k8-platform-private-*`, tagged `Project=k8-platform`, `Environment=dev`, `kubernetes.io/role/internal-elb=1`. (There are also separate `k8-platform-mgmt-*` and `k8-platform-public-*` subnets.)
- Route53 zone `975049983446.realhandsonlabs.net.` (`/hostedzone/Z0182461NZM4YE192TO8`).

## Key decisions (need decision briefs + adversarial review per autonomous-run)

### D1 — How does the PlatformCluster claim get its subnet IDs? (BLOCKER)

The claim hardcodes `subnetIds`, but **AGENTS §8.1 forbids committing
account-ephemeral IDs** (subnet IDs are rotated with the account). Options:
- **D1-a (recommended): tag-based `subnetIdSelector` in the Composition.**
  Replace the explicit `spec.forProvider.vpcConfig.subnetIds` patch with a
  `subnetIdSelector.matchLabels` (or `matchTags`) on the EKS Cluster MR,
  selecting `Project=k8-platform` + a tier discriminator. **Problem:** the
  private subnets are only distinguished from mgmt/public subnets by their
  `Name` tag (`k8-platform-private-*`); there is no single exact-match tag
  that isolates exactly the 2 private subnets. → base module likely needs a
  dedicated tag (e.g. `k8-platform/subnet-tier=private`). That is a phase-0
  terraform change (small) feeding phase-3.
- **D1-b: ArgoCD does NOT hardcode; an operator substitutes real IDs at sync
  time** (the current placeholder design). Rejected for GitOps — manual edit
  per account, and the edited IDs would still land in git on commit.
- **D1-c: a small terraform output → CI step writes the subnet IDs into the
  claim at sync time** (templated). More moving parts.

Lead lean: **D1-a + a phase-0 tag addition.** Needs the two-round brief.

### D2 — ApplicationSet kubeconfig source (v2 connection-secret repoint)

Handoff phase-3 note + the XRD header: v2 removed XR-level connection
secrets, so the platform cluster's kubeconfig is on the **EKS Cluster MR's
own `writeConnectionSecretToRef`**, not an XR-aggregated
`platform-cluster-kubeconfig`. The ArgoCD ApplicationSet (cluster generator)
that registers the spoke cluster must read kubeconfig from that MR secret.
Decision: how to register the spoke (ArgoCD cluster Secret) from the MR
connection-secret — a small glue controller, an ESO PushSecret, or a manual
`argocd cluster add`. Needs a brief.

### D3 — cert-manager ClusterIssuer: Let's Encrypt staging vs prod

REQ-PLAT-05 wants real TLS. Lab accounts + a real Route53 zone can do DNS-01.
Decision: start with LE **staging** (avoid rate limits during iteration),
flip to prod for the final hello-app TLS check. Low-risk; brief-lite.

### D4 — ExternalDNS scoping to `platform.<domain>`

REQ-PLAT-04: ExternalDNS on the platform cluster must only manage
`*.platform.975049983446.realhandsonlabs.net`. `--domain-filter` +
`--zone-id-filter` (or a dedicated sub-hosted-zone). Brief-lite.

## Execution sequence (once phase 1 + 2 are green)

1. **D1 brief** (2 rounds, ≥3 real reviewers each). If D1-a: add the private-subnet tag in `terraform/base`, re-apply phase 0, then switch the Composition to a `subnetIdSelector`. Re-render the golden (SPEC-S9), re-dispatch the `xrd-establishes` chainsaw.
2. Fill `clusters/platform/platform-cluster-claim.yaml` to use the selector (drop placeholders + the kubeconform-skip header).
3. Sync `platform-cluster-claim` (manual) → provision the real EKS cluster (~20 min). Verify via `crossplane-claim-verify` skill + live `aws eks describe-cluster`.
4. **D2 brief** + register the spoke in ArgoCD.
5. Author `platform-services/ingress` (ingress-nginx), `external-dns` (D4), `cert-manager` (D3) as ArgoCD apps (automated sync OK — only the cluster claim is manual).
6. Author the hello app + Ingress at `hello.platform.<domain>`.
7. Verify: browse to `hello.platform.<domain>`, valid TLS, no manual DNS/cert steps (REQ-PLAT-06).

## Stacked-PR shape

- PR (stack): D1 brief + base subnet tag + Composition selector + re-render golden.
- PR (stack): platform-cluster claim wired + provisioned (manual sync; document the run).
- PR (stack): D2 + ArgoCD spoke registration.
- PR (stack): ingress-nginx + ExternalDNS + cert-manager apps.
- PR (stack): hello app + e2e TLS verification.

## Morning-review items this raises

- **D1 subnet-selection design** — recommend D1-a (tag-selector + phase-0 tag); confirm before changing the base terraform module.
- Real cluster provisioning cost: phase 3 runs a 2nd EKS cluster (t3.medium×2) for the duration; 2 (mgmt) + 2 (platform) = 4 of the 9-instance EC2 quota.
