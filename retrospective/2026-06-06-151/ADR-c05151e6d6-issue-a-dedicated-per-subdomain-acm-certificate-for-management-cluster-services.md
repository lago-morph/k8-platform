# ADR: Issue a dedicated per-subdomain ACM certificate for management-cluster services

- **ID**: ADR-c05151e6d6
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-06-06
- **Source retrospective**: ../2026-06-06-151.md
- **PRs covered**: #149

## Context

Management-cluster services are exposed at two-label hosts under a per-account
zone — e.g. `argocd.management.<account-id>.realhandsonlabs.net`. The ingress
NLB originally terminated TLS with the **base** ACM wildcard
`*.<account-id>.realhandsonlabs.net` (from `terraform/base`). A DNS wildcard with
a single `*` matches exactly **one** label, so that cert does **not** cover
`argocd.management.<…>` (two labels: `argocd` + `management`). Lenient clients
ignore the SAN mismatch, so this stayed invisible — until the sandbox's egress
gateway, which does **strict upstream SAN verification**, refused to proxy and
returned `503 … verify SAN list`. The result: the agent could not reach ArgoCD
from the sandbox at all, blocking the entire phase-3 provisioning flow (which is
driven by `argocd login` + `argocd app sync` from the sandbox). The handoff had
even asserted ArgoCD was "directly reachable" — a claim that was false precisely
because of this SAN gap.

## Decision

Serve management-cluster service hostnames such as `argocd.management.<domain>`
from a **dedicated `*.management.<domain>` ACM certificate** on the ingress NLB,
provisioned in `terraform/management` (`acm-management.tf`), rather than the base
`*.<domain>` wildcard — and point the ingress-nginx `aws-load-balancer-ssl-cert`
annotation at it.

## Alternatives considered

- **Keep the base `*.<domain>` wildcard.** Rejected: it structurally cannot cover
  two-label hosts, and strict-SAN clients (the egress gateway, and any
  security-conscious consumer) reject it. The bug recurs for every
  `*.management.<domain>` service.
- **A multi-SAN cert listing each service host explicitly** (`argocd.management…`,
  etc.). Rejected: requires editing the cert every time a management service is
  added; a `*.management` wildcard covers them all with no churn.
- **Terminate TLS at nginx with cert-manager instead of the NLB+ACM.** Rejected:
  the project's established TLS strategy terminates at the NLB with ACM (no ACME
  on the management cluster); changing that is a larger architectural shift than
  the problem warrants.
- **Flatten the hostnames to one label (`argocd.<domain>`).** Rejected: the
  `management` / `platform` subdomain segmentation is intentional (it scopes
  hub vs spoke service DNS) and used elsewhere.

## Consequences

- **Easier:** every current and future `*.management.<domain>` service gets a
  SAN-correct, publicly-trusted cert with no per-service cert edits; the sandbox
  can reach them through the strict-verifying gateway. Establishes the pattern
  for spoke clusters too (`*.platform.<domain>` already follows it via the
  XPlatformCluster composition).
- **Harder / trade-off:** one more ACM cert + DNS-validation record per cluster
  to provision and wait on (adds a dependency to the management apply). Accepted —
  it is a one-time per-cluster cost and the validation is automated.
- **Reinforces** the egress-gateway rule: any sandbox-reachable service must
  present a publicly-trusted cert whose SAN matches the host.

## References

- [`../2026-06-06-151.md`](../2026-06-06-151.md) — the source retrospective.
- [`./AGENTS-MD-ef58eb520b-sandbox-egress-is-a-strict-verifying-mitm-gateway.md`](./AGENTS-MD-ef58eb520b-sandbox-egress-is-a-strict-verifying-mitm-gateway.md) — the gateway behavior that surfaced the SAN gap.
- `terraform/management/acm-management.tf`, `terraform/management/helm.tf` (ingress ssl-cert annotation) — PR #149.
- PRs the decision was made in: #149.
