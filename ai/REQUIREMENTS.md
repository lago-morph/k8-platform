# Real-World Kubernetes Platform — Requirements

**Project name:** k8s-platform (working title)
**Version:** 1.0 (initial)
**Status:** Pre-implementation — approved for development

---

## 1. Purpose and Goals

### 1.1 Primary Goals

This project has two closely intertwined goals that drive all design decisions:

**Goal 1 — Learning platform.** Build a realistic, production-like Kubernetes platform on AWS for hands-on learning and experimentation with Crossplane, ArgoCD, and the broader cloud-native ecosystem. "Realistic" means it uses the same patterns, tools, and architecture that real enterprise deployments use — not simplified toy versions.

**Goal 2 — Blog post series.** Produce a documented, reproducible reference implementation that illustrates the gap between "toy" Kubernetes clusters (single cluster, manual cert management, no SSO, no secrets management, no observability) and one that meets the minimum bar for real-world use. Each major iteration is a blog post topic.

These goals reinforce each other: the learning platform *is* the blog subject, and the blog discipline forces the implementation to be explainable and reproducible.

### 1.2 What This Is Not

- Not a production system for running real customer workloads
- Not a general-purpose Kubernetes management tool or CLI product
- Not optimized for cost (ephemeral AWS environment acceptable)
- Not intended to be the starting point for production without significant hardening

---

## 2. Audience

**Primary audience (learning platform):** The author — a platform/infrastructure engineer with existing Kubernetes knowledge who wants deep hands-on experience with Crossplane, ArgoCD, GitOps patterns, and the integration of platform services.

**Primary audience (blog series):** Platform engineers and DevOps practitioners who understand basic Kubernetes and want to understand what a production-grade platform actually looks like and why each component exists.

---

## 3. Scope

### 3.1 In Scope

- AWS-hosted multi-cluster Kubernetes platform (EKS)
- Management cluster provisioned by Terraform (minimal scope)
- Platform services cluster and workload clusters provisioned by Crossplane
- ArgoCD hub-spoke GitOps managing all clusters from the management cluster
- Ingress (ingress-nginx) + ExternalDNS + cert-manager on each cluster
- Keycloak as the platform identity provider, federated to an upstream OIDC/SAML provider
- External Secrets Operator on all clusters, backed by AWS Secrets Manager
- Crossplane XRDs abstracting secrets and cluster provisioning
- Prometheus + Grafana + Loki on the platform services cluster, with agents on all other clusters
- Annotation-driven observability configuration
- Subdomain-per-cluster DNS pattern using a real domain

### 3.2 Out of Scope (explicitly deferred)

- Tenant-facing ArgoCD instances (tenants manage their own app deployments)
- Multi-tenancy isolation policies (network policies, OPA/Kyverno)
- Cost optimization (reserved instances, Karpenter, etc.)
- Disaster recovery and backup
- CI pipelines for application code
- Production hardening (node hardening, CIS benchmarks, etc.)

---

## 4. Functional Requirements

### 4.1 Base Environment (Iteration 0)

REQ-BASE-01: A VPC with public and private subnets, an internet gateway, and NAT gateways must exist before any cluster is provisioned.

REQ-BASE-02: A Route53 hosted zone for a real domain must exist and be usable by ExternalDNS across all clusters.

REQ-BASE-03: An upstream identity provider (AWS Cognito user pool or AWS Managed AD) must exist and be configurable as a SAML or OIDC source for Keycloak. This represents the "enterprise identity provider" that the platform slots into.

REQ-BASE-04: The base environment must be provisioned by Terraform and must be stable — it is not modified by subsequent iterations.

REQ-BASE-05: The base environment must be documented as "what the enterprise already has" so blog readers understand the assumed starting conditions.

### 4.2 Management Cluster (Iteration 1)

REQ-MGMT-01: The management cluster must be provisioned entirely by Terraform.

REQ-MGMT-02: Terraform scope for the management cluster must be strictly minimal: EKS cluster, dedicated private subnets in the existing VPC, IRSA roles, and installation of ArgoCD, Crossplane, and ESO. Nothing else.

REQ-MGMT-03: ArgoCD must be accessible at `management.<domain>` with a valid TLS certificate on completion of Iteration 1.

REQ-MGMT-04: The management cluster must be recoverable from a bad state by re-running Terraform. This is the core reason Terraform is used here and not Crossplane or ArgoCD.

REQ-MGMT-05: IRSA must be used for all AWS API access from pods. No long-lived AWS credentials may be stored in the cluster.

REQ-MGMT-06: Crossplane must be installed on the management cluster with the AWS provider configured via IRSA.

REQ-MGMT-07: ESO must be installed on the management cluster, configured to read from AWS Secrets Manager via IRSA.

### 4.3 Crossplane Foundations (Iteration 2)

REQ-XP-01: A `PlatformSecret` Composite Resource Definition (XRD) must be defined that abstracts secret management. A claim against this XRD must result in the secret being created in AWS Secrets Manager and an ExternalSecret resource being created to sync it into the cluster as a Kubernetes Secret.

REQ-XP-02: A base cluster XRD must be defined that encapsulates the standard pattern for provisioning a new EKS cluster: private subnets, EKS, node groups, IRSA roles, and kubeconfig secret.

REQ-XP-03: All Crossplane compositions must be managed via ArgoCD GitOps from the management cluster.

REQ-XP-04: The `PlatformSecret` XRD must work end-to-end before any other cluster is provisioned.

### 4.4 Platform Services Cluster (Iteration 3)

REQ-PLAT-01: The platform services cluster must be provisioned by Crossplane using the base cluster XRD.

REQ-PLAT-02: ArgoCD on the management cluster must deploy all platform services to the platform services cluster using a hub-spoke model.

REQ-PLAT-03: ingress-nginx must be installed and functional on the platform services cluster.

REQ-PLAT-04: ExternalDNS must be installed and must automatically create Route53 records for any Ingress resource created on the platform services cluster, under `platform.<domain>`.

REQ-PLAT-05: cert-manager must be installed and must automatically provision and renew TLS certificates for all Ingress resources using Let's Encrypt.

REQ-PLAT-06: At completion of Iteration 3, a test application deployed to the platform services cluster must be reachable at a subdomain of `platform.<domain>` with a valid TLS certificate, with no manual DNS or certificate steps required.

### 4.5 Observability (Iteration 4)

REQ-OBS-01: Prometheus, Grafana, and Loki must be installed on the platform services cluster as the central observability stack.

REQ-OBS-02: A Prometheus agent (or Grafana Alloy) must be installed on the management cluster and must ship metrics to the platform services cluster's Prometheus.

REQ-OBS-03: Grafana must be accessible at `grafana.platform.<domain>` with valid TLS.

REQ-OBS-04: Kubernetes resources on any cluster must be able to configure scraping and log collection via standard annotations (e.g., `prometheus.io/scrape`, `prometheus.io/port`).

REQ-OBS-05: All observability components must be deployed via ArgoCD GitOps from the management cluster.

### 4.6 Authentication (Iteration 5)

REQ-AUTH-01: Keycloak must be installed on the platform services cluster.

REQ-AUTH-02: Keycloak must be configured as an OIDC identity broker, federating authentication to the upstream provider (Cognito or AWS Managed AD) provisioned in Iteration 0.

REQ-AUTH-03: Keycloak must issue JWT tokens usable by workloads. User management must not be required in Keycloak itself — all users are managed in the upstream provider.

REQ-AUTH-04: ArgoCD on the management cluster must use Keycloak for SSO.

REQ-AUTH-05: Grafana must use Keycloak for SSO.

REQ-AUTH-06: Keycloak must be accessible at `auth.platform.<domain>` with valid TLS.

REQ-AUTH-07: Each EKS cluster that supports human kubectl access must have an associated OIDC identity provider configuration (`aws_eks_identity_provider_config`) pointing at the Keycloak `platform` realm. The `kubernetes` audience must be a public OIDC client in Keycloak with PKCE enabled (no client secret). The API server must extract the username from the `preferred_username` claim and groups from the `groups` claim, with both prefixed (e.g. `kc:`) so Keycloak-issued identities cannot collide with IAM-mapped identities.

REQ-AUTH-08: Group membership presented to Kubernetes must originate in Cognito. Keycloak's Cognito IdP configuration must include an attribute mapper that copies the Cognito group claim into a `groups` claim on the Keycloak-issued ID token. No group state may be created or maintained inside Keycloak; Keycloak's only role is brokering and token shaping.

REQ-AUTH-09: ClusterRoleBindings must exist that bind the prefixed Keycloak groups (e.g. `kc:k8s-admins`, `kc:k8s-viewers`) to standard cluster roles. These bindings must be managed as Kubernetes manifests under `clusters/<cluster>/` and deployed via ArgoCD. AWS IAM access via EKS Access Entries must remain available as a break-glass admin path independent of Keycloak.

REQ-AUTH-10: The repository must document the kubectl client setup for Keycloak-authenticated access (the `oidc-login` krew plugin and the kubeconfig stanza needed) so that a new operator can authenticate without IAM credentials.

### 4.7 First Workload Cluster (Iteration 6)

REQ-WL-01: A workload cluster must be provisionable by creating a Crossplane claim against the base cluster XRD with no manual AWS steps.

REQ-WL-02: A newly provisioned workload cluster must automatically receive: ingress-nginx, ExternalDNS, cert-manager, ESO, and a Prometheus/Loki agent — all via ArgoCD.

REQ-WL-03: The workload cluster must have its own subdomain (`workload1.<domain>`).

REQ-WL-04: Metrics and logs from the workload cluster must appear in the platform services cluster's Grafana automatically.

REQ-WL-05: A test application deployed to the workload cluster must be reachable at a subdomain of `workload1.<domain>` with valid TLS.

---

## 5. Non-Functional Requirements

REQ-NF-01: **Reproducibility.** The entire platform must be destroyable and rebuildable from scratch. This is required both for the ephemeral AWS environment and for blog post readers to follow along.

REQ-NF-02: **GitOps.** After Iteration 1, all changes to the platform must be expressed as Git commits. No manual `kubectl apply` or Helm installs after the management cluster is bootstrapped.

REQ-NF-03: **No long-lived credentials.** All AWS API access from cluster workloads must use IRSA. No static AWS credentials may appear in any manifest, secret, or Helm values file committed to Git.

REQ-NF-04: **Real domain and real TLS.** All platform services must use a real registered domain and Let's Encrypt certificates. Self-signed certificates are not acceptable.

REQ-NF-05: **Explainability.** Every architectural decision must be documentable with a clear "why." The implementation serves the blog series, so anything that cannot be explained clearly to a practitioner audience is a signal to simplify.

REQ-NF-06: **Iteration completeness.** Each iteration must end in a fully working, demonstrable state. No iteration may leave the platform in a state where a component is partially installed or non-functional.

---

## 6. Constraints

- AWS account is ephemeral (Pluralsight or similar); full rebuild from scratch must be feasible
- Single operator (the author); no team coordination requirements
- Terraform is used only for the base environment and management cluster; all other provisioning is Crossplane + ArgoCD
- Vault is explicitly out of scope as a secrets backend; AWS Secrets Manager is used instead

---

## 7. Lessons Learned from Previous Attempt

The previous implementation (`lago-morph/ai-k8s`) stalled for a documented reason: infrastructure for the tooling was built before anything actually worked end-to-end. Specifically:

- A full Python CLI (`mk8`) was built with layered architecture, property-based testing, and 95%+ coverage — but it could not yet provision or manage anything useful
- 273 tests were passing against code that had no end-to-end functionality
- The spec-driven development process (requirements → design → tasks, EARS format) consumed iteration cycles without delivering usable output

**Retained from the previous attempt:**
- The three-tier cluster architecture concept (though bootstrap cluster replaced by Terraform)
- The toolchain choices: EKS, Crossplane, ArgoCD, Helm, ExternalDNS, cert-manager
- The security practices: IRSA over static credentials, secure file permissions, secret masking
- The separation of "base environment" from "what we build"
- The read-only verification tooling pattern (kubectl/AWS CLI preferred over MCP servers for maturity reasons)

**Explicitly abandoned:**
- The Python CLI wrapper (`mk8`) — direct Terraform, shell scripts, and Kubernetes manifests instead
- The elaborate layered Python architecture
- The spec-driven development process with formal requirements phases before any implementation
- Coverage targets and property-based testing as gates on progress

**New constraint:** Each iteration must produce something usable before the next iteration begins.
