# Blog Series — Post Outlines

**Series working title:** Real-World Kubernetes: From Tutorial to Production Architecture
**Status:** Outlines approved, not yet written

For series intent, audience, and writing approach see BLOG-OVERVIEW.md.

---

## Post 1: The Gap Between Tutorial Kubernetes and Real Kubernetes

**Role in series:** Introductory. Sets up the problem the entire series addresses.

**Not about:** Any specific technology or implementation.

**Central argument:** A tutorial cluster gets you running an application. A real cluster needs to answer a set of questions that tutorials never surface: who can authenticate, where do secrets come from, how do TLS certificates get provisioned and renewed, how do you know something is broken before users tell you, how do changes get applied safely, and how do you recover when something goes wrong. The jump from "I understand Kubernetes" to "I can architect a production platform" involves a whole category of decisions that most practitioners have never had to make.

**Key points:**
- What a tutorial cluster gives you and what it leaves out
- The category of problems that only appear at platform scale: certificate lifecycle, secret rotation, consistent identity, multi-team access control, change auditability
- What organically grown clusters typically look like in practice — TLS managed manually or not at all, secrets in ConfigMaps or environment variables, no SSO so every service has its own login, observability added after incidents rather than before
- The reference implementation this series is built around: what it covers and what it explicitly does not cover

**Embedded failure mode:** The organic cluster — what it looks like when each of these problems is solved reactively rather than by design.

---

## Post 2: Single Cluster or Multi-Cluster — And Why It's Not a Simple Answer

**Role in series:** Foundational topology decision. Everything downstream assumes this choice has been made.

**Central argument:** Multi-cluster is not obviously correct. Single cluster with namespace isolation is genuinely viable for many teams and has real advantages. The decision depends on team size, workload characteristics, and how much operational overhead you can absorb. We use multi-cluster here, but most of what follows applies equally to both.

**Key points:**

*Arguments for single cluster:*
- Simpler networking — no cross-cluster communication to manage
- Lower cost — fewer control planes, fewer NAT gateways, simpler load balancer topology
- Less operational overhead — one cluster to upgrade, one kubeconfig to manage
- Namespace isolation with good RBAC is sufficient for many teams
- Right choice for smaller teams where operational simplicity outweighs blast radius concerns

*Arguments for multi-cluster:*
- Smaller blast radius — a platform upgrade gone wrong doesn't take application workloads with it, and vice versa
- Cleaner separation between platform services (shared infrastructure) and workload clusters (tenant-owned)
- Different clusters can have different upgrade cadences, node types, and security policies
- Matches organizational boundaries — platform team owns platform cluster, teams own their workload clusters
- Better for environments with genuinely different compliance or security requirements per workload

*Why we use multi-cluster here:*
- The learning goal is to understand patterns that apply at scale — multi-cluster patterns apply whether you end up with 2 clusters or 20
- The blast radius argument matters even at small scale when the "blast" is your GitOps plane going down
- This is explicitly not "multi-cluster is better" — it is "multi-cluster fits this particular use case"

*What stays the same either way:*
- Almost every other decision in this series (secrets management, identity, observability, ingress) applies equally to single and multi-cluster deployments
- The component choices don't change; only the topology of how they're deployed

**Embedded failure mode:** What happens in a single cluster when a platform upgrade goes wrong and takes application workloads with it.

---

## Post 3: GitOps — Why Your Change Mechanism Is an Architectural Decision

**Role in series:** Establishes the change management pattern that everything else depends on.

**Central argument:** Most people think of GitOps as a deployment tool. It is actually a decision about where authority lives and how changes are made. The choice of change mechanism has architectural consequences that are hard to retrofit later.

**Key points:**

*What GitOps gives you:*
- Audit trail as a side effect — every change is a Git commit with author, timestamp, and diff
- Declarative desired state — the cluster reconciles toward what Git says, not toward what someone last ran
- Recovery path — any cluster can be restored to a known state by pointing it at a Git ref
- Natural gate between "someone wrote this" and "this is running" — pull request review, CI checks

*What you give up or trade off:*
- Higher initial complexity — ArgoCD itself has to be set up and managed
- Slower "emergency" changes — the temptation to kubectl apply directly is real and hard to resist
- Requires discipline — GitOps only works if everyone uses it; one person with kubectl access who bypasses it creates drift

*Alternatives and when they make sense:*
- CI pipelines pushing directly (helm upgrade, kubectl apply from CI): simpler to set up, works well for application deployments, but lacks the reconciliation loop — if something changes the cluster state directly, CI doesn't notice
- Manual kubectl: fine for experimentation, not viable for anything requiring auditability or repeatability
- Other GitOps tools (Flux): viable alternative to ArgoCD, different trade-offs around UI, multi-tenancy model, and configuration approach

*ArgoCD hub-spoke vs per-cluster:*
- Hub-spoke: one ArgoCD instance on the management cluster holds credentials to and manages all other clusters. Single pane of glass, management cluster is authoritative for all cluster state. If management cluster is unavailable, no GitOps changes can be applied (workloads continue running)
- Per-cluster: each cluster manages itself independently. More resilient to management cluster failure, but no central view, and adding a new cluster means bootstrapping a new ArgoCD instance
- We use hub-spoke because: single pane of glass matters for a learning/demonstration platform, and management cluster availability is not a concern here

**Embedded failure mode:** What "who applied that and when" looks like when you manage five clusters without GitOps — the audit trail that doesn't exist when you need it.

---

## Post 4: The Management Cluster Problem — Who Manages the Manager?

**Role in series:** Explains the specific bootstrapping problem and the Terraform decision.

**Central argument:** Crossplane and ArgoCD have to run somewhere. That somewhere cannot safely manage itself. This is a specific, concrete problem with a specific solution — and the solution matters more than which tool you use to implement it.

**Key points:**

*The bootstrapping problem:*
- ArgoCD manages what gets deployed to clusters. If ArgoCD manages its own cluster's infrastructure, a bad rollout can break the management plane with no recovery path except manual AWS console intervention
- Crossplane provisions clusters. Crossplane runs on the management cluster. Crossplane cannot provision the cluster it runs on
- Something outside the cluster must create the management cluster and get it to a state where ArgoCD and Crossplane can take over

*Why Terraform here:*
- Terraform state lives outside the cluster — it can always be used to recover or rebuild the management cluster regardless of what state the cluster is in
- We already know Terraform well — the job is narrow enough that the tool choice matters less than the skill level
- This is explicitly not "Terraform is best for this." It is "Terraform works, we know it, and the scope is small enough that its limitations don't matter"

*What "minimal Terraform footprint" means:*
- EKS cluster, subnets, IRSA roles, Helm install of ArgoCD + Crossplane + ESO
- Nothing else. Once these are running, ArgoCD takes over and Terraform is not touched again for normal operations
- The boundary is deliberate: anything managed by Terraform cannot benefit from GitOps. Keeping Terraform scope minimal keeps GitOps scope maximal

*Alternatives that satisfy the same requirement:*
- Pulumi: same outcome, different language, valid choice if your team knows it better
- Raw CloudFormation or CDK: more verbose, but satisfies the "state outside the cluster" requirement
- A well-documented manual process: technically viable for a one-person project, operationally fragile for a team
- "Crossplane all the way down" is not possible — Crossplane has to run somewhere that was provisioned by something else

**Embedded failure mode:** What happens if ArgoCD manages its own cluster's infrastructure and a bad Helm upgrade breaks the ArgoCD deployment itself.

---

## Post 5: Secrets — Why "Just Use Kubernetes Secrets" Isn't Enough

**Role in series:** Component decision — secrets management.

**Central argument:** Kubernetes Secrets are not encrypted at rest by default, and the workflow of managing them typically ends with secrets in Git. External secrets management solves the "secrets in Git" problem and adds rotation, auditing, and access control that Kubernetes Secrets don't provide.

**Key points:**

*What's wrong with Kubernetes Secrets alone:*
- Base64 is not encryption — anyone with read access to the secret object or the etcd backup has the plaintext
- The natural GitOps workflow is to commit everything to Git — Kubernetes Secrets end up in Git unless you actively work around it
- No rotation mechanism — changing a secret means manually updating the Secret object or re-running whatever created it
- No audit trail — who read this secret, when, from where

*Why external secrets management:*
- Secrets live in a dedicated store with access controls, audit logging, and rotation support
- ESO syncs secrets into Kubernetes Secret objects — existing applications need no changes
- The GitOps repo contains ExternalSecret manifests (references to secrets) not the secrets themselves

*ASM vs Vault:*
- Vault: more capable, cloud-agnostic, fine-grained policies, dynamic secrets. Also: you have to operate it — unsealing, storage backend, HA setup, backup, upgrade procedures. Another stateful service to manage
- ASM: fully managed, native IAM integration via IRSA, no operational overhead, what most AWS-native teams actually use. Less capable than Vault for advanced use cases (dynamic secrets, complex policies)
- The choice depends on: whether you're committed to AWS, whether you want to operate another stateful service, and whether you need Vault's advanced capabilities
- We use ASM because: we're already AWS-committed, we don't want to operate Vault, and the learning goal is secrets patterns not secrets operations

*Raw ESO vs Crossplane XRD abstraction:*
- Raw ESO: create an ExternalSecret manifest per secret, referencing the ASM path explicitly. Fine for a single cluster or small number of secrets
- Crossplane XRD (`PlatformSecret`): a claim-based API that hides ASM paths, ExternalSecret configuration, and cluster-specific details. Consuming teams declare "I need a secret called X" without knowing anything about ASM or ESO
- The XRD is a platform API, not a technical requirement. It pays off when: multiple clusters need the same secret abstraction, you want to change the backend without touching every consumer, or you want platform teams to own the implementation and consuming teams to use a simple API
- We use the XRD because: it demonstrates the platform API pattern that is the whole point of using Crossplane

**Embedded failure mode:** What "secrets in Git" actually looks like in a real incident — the committed .env file, the rotation that requires updating 12 manifests, the audit finding that nobody can answer "who had access to this credential."

---

## Post 6: TLS, DNS, and Ingress — The Three Things That Have to Work Together

**Role in series:** Component decision — ingress, certificate management, DNS automation.

**Central argument:** cert-manager, ExternalDNS, and ingress-nginx are often set up independently and then cause problems for each other. They form a system, and understanding them as a system is what makes them work reliably.

**Key points:**

*How the three components interact:*
- ingress-nginx: receives traffic, terminates TLS, routes to services. Needs a valid certificate and a DNS record pointing to it
- ExternalDNS: watches Ingress resources, creates Route53 records automatically. Removes the manual "create a DNS record" step
- cert-manager: watches Ingress resources with the right annotations, requests certificates from Let's Encrypt, stores them as Secrets, renews them automatically. Removes the manual "get a certificate" step
- Without all three working together, at least one step is manual. Manual steps don't scale and don't get done at 2am

*Why DNS-01 over HTTP-01 for ACME challenges:*
- HTTP-01 requires the Let's Encrypt servers to reach your cluster over the internet on port 80
- Cluster nodes are in private subnets — HTTP-01 doesn't work
- DNS-01 proves domain ownership by creating a DNS TXT record via Route53 — works regardless of cluster network topology, also works for wildcard certificates

*The subdomain-per-cluster pattern:*
- Each cluster gets its own subdomain: `management.example.com`, `platform.example.com`, `workload1.example.com`
- ExternalDNS on each cluster is scoped to only manage records under that cluster's subdomain
- Prevents one cluster from accidentally overwriting another's DNS records
- Mirrors real enterprise DNS delegation patterns — each cluster "owns" its subdomain

*Why a real domain is required:*
- Let's Encrypt cannot issue certificates for internal or made-up domains
- Self-signed certificates create browser warnings and don't work for automated certificate verification
- This is one of the things that distinguishes a real platform from a local development setup

**Embedded failure mode:** What certificate management looks like without cert-manager — the expiry alert at 2am, the manual renewal process, the "we forgot to renew the staging cert" incident, the wildcard certificate that's shared across environments because renewing per-service is too painful.

---

## Post 7: Identity — Why You Want a Broker, Not Direct Integration

**Role in series:** Component decision — authentication and identity.

**Central argument:** Integrating each platform service directly to your identity provider creates a maintenance and consistency problem that compounds as the number of services grows. An identity broker (Keycloak) provides a single integration point to the upstream provider and a consistent OIDC interface to everything downstream.

**Key points:**

*The direct integration problem:*
- ArgoCD needs OIDC configuration. Grafana needs OIDC configuration. Each application needs OIDC configuration. Each one has slightly different attribute mapping, slightly different group handling, slightly different token validation
- When the upstream IdP changes something — a new claim format, a new group structure, a certificate rotation — you update it in every service independently
- Revoking a user's access requires removing them from every service independently, or hoping the upstream IdP revocation propagates correctly to each OIDC client

*What Keycloak as a broker gives you:*
- One integration to the upstream provider. When the upstream changes, you fix it once in Keycloak
- Consistent OIDC interface to all downstream services regardless of what the upstream provides
- A place to do attribute mapping, group transformation, and role assignment centrally
- The ability to add, remove, or change upstream providers without touching any downstream service

*"Don't manage users in Keycloak" design:*
- Keycloak federates authentication to Cognito (or AD, or Okta) — users authenticate against the enterprise system that already exists
- Keycloak translates the upstream identity into a consistent format and issues JWTs
- No user management required in Keycloak itself. This matches how real enterprise deployments work — the platform team does not own the user directory

*JWT tokens for workload auth:*
- Keycloak issues tokens that services can verify against Keycloak's JWKS endpoint
- No service mesh required for basic service-to-service authentication
- Not as complete as mTLS everywhere, but much simpler to implement and operationally understand
- Right level of complexity for a platform focused on demonstrating patterns

*Why Keycloak specifically:*
- Most complete open-source identity platform available — OIDC, SAML, identity brokering, JWT issuance
- What real enterprise platforms use when they need a self-hosted identity layer
- Alternatives (Dex, Authentik) are valid; Keycloak has the most complete feature set and the most real-world deployment history

**Embedded failure mode:** What per-service SSO integration looks like at scale — each service with its own login, inconsistent group handling, the "we can't revoke access consistently" incident, the 6-service update required when the IdP rotates its signing certificate.

---

## Post 8: Observability Across Clusters — Centralize or Federate?

**Role in series:** Component decision — observability topology.

**Central argument:** The same hub-vs-distributed question that applies to ArgoCD applies to observability. The trade-offs are similar and the reasoning follows the same pattern.

**Key points:**

*Per-cluster observability:*
- Each cluster runs its own Prometheus, Grafana, Loki
- Resilient — platform cluster outage doesn't affect a workload cluster's ability to observe itself
- Operationally expensive — N clusters means N observability stacks to maintain, upgrade, and monitor
- Fragments the view — investigating an incident that spans multiple clusters means accessing multiple Grafana instances

*Centralized observability (hub model):*
- Platform cluster hosts Prometheus, Grafana, Loki
- Agents on each cluster (Prometheus agent mode or Grafana Alloy) scrape locally and remote-write to the platform cluster
- Single Grafana instance covers all clusters — cross-cluster correlation is possible
- Adding a new cluster automatically adds its metrics to the central stack (as long as the agent is deployed)
- Platform cluster becomes a dependency for observability — if it's down, you lose the central view (but local workloads continue running)

*Why we use the hub model:*
- Single pane of glass matters for the learning and demonstration goals
- The agent-based approach means workload cluster observability doesn't depend on the platform cluster — agents buffer locally if the remote write endpoint is unavailable
- Operational simplicity: one stack to maintain, one Grafana to configure, one place to set up dashboards and alerts

*Annotation-driven configuration:*
- Standard Prometheus annotations (`prometheus.io/scrape: "true"`, `prometheus.io/port`, `prometheus.io/path`) are the lowest-friction onboarding for application teams
- No knowledge of ServiceMonitor CRDs required
- Works with the standard scrape configuration — annotations are not a Prometheus-specific feature, they're a convention

*The three pillars and what we cover:*
- Metrics: Prometheus + Grafana
- Logs: Loki + Grafana (same UI for both)
- Traces: explicitly out of scope for this series — would require application instrumentation which is beyond the platform layer

**Embedded failure mode:** What debugging an incident looks like when metrics live on five different clusters and you need kubectl access to each one — the context switching, the inability to correlate events across clusters, the "what was happening on the platform cluster when this workload cluster started misbehaving" question that cannot be answered.

---

## Post 9: Crossplane and the Platform API — Infrastructure as a Kubernetes Resource

**Role in series:** Component decision — Crossplane, XRDs, and the platform API pattern.

**Central argument:** Once the management cluster exists, expressing infrastructure as Kubernetes manifests means ArgoCD can manage infrastructure the same way it manages applications. Crossplane XRDs let the platform team define an API that hides cloud-provider specifics from consuming teams.

**Key points:**

*Why Crossplane instead of more Terraform:*
- Terraform requires a separate execution environment (CI pipeline or local workstation) and separate state management
- Crossplane runs in the cluster — infrastructure changes go through the same GitOps workflow as application changes
- A new workload cluster is a Crossplane claim in Git, not a Terraform workspace to manage
- The feedback loop is the same as for any other Kubernetes resource — you see it in ArgoCD, you can watch it reconcile, you can describe it to see status

*Raw Crossplane managed resources vs XRDs:*
- Raw managed resources: Crossplane CRDs that map directly to AWS resources (VPC, Subnet, EKS cluster). Work fine but expose AWS-specific details — ARNs, resource names, provider-specific configuration — to anything that consumes them
- XRDs (Composite Resource Definitions): a platform-defined API. A `PlatformCluster` claim says "give me a cluster with these properties." The Composition underneath it handles all the AWS-specific details. Consuming teams never see provider specifics

*What the platform API pattern gives you:*
- Platform teams own the implementation (Composition). Consuming teams use the claim API. This mirrors how real platform teams work — developers interact with the platform, not with AWS
- The backend can change (different cloud provider, different provisioning approach) without touching any consumer
- The claim API is stable even when the underlying AWS resource structure changes

*XRD design considerations:*
- Too leaky: an XRD that exposes cloud-specific parameters (subnet CIDR notation, AZ names) isn't really an abstraction — it's just a wrapper
- Too opaque: an XRD with no status conditions or observable outputs is impossible to debug when something goes wrong
- Right level: the claim captures what the consumer cares about (cluster size, environment, region), the Composition handles the rest, and status conditions show what's happening

*Why not Crossplane for the management cluster:*
- Covered in Post 4. Crossplane can't provision the cluster it runs on. Something else has to create the management cluster first.

**Embedded failure mode:** What infrastructure drift looks like when you have Terraform managing some things and manual changes managing others and no single source of truth — the "why is this subnet different from what Terraform shows" incident.

---

## Post 10: Putting It Together — What the Architecture Looks Like in Practice

**Role in series:** Synthesis and honest assessment.

**Central argument:** The components in this architecture are not new. Most practitioners have used most of them. The value is in how they connect and why — the part that tutorials never cover.

**Key points:**

*The end-to-end new cluster flow:*
Walk through what happens when a new workload cluster is added — no step-by-step instructions, just the narrative of what each component does:
- A Crossplane claim is committed to Git
- ArgoCD applies it to the management cluster
- Crossplane provisions the EKS cluster, subnets, IRSA roles, and stores the kubeconfig as a secret
- ArgoCD's ApplicationSet detects the new cluster secret and deploys the standard agent stack: ingress-nginx, ExternalDNS, cert-manager, ESO, Alloy
- ExternalDNS creates the subdomain in Route53
- cert-manager issues a wildcard certificate via DNS-01
- Alloy starts shipping metrics and logs to the platform cluster's Prometheus and Loki
- No manual steps were taken after the Git commit

*What this architecture makes easy that would otherwise be hard:*
- Adding a cluster: one claim, one ApplicationSet entry
- Consistent platform services: every cluster gets the same stack, configured the same way, because it comes from the same ArgoCD ApplicationSet
- Secret rotation: update the value in ASM, ESO syncs it automatically to every cluster that has an ExternalSecret referencing it
- Certificate renewal: happens automatically, never requires human intervention

*What this architecture does not solve:*
Honest enumeration of what a true production version of this would still need:
- Tenant isolation: network policies, OPA/Kyverno admission control, namespace-level RBAC
- Cost controls: resource quotas, Karpenter, reserved instances
- Multi-region resilience: this is all in one region
- Disaster recovery: no backup strategy for cluster state or persistent volumes
- Security hardening: CIS benchmarks, node hardening, image scanning, runtime security
- CI pipelines for application code: this covers the platform, not application delivery

*The closing argument:*
The gap between a tutorial cluster and a real platform is not a gap in Kubernetes knowledge — it's a gap in architectural reasoning about how components combine. The decisions documented in this series are made in every real deployment. Most teams make them reactively rather than upfront. Understanding the decisions — and the alternatives — is what makes it possible to make them intentionally.
