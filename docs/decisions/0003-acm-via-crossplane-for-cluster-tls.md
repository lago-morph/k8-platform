# 3. Per-cluster TLS via a Crossplane-provisioned ACM certificate (no cert-manager / Let's Encrypt)

- **Status**: Accepted
- **Date**: 2026-06-05
- **Supersedes**: the cert-manager + Let's Encrypt (ACME DNS-01) choice in
  `ai/DESIGN.md` §"cert-manager + Let's Encrypt" and REQ-PLAT-05.
- **Related**: ADR-e557a40123 (subnet/zone/domain injection from base
  Terraform output — drafted in `retrospective/2026-06-05-01/`), adopted
  in §Decision below.

## Context

REQ-PLAT-05 originally specified cert-manager with a Let's Encrypt ACME
ClusterIssuer (DNS-01 via Route53) for platform-cluster TLS. The
management cluster, however, already terminates TLS at its ingress-nginx
NLB using an AWS-managed **ACM** certificate provisioned in
`terraform/base` (no cert-manager, no ACME) — see `terraform/base/acm.tf`
and `terraform/management/helm.tf`. Running two different TLS mechanisms
(ACM for management, ACME for platform) adds a second issuance path,
a second renewal failure mode, and a cert-manager + ClusterIssuer +
Route53-IRSA surface that the ACM path does not need.

The base `*.<domain>` certificate is a single-label wildcard and does not
cover the two-label platform hostnames (`<svc>.platform.<domain>`), so the
platform cluster genuinely needs its own `*.platform.<domain>` cert.

Cluster provisioning is owned by the `XPlatformCluster` Composition
(`crossplane/compositions/platform-cluster.yaml`), which already renders
the EKS cluster, node group, and IAM roles. Certificate issuance should be
an intrinsic part of provisioning *any* cluster (platform or future
tenant), not a one-off bolted onto the platform cluster.

## Decision

1. **TLS for every cluster comes from a DNS-validated ACM certificate
   provisioned by the cluster Composition**, not cert-manager / Let's
   Encrypt. The Composition renders, alongside the EKS resources, three
   managed resources from `provider-upjet-aws` v2.5.0:
   - `acm.aws.m.upbound.io/v1beta1` **Certificate** — `*.<subdomain>.<domain>`,
     `validationMethod: DNS`.
   - `route53.aws.m.upbound.io/v1beta1` **Record** — the DNS validation
     CNAME the certificate emits.
   - `acm.aws.m.upbound.io/v1beta1` **CertificateValidation** — gates on
     the certificate reaching ISSUED ("go through the process of confirming
     it"), so the XR only becomes Ready once TLS is confirmed.

   The issued ARN is published on `status.certificateArn` and bound to the
   cluster's ingress-nginx NLB via the `aws-load-balancer-ssl-cert`
   annotation. cert-manager, ACME, and ClusterIssuers are removed from the
   platform stack.

2. **Account-ephemeral inputs are injected from the base Terraform output**
   (adopting ADR-e557a40123). The private subnet IDs, Route53 zone id, and
   root domain are account-ephemeral (AGENTS §8.1) and must not be
   committed to git. `terraform/management` materializes a Crossplane
   `EnvironmentConfig` named `cluster-network` from
   `data.terraform_remote_state.base.outputs` (`private_subnet_ids`,
   `route53_zone_id`, `domain`). The Composition reads it via a
   `function-environment-configs` pipeline step; the XR carries only stable
   values (`spec.name`, `spec.dns.subdomain`, sizing). The wildcard cert
   domain `*.<subdomain>.<domain>` is built in the Composition with a
   top-level `environment` patch (copies `spec.dns.subdomain` into the
   pipeline environment) followed by a `CombineFromEnvironment`
   `[subdomain, domain]` patch on the Certificate resource.

## Alternatives considered

- **Keep cert-manager + Let's Encrypt (original REQ-PLAT-05)** — rejected:
  a second issuance/renewal mechanism alongside the management cluster's
  ACM path, more moving parts (cert-manager, ClusterIssuer, Route53 IRSA
  for ACME solvers), and ACME rate limits. Retained as a possible future
  enhancement — see `docs/future-enhancements.md`.
- **Extend the base `*.<domain>` ACM cert with a `*.platform.<domain>`
  SAN** — rejected by the user in favour of a per-cluster Crossplane XRD:
  a Terraform-managed central cert does not generalize to self-service
  tenant clusters and is not part of the cluster-provisioning Composition.
- **Standalone per-platform cert XRD** — rejected: would not give tenant
  clusters their certs. Folding issuance into the shared cluster
  Composition makes it intrinsic to provisioning any cluster.
- **Per-resource `ToEnvironmentFieldPath` to stage the subdomain** —
  rejected: a per-resource environment write is not visible to a
  `CombineFromEnvironment` in the same render/reconcile pass; the top-level
  `environment.patches` (which run first) are.

## Consequences

- One TLS mechanism (ACM + NLB termination) across all clusters; no ACME,
  no cert-manager, no ClusterIssuer.
- The Crossplane AWS provider needs ACM and Route53 permissions and the
  `provider-aws-acm` / `provider-aws-route53` packages installed on the
  management cluster (added in `terraform/management`).
- The cluster's networking/DNS facts live in the `cluster-network`
  EnvironmentConfig (one source of truth from base state); the cluster XR
  is account-portable and commits with no placeholders.
- Soft coupling: the platform cluster's subnets/cert are correct only after
  a `terraform/management` apply has published the current account's values
  into the EnvironmentConfig.

## References

- `crossplane/compositions/platform-cluster.yaml`, `crossplane/xrds/platform-cluster.yaml`
- `terraform/base/acm.tf` — the management cluster's ACM pattern this mirrors.
- `retrospective/2026-06-05-01/ADR-e557a40123-subnet-ids-from-base-terraform-output.md`
- `docs/future-enhancements.md` — cert-manager / Let's Encrypt as a future option.
