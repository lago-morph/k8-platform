# k8-platform

A real-world, production-like Kubernetes platform on AWS — built as a learning reference and blog post series.

This fills the gap between "deploy an app to a cluster" tutorials and what actually has to exist before an application can run in an enterprise context: automatic TLS, SSO, secrets that don't live in Git, cross-cluster observability, and a management plane that survives a bad rollout.

## Architecture

Three-tier cluster topology:

```
Management Cluster (EKS, Terraform)
  └── ArgoCD hub + Crossplane + ESO
      ├── Platform Services Cluster (EKS, Crossplane)
      │     └── ingress-nginx, ExternalDNS, cert-manager,
      │         Keycloak, Prometheus, Grafana, Loki
      └── Workload Clusters (EKS, Crossplane)
            └── ingress-nginx, ExternalDNS, cert-manager,
                ESO, Prometheus/Loki agent
```

See [`ai/DESIGN.md`](ai/DESIGN.md) for full architecture rationale and ADRs.

## Prerequisites

- AWS account with sufficient IAM permissions (EKS, VPC, Route53, Secrets Manager, IAM, Cognito)
- A registered domain with Route53 as the DNS provider (or delegated to Route53)
- Terraform >= 1.6
- `kubectl`, `helm`, `aws` CLI installed locally
- AWS credentials available in environment (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`) or via a named profile (`AWS_PROFILE`)

## Repository Structure

```
terraform/base/          # Iteration 0: VPC, Route53, Cognito
terraform/management/    # Iteration 1: Management EKS cluster
argocd/                  # ArgoCD Application and Project manifests
crossplane/              # XRDs, Compositions, example Claims
clusters/                # Per-cluster resource overlays
platform-services/       # Helm values for platform components
docs/                    # ADRs, iteration notes, diagrams
ai/                      # Design docs and requirements
```

## Build Order (Iterations)

| # | Deliverable | End State |
|---|-------------|-----------|
| 0 | Base environment | Route53 zone exists; Cognito user pool with test user |
| 1 | Management cluster | ArgoCD UI at `argocd.management.<domain>` with valid TLS |
| 2 | Crossplane foundations | `PlatformSecret` claim creates ASM secret + K8s Secret |
| 3 | Platform services cluster | Test app at `hello.platform.<domain>` with auto TLS/DNS |
| 4 | Observability | Grafana at `grafana.platform.<domain>` with cross-cluster metrics |
| 5 | Authentication | ArgoCD + Grafana SSO via Keycloak → Cognito |
| 6 | First workload cluster | New cluster from one Crossplane claim + one Git commit |

## Getting Started

### Iteration 0 — Base Environment

```bash
cd terraform/base
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set domain, aws_region, etc.
terraform init
terraform plan
terraform apply
```

### Iteration 1 — Management Cluster

```bash
cd terraform/management
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set domain, cluster_name, etc.
terraform init
terraform plan
terraform apply
```

After `apply`, ArgoCD takes over. All subsequent changes are GitOps — commit to this repo and ArgoCD reconciles.

## Key Design Decisions

- **Terraform only for management cluster** — provides break-glass recovery; Crossplane manages everything else
- **Crossplane XRDs** (`PlatformCluster`, `PlatformSecret`) — platform abstractions hide AWS specifics from consumers
- **IRSA everywhere** — no static AWS credentials in any manifest or secret
- **AWS Secrets Manager + ESO** — no secrets in Git, ever
- **Real domain + Let's Encrypt** — no self-signed certificates; DNS-01 challenge for private clusters

Full rationale in [`ai/DESIGN.md`](ai/DESIGN.md). Requirements in [`ai/REQUIREMENTS.md`](ai/REQUIREMENTS.md).
