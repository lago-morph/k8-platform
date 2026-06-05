# Future enhancements

Deferred ideas that are intentionally out of scope for the current
iterations but worth revisiting. Each entry says what it is, why it was
deferred, and what adopting it would touch.

## cert-manager + Let's Encrypt (ACME DNS-01) as an alternative TLS path

**Status:** deferred (replaced for now by ACM-via-Crossplane —
`docs/decisions/0003`).

The original Iteration 3 design used **cert-manager with a Let's Encrypt
ACME ClusterIssuer** (DNS-01 challenge via Route53) for platform-cluster
TLS. That was replaced by a DNS-validated **ACM certificate provisioned by
the cluster Crossplane Composition**, terminated at the ingress-nginx NLB —
the same mechanism the management cluster already uses, so the platform
runs a single TLS path instead of two.

cert-manager + Let's Encrypt remains a reasonable future option, e.g. if:

- the platform must issue certs for domains not in an ACM-supported
  Route53 zone, or
- a workload needs in-cluster cert material (mTLS between pods, a
  `Certificate` CRD consumed by a sidecar) rather than LB-terminated TLS,
  or
- the demo specifically wants to show the ACME DNS-01 flow.

Adopting it would touch: a cert-manager Helm release on the target
cluster, a `ClusterIssuer` (ACME + Route53 DNS-01 solver), an IRSA role
granting the cert-manager controller Route53 change access scoped to the
cluster's subdomain zone, and per-Ingress `cert-manager.io/cluster-issuer`
annotations. It would coexist with, not replace, the ACM path —
LB-terminated ACM for public ingress, cert-manager for in-cluster cert
material. ACME rate limits and the extra issuance/renewal failure mode are
the reasons it is not the default.
