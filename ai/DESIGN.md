# Real-World Kubernetes Platform — Design

**Project name:** k8s-platform (working title)
**Version:** 1.0 (initial)
**Status:** Pre-implementation — approved for development

---

## 1. Architecture Overview

### 1.1 The Core Problem This Solves

Kubernetes tutorials show you how to deploy an application to a cluster. What they don't show you is everything that has to exist before that application can run in a way that meets real enterprise requirements: automatic TLS, SSO, secrets that don't live in Git, observability that works across clusters, and a management plane that can't be accidentally destroyed by the thing it manages.

This platform is an attempt to build that missing layer — the "boring infrastructure" that every real deployment has but almost no tutorial covers end to end.

### 1.2 Cluster Topology

```
┌─────────────────────────────────────────────────────────────────┐
│  Management Cluster (EKS)                                       │
│  Provisioned by: Terraform                                      │
│  Runs: ArgoCD (hub), Crossplane, ESO                           │
│  DNS: management.<domain>                                       │
│  Manages: everything below via GitOps + Crossplane             │
└───────────────────┬─────────────────────────────────────────────┘
                    │ ArgoCD hub-spoke
                    │ Crossplane provisions
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│  Platform Services Cluster (EKS)                                │
│  Provisioned by: Crossplane                                     │
│  Runs: ingress-nginx, ExternalDNS, ACM TLS, Keycloak,          │
│        Prometheus, Grafana, Loki                                │
│  DNS: platform.<domain>                                         │
└───────────────────┬─────────────────────────────────────────────┘
                    │ metrics/logs shipped here
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
┌──────────────────┐   ┌──────────────────┐
│ Workload Cluster │   │ Workload Cluster  │
│ (EKS)            │   │ (EKS)             │
│ workload1.<domain>│  │ workload2.<domain>│
│ Provisioned by:  │   │ Provisioned by:   │
│ Crossplane claim │   │ Crossplane claim  │
└──────────────────┘   └──────────────────┘
```

### 1.3 Why This Topology

**Why a separate management cluster?**
The management cluster runs ArgoCD and Crossplane — the tools that manage everything else. If ArgoCD managed its own cluster and a bad rollout broke it, you'd have no way to recover without manual intervention. By keeping the management cluster stable (provisioned by Terraform, not self-managed), a broken update to any other cluster is always recoverable.

**Why a separate platform services cluster?**
Platform services (Keycloak, Grafana, ingress) are shared infrastructure used by all tenant workloads. Isolating them means: platform upgrades don't risk tenant workloads; resource contention from workloads doesn't affect platform services; and the platform cluster can have different node types and scaling policies than workload clusters.

**Why Crossplane for workload clusters instead of Terraform?**
Once the management cluster exists, using Terraform to provision additional clusters would require either manual Terraform runs or a CI pipeline to trigger them. Crossplane lets you declare a new cluster by creating a Kubernetes manifest — which means ArgoCD can manage cluster provisioning the same way it manages everything else. New cluster = new Git commit.

---

## 2. Technology Decisions

### 2.1 Infrastructure Provisioning

**Terraform** — management cluster and base environment only.

*Why:* Terraform state lives outside the cluster, so it can always be used to recover or rebuild the management cluster regardless of what state the cluster itself is in. This is the "break glass" recovery mechanism. Using Terraform for more than the minimum would mean the GitOps principle (all changes via Git → ArgoCD) has exceptions, which reduces the educational value of the platform.

**Crossplane** — all other clusters and AWS resources.

*Why:* Crossplane allows infrastructure to be declared as Kubernetes manifests, which means ArgoCD can manage infrastructure the same way it manages applications. The learning goal of this project is specifically to get deep experience with Crossplane. Using Terraform for workload clusters would undermine that goal and create a two-system problem (changes in two places, two state stores, two tools to understand).

**Crossplane XRDs** — cluster provisioning and secrets abstraction.

*Why:* Raw Crossplane managed resources expose AWS-specific implementation details (specific resource names, ARN formats, etc.) to anything that consumes them. XRDs let us define platform-level abstractions (`PlatformCluster`, `PlatformSecret`) that hide AWS specifics. This mirrors what real platform teams do — developers interact with the platform API, not the cloud provider API.

### 2.2 GitOps

**ArgoCD** — hub-spoke model, management cluster as hub.

*Why ArgoCD over Flux:* Both are viable. ArgoCD was chosen because its UI is more useful for learning and demonstration (blog post screenshots), and because hub-spoke multi-cluster management is a first-class feature in ArgoCD via ApplicationSets and cluster secrets.

*Why hub-spoke:* The management cluster's ArgoCD instance holds credentials to all other clusters and manages what's deployed to them. Tenants don't have their own ArgoCD instances in scope. This is the simplest multi-cluster GitOps topology and the right starting point.

### 2.3 Secrets Management

**AWS Secrets Manager** — secrets backend.

*Why ASM over Vault:* Vault is a more complete secrets management solution but requires significant operational overhead: it needs to be unsealed, backed up, and its storage backend managed. For a platform whose primary purpose is learning and demonstration, that overhead is a distraction. ASM is a managed service that requires no operational attention, integrates cleanly with IRSA, and is what most AWS-native teams actually use.

*Why not Vault:* Vault's advantage (more features, cloud-agnostic) doesn't outweigh its cost here. The goal is to show secrets management patterns, not to operate Vault.

**External Secrets Operator** — Kubernetes integration layer.

*Why ESO over Secrets Store CSI Driver:* ESO syncs secrets into native Kubernetes Secret objects, which means existing applications need no changes to consume them. The CSI driver mounts secrets as files, which requires application awareness. ESO is also easier to reason about — the sync behavior is visible as ExternalSecret resources.

**`PlatformSecret` XRD** — abstraction layer over ASM + ESO.

*Why:* Without this abstraction, provisioning a secret requires knowing about both ASM (to create the secret) and ESO (to create the ExternalSecret). The XRD reduces this to a single claim. It also means the backend (ASM today, potentially something else tomorrow) can change without affecting anything that consumes secrets.

### 2.4 Ingress and TLS

**ingress-nginx** — ingress controller.

*Why:* The most widely deployed ingress controller. Straightforward to configure, well-documented, and what most practitioners will be familiar with. The point of this platform is not to be opinionated about ingress controllers — it's to show the pattern.

**ExternalDNS** — automatic DNS management.

*Why:* Manually creating Route53 records for every service defeats the purpose of a self-service platform. ExternalDNS watches Ingress resources and creates/updates Route53 records automatically. This is the pattern real platforms use.

**ACM (AWS Certificate Manager) via Crossplane** — automatic TLS.

*Why:* Manual certificate management doesn't scale and teaches bad habits. Each cluster's Crossplane Composition provisions a DNS-validated **ACM** wildcard certificate (`*.<subdomain>.<domain>`) and terminates TLS at the ingress-nginx NLB — the same mechanism the management cluster already uses, so the platform runs a single TLS path. The DNS validation also demonstrates why you need a real domain — self-signed certificates can't be used here. See `docs/decisions/0003`.

*Why ACM and not cert-manager + ACME:* The clusters are private and TLS terminates at the load balancer, so an in-cluster ACME issuer adds a second issuance/renewal mechanism (and ACME rate limits) for no benefit over the AWS-native, auto-renewing ACM cert the LB already consumes. cert-manager + Let's Encrypt is retained as a future option for in-cluster cert material — see `docs/future-enhancements.md`.

### 2.5 Identity and Authentication

**Keycloak** — platform identity provider.

*Why Keycloak:* Keycloak is the most complete open-source identity platform available. It supports OIDC, SAML, identity brokering, and JWT issuance. It's what real enterprise platforms use when they need a self-hosted identity layer.

**Identity brokering to upstream provider** — Keycloak delegates authentication to AWS Cognito or AWS Managed AD.

*Why:* This pattern is how real enterprise deployments work. The platform doesn't own user management — the enterprise identity system does. Keycloak sits in the middle, providing a consistent OIDC interface to all platform services regardless of what the upstream identity system is. It also means this demonstration doesn't require managing any users — authentication flows to the upstream provider.

*Why Cognito as the upstream:* It's fully managed, available in the ephemeral AWS environment, and demonstrates the "enterprise already has an IdP" pattern without requiring Active Directory infrastructure.

**JWT tokens for workloads** — workloads authenticate to each other using Keycloak-issued JWTs.

*Why:* This is the OIDC/JWT pattern that service meshes, API gateways, and modern applications all use. Keycloak issuing JWTs that workloads can verify against Keycloak's JWKS endpoint is a real pattern that works without a service mesh.

**Kubernetes API server federated to Keycloak** — human `kubectl` access is authenticated by Keycloak, not by AWS IAM.

*Why:* Real platform teams don't hand out IAM users so engineers can run `kubectl`. They federate the API server to the same identity provider that powers everything else, so leaving the company revokes cluster access in one place. EKS supports this through `aws_eks_identity_provider_config`, which registers an external OIDC issuer with the API server.

*Two distinct OIDC roles to keep straight:*
- **EKS cluster as OIDC issuer** — the cluster signs ServiceAccount JWTs that AWS IAM trusts. This is how IRSA works. Unrelated to Keycloak.
- **EKS API server as OIDC client** — the API server validates JWTs issued by Keycloak. This is how human users authenticate. Unrelated to IRSA.

*Authentication flow for a human user:*

```
kubectl ──(oidc-login plugin)──► browser ──► Keycloak ──► Cognito ──► back to Keycloak
                                                                          │
                                                              issues ID token (JWT)
                                                                          │
kubectl ◄──────────────────────────────────────────────────────────────────┘
   │
   │  Authorization: Bearer <keycloak-jwt>
   ▼
EKS API server ──► fetches JWKS at https://auth.platform.<domain>/realms/platform/protocol/openid-connect/certs
              ──► verifies signature; extracts `preferred_username` and `groups`
              ──► hands user + (prefixed) groups to k8s RBAC
```

The API server never talks to Cognito directly — Keycloak is the only identity provider it knows about. Cognito sits behind Keycloak as the user store, consistent with ADR-004.

*Why Cognito groups, not Keycloak groups:* REQ-AUTH-03 says no user management in Keycloak, and group membership is user management. Cognito groups are mapped through Keycloak's Cognito IdP attribute mapper into a `groups` claim on the issued JWT. Keycloak shapes the token; it does not own the data.

*Why a username/group prefix (`kc:`):* EKS supports exactly one external OIDC provider per cluster, but IAM-based authentication remains active alongside it as a break-glass path. Prefixing keeps Keycloak-derived identities in their own namespace so a Keycloak group named `admins` can never collide with an IAM-mapped principal named `admins`.

*Why IAM stays as break-glass:* Keycloak runs on the platform cluster. If Keycloak is broken, you still need a way to fix it. EKS Access Entries provide that path. It is intentional, not a workaround.

### 2.6 Observability

**Prometheus + Grafana + Loki** — central observability stack on platform services cluster.

*Why this stack:* The de facto standard for Kubernetes observability. Grafana's dashboard ecosystem, Prometheus's query language, and Loki's log aggregation together cover the three pillars (metrics, logs) in a way that's well understood and well documented.

**Hub model — agents on each cluster, storage on platform cluster.**

*Why:* Storing metrics and logs on each workload cluster would mean operators need to access each cluster separately to investigate issues. Centralizing on the platform cluster gives a single pane of glass. The hub model also means adding a new workload cluster automatically adds its metrics to the central stack (as long as the agent is deployed there).

**Annotation-driven configuration.**

*Why:* Standard Prometheus annotations (`prometheus.io/scrape: "true"`, etc.) are the lowest-friction way for application teams to opt into scraping. They require no knowledge of Prometheus ServiceMonitor CRDs and work with the standard scraping configuration.

### 2.7 AWS Networking

**One VPC, multiple private subnet pairs per cluster.**

*Why one VPC:* Simplicity. Cross-VPC communication requires VPC peering or Transit Gateway, which adds cost and complexity. For a learning platform, a single VPC is the right trade-off.

*Why private subnets per cluster:* Each cluster gets its own pair of private subnets (one per AZ minimum). This gives clean network isolation between clusters while staying in the same VPC. It also mirrors real deployments where clusters don't share subnets.

**IRSA for all AWS API access.**

*Why:* IRSA (IAM Roles for Service Accounts) is the correct way to give Kubernetes workloads AWS API access. It scopes permissions to a specific service account in a specific namespace, uses short-lived tokens automatically rotated by the EKS token webhook, and leaves no static credentials anywhere. The alternative — putting AWS access keys in secrets — is a security antipattern that this platform explicitly avoids.

### 2.8 DNS Pattern

**Subdomain per cluster: `<cluster>.<domain>`**

*Why:* This pattern is clean, predictable, and mirrors real deployments. Each cluster has a clear namespace in DNS. Services within a cluster get subdomains: `grafana.platform.example.com`, `auth.platform.example.com`, `app1.workload1.example.com`. ExternalDNS is configured per cluster to only manage records under that cluster's subdomain, preventing one cluster from accidentally overwriting another's records.

---

## 3. Repository Structure

```
k8s-platform/
├── terraform/
│   ├── base/                  # Base environment (VPC, Route53, Cognito)
│   └── management/            # Management cluster (EKS, IRSA, ArgoCD, Crossplane, ESO)
├── argocd/
│   ├── apps/                  # ArgoCD Application and ApplicationSet manifests
│   └── projects/              # ArgoCD Project definitions
├── crossplane/
│   ├── compositions/          # Crossplane Compositions
│   ├── xrds/                  # CompositeResourceDefinitions
│   └── claims/                # Example claims (not environment-specific config)
├── clusters/
│   ├── management/            # Resources deployed to management cluster
│   ├── platform/              # Resources deployed to platform cluster
│   └── workload-template/     # Template for workload cluster resources
├── platform-services/
│   ├── ingress/               # ingress-nginx Helm values
│   ├── cert-manager/          # (deferred — see docs/future-enhancements.md; TLS is ACM via Crossplane)
│   ├── external-dns/          # ExternalDNS configuration
│   ├── keycloak/              # Keycloak Helm values and realm config
│   ├── observability/         # Prometheus, Grafana, Loki stack
│   └── eso/                   # ExternalSecret templates and ClusterSecretStore
└── docs/
    ├── decisions/             # Architecture decision records
    ├── iterations/            # Per-iteration design and blog notes
    └── diagrams/              # Architecture diagrams
```

---

## 4. Iteration Plan

Each iteration has a defined end state — a thing you can use or demonstrate — before the next begins.

### Iteration 0: Base Environment

**What:** Terraform provisions the shared AWS foundation.

**Components:**
- VPC with public and private subnets across 2 AZs, IGW, NAT gateways
- Route53 hosted zone for `<domain>`
- AWS Cognito user pool with at least one test user, configured as an OIDC provider

**End state:** `aws route53 list-hosted-zones` shows the zone. A test user can authenticate against Cognito. Nothing cluster-related exists yet.

**Blog angle:** "What the enterprise already has — and why your tutorial skipped it."

### Iteration 1: Management Cluster

**What:** Terraform provisions a minimal EKS cluster with ArgoCD, Crossplane, and ESO installed.

**Components:**
- Private subnets for management cluster (2 AZs)
- EKS cluster with managed node group
- IRSA roles for: ArgoCD, Crossplane AWS provider, ESO
- Helm install of ArgoCD (via Terraform helm provider)
- Helm install of Crossplane with AWS provider (via Terraform)
- Helm install of ESO (via Terraform)
- Ingress for ArgoCD UI with ExternalDNS annotation; TLS terminated at the ingress NLB by the base ACM wildcard certificate
- ArgoCD accessible at `argocd.management.<domain>` with valid TLS

**Design note:** ingress-nginx is installed on the management cluster by Terraform so that the ArgoCD UI is accessible at the end of this iteration. TLS uses the ACM wildcard certificate from `terraform/base` terminated at the NLB (no cert-manager — see `docs/decisions/0003`). This is the only exception to the "ArgoCD manages everything" rule — the management cluster's own ingress stack is Terraform-managed to avoid the chicken-and-egg problem.

**End state:** `kubectl get pods -A` on the management cluster shows everything running. ArgoCD UI loads at `argocd.management.<domain>` with a valid certificate.

**Blog angle:** "The management cluster — why Terraform and why so little of it."

### Iteration 2: Crossplane Foundations

**What:** ArgoCD (now managing itself) deploys Crossplane XRDs and compositions. The `PlatformSecret` XRD is proven end-to-end.

**Components:**
- ArgoCD Application pointing at `crossplane/` in the Git repo (ArgoCD now self-manages via GitOps)
- `PlatformSecret` XRD and Composition: claim → ASM secret created + ExternalSecret created → Kubernetes Secret synced
- Base cluster XRD and Composition (not yet invoked — defines the pattern)
- ClusterSecretStore resource on management cluster pointing at ASM

**End state:** Apply a `PlatformSecret` claim manifest. Observe the secret appear in ASM. Observe the Kubernetes Secret appear in the cluster. Delete the claim and observe cleanup.

**Blog angle:** "Crossplane XRDs — why you want an abstraction layer between your teams and AWS."

### Iteration 3: Platform Services Cluster

**What:** Crossplane provisions the platform cluster; ArgoCD deploys the standard platform stack to it.

**Components:**
- Crossplane `XPlatformCluster` XR creating: EKS cluster, node group, IRSA roles, and a DNS-validated wildcard ACM certificate (`*.platform.<domain>`) — see `docs/decisions/0003`
- ArgoCD ApplicationSet targeting the platform cluster
- ingress-nginx (NLB terminates TLS with the cluster's ACM cert), ExternalDNS (scoped to `platform.<domain>`)
- A test application deployed at `hello.platform.<domain>` with automatic DNS and TLS

**End state:** Navigate to `hello.platform.<domain>` in a browser. Valid TLS certificate. No manual DNS or cert steps were taken.

**Blog angle:** "Automatic TLS and DNS — what ACM (via Crossplane) and ExternalDNS actually do and why you need them."

### Iteration 4: Observability

**What:** Central Prometheus/Grafana/Loki stack on platform cluster; agent on management cluster.

**Components:**
- kube-prometheus-stack on platform cluster (Prometheus, Grafana, Alertmanager)
- Loki on platform cluster
- Grafana Alloy (or Prometheus agent mode) on management cluster, remote-writing to platform cluster
- Grafana accessible at `grafana.platform.<domain>` with TLS
- Dashboard showing management cluster nodes, pods, and ArgoCD metrics
- Loki showing management cluster pod logs

**End state:** Log into Grafana. See management cluster metrics. See management cluster logs. Add a new annotation to a pod and see it appear in Grafana.

**Blog angle:** "Observability across clusters — why annotation-driven scraping works and how to set it up."

### Iteration 5: Authentication

**What:** Keycloak on platform cluster; SSO wired to Cognito; ArgoCD and Grafana use Keycloak; `kubectl` access to all clusters federated to Keycloak.

**Components:**
- Keycloak via Helm on platform cluster, accessible at `auth.platform.<domain>` with TLS
- Keycloak realm `platform` configured with Cognito as OIDC identity provider, including an attribute mapper that lifts the Cognito group claim into a `groups` claim on issued JWTs
- ArgoCD configured to use Keycloak OIDC for SSO
- Grafana configured to use Keycloak OIDC for SSO
- `PlatformSecret` claims used for all Keycloak client secrets
- Keycloak `kubernetes` OIDC client (public, PKCE) for `kubectl` users — group-membership mapper enabled
- `aws_eks_identity_provider_config` on management and platform clusters pointing at the Keycloak `platform` realm, with username claim `preferred_username`, groups claim `groups`, and prefix `kc:`
- ClusterRoleBindings under `clusters/<cluster>/rbac/` that bind `kc:k8s-admins` to `cluster-admin` and `kc:k8s-viewers` to `view`, deployed via ArgoCD
- Cognito groups `k8s-admins` and `k8s-viewers` created in the base environment with at least one test user assigned to each
- `docs/operations.md` updated with the `oidc-login` krew plugin install + kubeconfig snippet

**End state:** Log into ArgoCD and Grafana using a Cognito user. Run `kubectl get pods` from a workstation that has only the `oidc-login` plugin installed and a kubeconfig pointing at Keycloak — no AWS credentials, no IAM principal mapping. Removing the user from their Cognito group revokes cluster access on the next token refresh.

**Blog angle:** "SSO for platform services *and* the API server — federating EKS to Keycloak and why you should never hand out IAM users for kubectl."

### Iteration 6: First Workload Cluster

**What:** Crossplane provisions a workload cluster; ArgoCD deploys the standard agent stack; a test app runs on it.

**Components:**
- `PlatformCluster` claim for `workload1`
- ArgoCD ApplicationSet entry for workload1 cluster, deploying: ingress-nginx, ExternalDNS (scoped to `workload1.<domain>`), ESO, Alloy observability agent (TLS is the ACM cert from the cluster Composition — docs/decisions/0003)
- Workload1 cluster metrics and logs appear in platform Grafana
- Test application at `hello.workload1.<domain>` with TLS

**End state:** A new cluster exists. It has TLS, DNS, secrets management, and observability — automatically, from a single Crossplane claim and a Git commit to the ApplicationSet.

**Blog angle:** "Adding a workload cluster — what 'day 2 operations' look like when the platform is done right."

---

## 5. Security Model

### 5.1 AWS IAM

All pods that need AWS API access use IRSA. Each IRSA role is scoped to a specific service account in a specific namespace. No role grants more than the minimum permissions needed.

Key IRSA roles:
- Crossplane AWS provider: EC2, EKS, IAM (for cluster provisioning), Secrets Manager (for `PlatformSecret`)
- ESO: Secrets Manager read-only
- ExternalDNS: Route53 change access scoped to the cluster's subdomain zone
- Crossplane AWS provider: ACM + Route53 change access to provision and DNS-validate each cluster's wildcard certificate

### 5.2 Secrets

No secrets in Git. Ever. The `PlatformSecret` XRD exists specifically to enforce this pattern. Secrets needed at bootstrap time (e.g., ArgoCD initial admin password) are generated and stored in ASM by Terraform, then synced to the cluster by ESO.

### 5.3 Network

All EKS nodes are in private subnets. The EKS API server endpoint can be public (required for Terraform and local kubectl access) but with CIDR restrictions. Ingress-nginx load balancers are internet-facing (in public subnets) but terminate TLS and proxy to private cluster services.

---

## 6. What "Production-Ready" Means Here

This platform demonstrates the *minimum* set of components a real deployment needs. It does not demonstrate everything a production system requires. Specifically, these are explicitly out of scope and would be needed for a true production deployment:

- Node and container hardening (CIS benchmarks, seccomp, AppArmor)
- Network policies (east-west traffic restriction between workloads)
- Pod Security Standards enforcement
- Backup and disaster recovery
- Multi-AZ and multi-region resilience testing
- Cost controls and resource quotas
- Audit logging to a SIEM
- Vulnerability scanning for images
- Tenant isolation (separate namespaces, RBAC, network policies per tenant)

The blog series should be explicit about this boundary: "here's the floor, not the ceiling."

---

## 7. Architecture Decision Records

### ADR-001: Terraform for management cluster, not Crossplane

**Decision:** Use Terraform to provision the management cluster.

**Context:** Crossplane runs on the management cluster. If Crossplane managed the management cluster's own EKS resources, a bad Crossplane update could render the management cluster unrecoverable without manual AWS console intervention. Additionally, the ArgoCD instance on the management cluster manages everything else — if ArgoCD managed itself, a bad rollout could break the management plane.

**Consequences:** Terraform state must be stored remotely (S3 + DynamoDB). Changes to the management cluster (node group sizing, new IRSA roles) require Terraform runs, not GitOps. This is acceptable — the management cluster is expected to be stable and rarely changed.

### ADR-002: AWS Secrets Manager over Vault

**Decision:** Use AWS Secrets Manager as the ESO backend, not HashiCorp Vault.

**Context:** Vault requires operational management: unsealing, storage backend, backup, upgrade procedures. For a platform whose purpose is learning Crossplane, ArgoCD, and multi-cluster patterns, Vault's operational overhead is a distraction. ASM is fully managed, integrates natively with IRSA, and is what AWS-native teams actually use.

**Consequences:** The platform is AWS-specific for secrets. A real production deployment might prefer Vault for cloud-agnosticism. The `PlatformSecret` XRD abstraction means the backend could theoretically be swapped — but that's a future concern.

### ADR-003: Crossplane XRDs for cluster and secret abstraction

**Decision:** Define `PlatformCluster` and `PlatformSecret` XRDs rather than using raw Crossplane managed resources.

**Context:** Raw managed resources expose cloud-provider implementation details. XRDs let the platform define its own API — the same pattern real platform teams use to provide self-service infrastructure to developers without exposing AWS specifics.

**Consequences:** XRD design requires upfront thought. Compositions are more complex to write and debug than raw managed resources. The payoff is a cleaner interface for anything that consumes platform resources.

### ADR-004: Keycloak as identity broker, not identity provider

**Decision:** Keycloak federates to an upstream provider (Cognito) rather than managing users itself.

**Context:** Managing users in Keycloak directly would mean: user provisioning steps during setup, password management, no connection to a real enterprise identity system. The realistic pattern is that an enterprise already has an identity system, and the platform connects to it. Using Cognito as the upstream means the demo requires no user management while still exercising the real federation pattern.

**Consequences:** Cognito must be provisioned as part of the base environment. Keycloak configuration is more complex (identity provider configuration, attribute mapping). The payoff is a more realistic and educational demonstration.

### ADR-005: Hub-spoke ArgoCD over per-cluster ArgoCD

**Decision:** One ArgoCD instance on the management cluster manages all other clusters.

**Context:** Per-cluster ArgoCD would mean: each cluster independently manages its own state, there's no central view of what's deployed where, and adding a new cluster requires bootstrapping a new ArgoCD instance. Hub-spoke gives a single pane of glass and makes the management cluster the authoritative source of platform state.

**Consequences:** The management cluster's ArgoCD holds cluster credentials for all managed clusters. If the management cluster is unavailable, no GitOps changes can be applied to any cluster (though existing workloads continue running). This is an acceptable trade-off for a platform of this scale.

### ADR-006: No bootstrap cluster (previous approach abandoned)

**Decision:** Do not use a local kind cluster as a bootstrap cluster. Use Terraform directly for the management cluster.

**Context:** The previous project (`lago-morph/ai-k8s`) used a local kind cluster running Crossplane to provision the EKS management cluster. This added complexity (kind cluster lifecycle, kubeconfig management, Crossplane on a throwaway cluster) without adding value. Terraform does the same job more reliably with better state management and no local cluster to manage.

**Consequences:** Terraform is now required as a local tool. The "everything is Kubernetes" purity is broken for the management cluster — which is the right trade-off.

### ADR-007: EKS API server federates to Keycloak; Cognito stays behind Keycloak; IAM is break-glass

**Decision:** Configure each EKS cluster's API server with a single external OIDC provider — the Keycloak `platform` realm — for human `kubectl` authentication. Do not configure Cognito as an OIDC provider on the API server directly. Keep AWS IAM authentication enabled as a break-glass admin path. Source group membership from Cognito and pass it through Keycloak as a claim mapper; do not store group state in Keycloak.

**Context:** EKS supports at most one external OIDC identity provider per cluster, in addition to the always-on AWS IAM path. Two design questions follow: which provider gets that slot, and where do groups live?

For the provider slot, the choice is Keycloak vs Cognito directly. ArgoCD, Grafana, and any future workload that needs SSO already point at Keycloak (ADR-004). If the API server pointed at Cognito, every component would need to know about both IdPs, the `client_id` audiences would multiply, and adding a future upstream IdP (Active Directory, Okta) would require touching every cluster's API server config. Pointing the API server at Keycloak means there is one OIDC issuer the platform cares about, regardless of what sits behind it.

For groups, the choice is Cognito vs Keycloak. REQ-AUTH-03 says user management does not live in Keycloak, and group assignment is user management. Cognito already supports groups, and Keycloak's IdP configuration includes attribute mappers that can lift a claim from the upstream token into the issued token. So the "right" answer falls out of existing constraints.

For IAM, removing it would mean a broken Keycloak takes the cluster offline for administration. EKS Access Entries are cheap to keep around and provide the only realistic recovery path. The cost of leaving them in place is one more thing to audit; the cost of removing them is occasional total loss of cluster access.

**Consequences:**
- Cognito group state must be created in Iteration 0 (the base environment) for the federation to have anything to pass through. The base module gains a `cognito-groups.tf` or similar.
- Keycloak realm configuration is more involved: Cognito IdP setup, attribute mappers, the `kubernetes` public client with PKCE, a Group Membership mapper on that client.
- Username and group prefixes (`kc:`) are mandatory to keep Keycloak-derived identities from colliding with IAM-mapped ones in RBAC bindings.
- The kubectl client side requires the `oidc-login` krew plugin. This is one more local tool for operators to install. Documented in `docs/operations.md`.
- API-server OIDC config is part of cluster-bring-up but cannot be wired until Keycloak is healthy. Iteration 5 takes the dependency. Earlier iterations rely on IAM for `kubectl`, which is fine.
- Token refresh latency (typically minutes) bounds how fast removing a user from a Cognito group actually revokes cluster access. Acceptable for a learning platform; would warrant token lifetime tuning in production.

### ADR-008: Tooling gaps are escalations, not design problems

ADRs 001–007 record platform-architecture decisions. ADR-008 is the first
operating-policy ADR in this section — a binding rule about *how the agent
works*, not about *what the platform is*. It belongs in `ai/DESIGN.md`
because the cost of getting it wrong is paid in the platform's code (see
the consequences below for the concrete history), and because the
operating rules and the architecture they produce are intertwined enough
that splitting them across two documents loses more than it gains.

**Decision:** When an agent driving this project discovers that a tool,
API, CLI, or capability required by a documented procedure is unavailable
in its execution environment, the default response is to flag the gap to
the user as a platform-tooling issue and ask whether to (a) escalate to
platform owners and wait, (b) build a scoped workaround, or (c) defer
the dependent task. The agent must not silently design and ship a
workaround under the assumption the limitation is permanent. Workarounds
are built only after the user has explicitly chosen path (b), and only
within the scope agreed in that choice.

**Context:** On 2026-05-23 the agent was asked to "Start testing phase 1."
The `ai/testing-guidelines.md` §3 procedure prescribed multiple
`workflow_dispatch` calls; the GitHub MCP toolset the agent had access to
did not expose a workflow-dispatch primitive, and neither `gh` CLI nor
direct GitHub API access was available. The agent's response — at the
user's invitation, but without first asking whether the gap should be
escalated — was to design and ship a 31-file workaround built around a
`.trigger-action.json` commit-driven trigger (issue #18, PR #19). PR #19
was merged on its own merits. Within days it was reverted entirely,
because the proper fix was direct GitHub API access for the agent (commit
`140ba12`, "Remove sandbox-workaround auto-triggers from CI").

The workaround was competently built, rigorously tested (52 unit tests,
3 e2e tests), and had a clean validation surface. None of that
mattered: it was the wrong response to the underlying gap. The right
response was "I cannot dispatch workflows — this is a platform-tooling
issue; should I escalate, work around, or wait?" — surfaced *before* any
design work began, not after the work was already underway with a draft
PR open.

Workarounds for platform limitations carry three asymmetric costs that
are easy to underweight at the moment they're proposed:

1. **The limitation is often temporary.** Platform tooling improves on
   timescales (days to weeks) shorter than most workarounds expect.
   `.trigger-action.json` was obsolete before the test harness around
   it was a week old.
2. **Workarounds become load-bearing.** Tested, documented infrastructure
   is hard to remove even when its underlying reason has gone away. The
   replacement design (direct API access) had to be explicitly fenced
   against being merged with the workaround machinery (commit `8a98ad7`,
   "Fence ext-github-design.md against synthesis with repo cruft").
3. **The platform owners don't learn what's needed.** A workaround that
   ships without escalation means the platform team never hears the
   signal "agents in this environment cannot dispatch workflows." The
   underlying gap stays unfixed for the next project that hits it.

The cost of the escalation question itself is one round of conversation.
The cost of an unnecessary workaround is the workaround's full
implementation cost plus the cleanup cost plus the diversion of design
attention away from the proper fix.

**Consequences:**

- The agent's default reaction to "I cannot do X in this environment" is
  to flag and ask, not to silently route around. This applies to missing
  CLIs, restricted APIs, sandbox limitations, file-write restrictions,
  and identity/permission gaps. The "follow procedure without asking"
  clauses in `CLAUDE.md` do not override this — those clauses prescribe
  *executing* the procedure, not *substituting* for it when its
  prerequisites aren't met.
- When the user does authorize a workaround (path (b)), the workaround
  must carry an explicit sunset annotation per the companion proposed
  ADR ("Sandbox/platform workarounds carry an explicit sunset
  condition") — a comment in the file header naming the limitation,
  who's tracking the fix, and the condition under which the workaround
  should be removed. Without that annotation the workaround rots into
  permanent infrastructure.
- Acceptance of a workaround is scoped: agreeing to "build a workaround
  for X" does not authorize follow-on scope (a test harness, a parallel
  doctrine section, a new dispatch matrix) without a second
  scope-expansion checkpoint. Scope expansion goes through the same
  flag-and-ask discipline.
- The companion `decommission-workaround` skill
  (`retrospective/2026-05-22-24/decommission-workaround-spec.md`)
  handles the removal side of the lifecycle once the underlying
  limitation lifts. ADR-008 governs the creation side; the skill
  governs the disposal side.
- Future operating-policy ADRs — if the project accumulates them — may
  warrant moving to a separate section header ("Operating Decisions")
  to keep the architecture ADRs distinct. For one entry, a same-section
  ADR with the framing above is sufficient.
