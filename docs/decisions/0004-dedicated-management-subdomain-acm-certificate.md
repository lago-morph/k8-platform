# 4. Dedicated `*.management.<domain>` ACM certificate for management-cluster services

- **Status**: Accepted
- **Date**: 2026-06-06
- **ID**: ADR-c05151e6d6
- **Related**: ADR 0003 (per-cluster ACM cert for *platform/spoke* clusters via
  Crossplane) — this decision applies the same "base wildcard can't cover
  two-label hosts" principle to the *management* cluster's own services, where
  the cert is provisioned by Terraform rather than the cluster Composition.

## Context

Management-cluster services are exposed at two-label hosts under the per-account
zone — e.g. `argocd.management.<account-id>.realhandsonlabs.net`. The
ingress-nginx NLB originally terminated TLS with the **base** ACM wildcard
`*.<account-id>.realhandsonlabs.net` (from `terraform/base`). A DNS wildcard with
a single `*` matches exactly **one** label, so that certificate does **not**
cover `argocd.management.<…>` (two labels: `argocd` + `management`). Lenient TLS
clients ignore the SAN mismatch, so this stayed invisible — until the sandbox's
egress gateway, which performs **strict upstream SAN verification** (AGENTS
§6.27), refused to proxy and returned `503 … verify SAN list`.

The consequence was severe: the agent could not reach ArgoCD from the sandbox at
all, which blocks the entire phase-3 provisioning flow — that flow is driven by
`argocd login` + `argocd app sync` *from the sandbox* (AGENTS §10.1). The handoff
had even asserted ArgoCD was "directly reachable," a claim that was false
precisely because of this SAN gap. Surfaced 2026-06-06 (PR #149).

## Decision

Serve management-cluster service hostnames such as `argocd.management.<domain>`
from a **dedicated `*.management.<domain>` ACM certificate** on the ingress NLB,
provisioned in `terraform/management` (`acm-management.tf`, DNS-validated via the
account's Route53 zone), and point the ingress-nginx
`service.beta.kubernetes.io/aws-load-balancer-ssl-cert` annotation at it — not at
the base `*.<domain>` wildcard.

## Alternatives considered

- **Keep the base `*.<domain>` wildcard.** Rejected: it structurally cannot cover
  two-label hosts, and any strict-SAN client (the egress gateway, and
  security-conscious consumers) rejects it. The bug recurs for every
  `*.management.<domain>` service.
- **A multi-SAN cert listing each service host explicitly.** Rejected: requires
  editing the certificate every time a management service is added; a
  `*.management` wildcard covers them all with no churn.
- **Terminate TLS at nginx with cert-manager instead of NLB + ACM.** Rejected:
  the project's TLS strategy terminates at the NLB with ACM (no ACME on-cluster);
  changing it is a larger shift than the problem warrants and contradicts ADR
  0003.
- **Flatten the hostnames to one label (`argocd.<domain>`).** Rejected: the
  `management` / `platform` subdomain segmentation is intentional (it scopes hub
  vs spoke service DNS) and used elsewhere.

## Consequences

- Every current and future `*.management.<domain>` service gets a SAN-correct,
  publicly-trusted certificate with no per-service cert edits; the sandbox can
  reach them through the strict-verifying egress gateway.
- One additional ACM certificate + DNS-validation record per cluster to
  provision and wait on (adds a dependency to the management apply). Accepted —
  a one-time per-cluster cost, fully automated.
- Symmetry with ADR 0003: management services use this Terraform-provisioned
  `*.management` cert; platform/spoke clusters get their `*.platform` cert from
  the cluster Composition. Both follow the same "wildcards cover one label" rule.
- Reinforces AGENTS §6.27: any sandbox-reachable service must present a
  publicly-trusted cert whose SAN matches the host.

## References

- `terraform/management/acm-management.tf` — the `*.management.<domain>` cert +
  validation (PR #149).
- `terraform/management/helm.tf` — the ingress-nginx `aws-load-balancer-ssl-cert`
  annotation that binds it.
- `docs/decisions/0003-acm-via-crossplane-for-cluster-tls.md` — the platform
  cluster analog.
- `retrospective/2026-06-06-151.md` and
  `retrospective/2026-06-06-151/ADR-c05151e6d6-issue-a-dedicated-per-subdomain-acm-certificate-for-management-cluster-services.md`
  — the source retrospective + draft.
- AGENTS §6.27 (sandbox egress is a strict-verifying MITM gateway) — the behavior
  that surfaced the SAN gap.
