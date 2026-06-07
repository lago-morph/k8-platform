# 0008 — Sandbox kubectl access via SSM Session Manager port-forward tunnel

- **Status**: Accepted
- **Date**: 2026-06-07

> **Scope — implementation-time only, not a runtime feature.** This ADR governs
> how engineers and agents *build, operate, and debug* the platform from the
> Anthropic sandbox. The SSM kube-tunnel is a development/diagnostic capability
> for people working **on** the platform; it is **not** part of the platform's
> runtime and plays no role in normal operation. No workload's data path, no
> cluster service, and nothing the platform delivers to its users depends on it —
> removing it would not affect any running cluster or application. It exists only
> to give a sandbox session a tighter inner loop than the `kube-diagnose`
> workflow + ArgoCD REST API. It is read-only, gated by IAM + a read-only access
> entry, and never sits on a production data path.

## Context

The Anthropic sandbox egress is a strict-verifying MITM gateway (AGENTS §6.27)
that validates the *upstream* TLS certificate against public trust roots. The
EKS API server presents a certificate signed by the cluster's **private CA**,
which is not in any public root store. Sending `kubectl` traffic directly from
the sandbox therefore causes the gateway to reject the connection with an HTTP
503 — it cannot verify the upstream cert, so it drops the request before
kubectl even sees a response.

EKS is a managed service: AWS owns the API-server certificate and the cluster's
CA. There is no mechanism to attach an ACM or Let's Encrypt certificate to the
EKS API endpoint, and the endpoint's DNS name cannot be pointed at a
custom-origin with a public cert. **The upstream certificate will always be
cluster-CA-signed.** The only viable approach is therefore to interpose
something whose *outbound* TLS — the leg the gateway inspects — carries a
publicly trusted certificate.

Two candidate topologies were evaluated:

- **Approach A — SSM Session Manager port-forward**: the sandbox opens an
  `aws ssm start-session` tunnel (`AWS-StartPortForwardingSessionToRemoteHost`)
  to a relay EC2 instance. The SSM data channel is a persistent WebSocket to
  `ssmmessages.<region>.amazonaws.com`, which presents a **public AWS
  certificate**. The gateway accepts it. The relay opens a raw TCP connection to
  the EKS *private* endpoint; kubectl sends TLS directly through that TCP pipe
  and verifies the **real cluster CA** end-to-end. No certificate is substituted
  or terminated anywhere in the path.

- **Approach B — NLB with ACM certificate**: expose the EKS API via a Network
  Load Balancer TLS listener backed by a public ACM certificate. The gateway
  would accept the public cert. However, the NLB **terminates TLS**, so kubectl
  can no longer verify the real cluster CA without either skip-verifying or
  trusting the Amazon root — neither is acceptable. Additionally, this approach
  adds an internet-facing kube-API listener that requires a CIDR allowlist and
  fragile maintenance of the AWS-managed endpoint IPs. Rejected on both security
  and fidelity grounds.

**Spike (2026-06-07)**: A throwaway SSM relay instance was stood up and
`AWS-StartPortForwardingSessionToRemoteHost` was opened through it. An HTTPS
request was sent through the tunnel (ssl_verify=0 at the relay side; TLS
terminated at the real destination). Result: HTTP 200 with the genuine
response body, confirming:

1. The sandbox gateway permits the long-lived `ssmmessages` WebSocket.
2. End-to-end TLS with real certificate verification works across the tunnel.

This was the single load-bearing unknown — SSM vs. NLB hinged on whether the
gateway would sustain the WebSocket session. It does.

**Instance-cap constraint**: the AWS account is hard-capped at 9 EC2 instances
(a 10th closes the account). There is therefore exactly **one** shared relay
(a `t3.nano`) for the entire account, living in the single shared base VPC.
Every cluster (the management hub and all platform clusters) admits that relay
to its *private* API endpoint by adding a security-group ingress rule on port
443. Per-cluster relays were considered and rejected (too many instances).
Reusing an EKS node as a relay was also rejected: an SSM shell on a node is
equivalent to root on a Kubernetes node, which would bypass the read-only
access-entry ceiling enforced for the sandbox identity.

## Decision

Use **AWS SSM Session Manager port-forward** (`AWS-StartPortForwardingSessionToRemoteHost`)
through a single shared relay instance to give the sandbox `kubectl` access
to every cluster.

Key properties of the chosen design:

- The relay has **no inbound security-group rule**; all connectivity is
  initiated outbound from the relay (SSM agent → `ssmmessages` endpoint).
- kubectl connects to `localhost:<port>` on the sandbox side and sends genuine
  TLS; the relay transparently forwards TCP to the EKS private endpoint; kubectl
  verifies the real cluster CA. No certificate substitution occurs.
- Authentication is two-layered: **IAM** (`ssm:StartSession` on the relay
  resource) to open the tunnel, and **Kubernetes RBAC** (read-only EKS access
  entry) to authorise API calls. Token issuance is via `aws eks get-token`; no
  static kubeconfig secrets are committed to the repository.
- The sandbox IAM identity (`user/cloud_user`) is mapped to
  `AmazonEKSAdminViewPolicy` in an EKS access entry on each cluster — read-only
  across all resources including CRDs (Crossplane XRs, ArgoCD Applications).
- Every platform cluster receives this automatically through the
  `XPlatformCluster` Composition (`crossplane/compositions/platform-cluster.yaml`),
  which renders two resources per cluster: `kube-relay-ingress` (security-group
  rule admitting the relay SG) and `sandbox-access-entry` / `sandbox-access-policy`
  (the read-only EKS access entry). The relay SG id is published from
  `terraform/management/kube-access.tf` into the `cluster-network`
  EnvironmentConfig (`relaySecurityGroupId`) and consumed by the Composition.
- The management hub cluster is wired separately in
  `terraform/management/kube-access.tf` (relay instance, relay SG, mgmt-cluster
  ingress rule, access entry).
- The helper script `scripts/sandbox-kubeconfig.sh` encapsulates the tunnel
  lifecycle and kubeconfig wiring.

## Alternatives considered

- **Approach B — NLB with ACM TLS termination** — rejected: terminates TLS so
  kubectl cannot verify the real cluster CA; adds an internet-facing kube-API
  listener requiring a CIDR allowlist and fragile IP-refresh of AWS-managed
  endpoint IPs. Strictly worse than SSM on both security and fidelity.

- **Lambda function URL as a kubectl proxy** — rejected: Lambda's HTTP model
  breaks `kubectl exec` and `kubectl port-forward` (no raw streaming). Suitable
  only for CRUD-style API calls, not a general-purpose kubectl path.

- **Per-cluster relay instances** — rejected: would consume one EC2 instance
  per cluster, hitting the 9-instance account cap immediately for any non-trivial
  cluster count.

- **Reuse an EKS node as the relay** — rejected: an SSM shell on a Kubernetes
  node is equivalent to root on that node, which would bypass the read-only
  access-entry ceiling and violate the principle of least privilege for sandbox
  sessions.

## Consequences

- **Implementation-time tool, not a runtime dependency** — this path is used only
  by sandbox sessions building/operating the platform. Normal platform operation
  (workloads, ingress, GitOps reconciliation) neither uses nor requires it; it can
  be removed or left unprovisioned without affecting any running cluster.
- **One standing `t3.nano` relay** (~$4/mo) counts against the 9-instance
  account cap. Budget for it; treat the cap as a hard constraint when planning
  any future EC2 resources.
- **kubectl is read-only by design** — the sandbox identity maps to
  `AmazonEKSAdminViewPolicy`. Mutations continue to flow through ArgoCD / CI
  (GitOps) and are not possible from a sandbox kubectl session.
- **No public listener added** — the EKS API endpoints remain private; the
  relay itself has no inbound SG rule. An SSM shell on the relay yields nothing
  useful (it runs no workloads, holds no kubeconfig or credentials).
- **Future clusters get this automatically** — the `XPlatformCluster`
  Composition renders the relay-ingress rule and access entry for every cluster
  it provisions, with no per-cluster manual steps.
- **Dependency on the management Terraform apply** — the relay instance and its
  SG id in `cluster-network` EnvironmentConfig must exist before platform
  clusters are provisioned. This is an ordering constraint, not a runtime
  dependency.

## References

- `terraform/management/kube-access.tf` — relay instance, relay SG, mgmt-cluster
  ingress rule, mgmt-cluster access entry.
- `crossplane/compositions/platform-cluster.yaml` — `kube-relay-ingress`,
  `sandbox-access-entry`, `sandbox-access-policy` resources.
- `crossplane/compositions/platform-cluster.yaml` — `cluster-network`
  EnvironmentConfig consumption (`relaySecurityGroupId`).
- `scripts/sandbox-kubeconfig.sh` — tunnel lifecycle helper.
- AGENTS.md §6.27 — sandbox egress gateway TLS verification policy.
