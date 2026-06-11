# 0011 — Composite-routed cross-resource references over provider reference selectors

- **ID**: ADR-0e5ccd45c3
- **Status**: Accepted (owner-ratified 2026-06-11)
- **Date**: 2026-06-11
- **Source retrospective**: [`../../retrospective/2026-06-11-224.md`](../../retrospective/2026-06-11-224.md)
- **PRs covered**: #223 (the fix), #220 (the pattern's other user)
- **Mechanical enforcement**: pending — the retrospective's R1 lint proposal
  (flag reference-selectors whose target MR lacks an explicit external-name
  patch); until it lands, this ADR is prose-only guidance

## Context

During the first from-scratch clean build (2026-06-10), the platform cluster
XR stalled at `Ready=False` on `cluster-cert-validation` for 50+ minutes
while the real ACM certificate sat ISSUED. The CertificateValidation MR used
`certificateArnSelector` (matchControllerRef + label) to reference the
Certificate MR. Upjet reference selectors resolve through the referenced
MR's `crossplane.io/external-name` annotation — and the v2.5.0 ACM provider
leaves that annotation **empty** on Certificate (an identity-from-provider
resource), even when the MR is Ready with `status.atProvider.arn` populated.
This is the same provider-resource-identity bug class already documented for
`SecurityGroupIngressRule` (hashicorp/terraform-provider-aws#45303,
docs/decisions/0008). Every static layer (render golden, kubeconform,
chainsaw admission) was green; only the build-coupled behavioral loop
exposed it (OI-2026-06-10-1).

The same session's ADR-0010 PR-2 producer (PR #220) had already established
the alternative idiom: facts cross resource boundaries via the composite
(`ToCompositeFieldPath` → XR status → `FromCompositeFieldPath`), with
`policy.fromFieldPath: Required` giving complete-or-absent creation
semantics (verified against function-patch-and-transform v0.10.6 source: an
unresolvable Required patch skips creating that one composed resource and
leaves siblings untouched).

## Decision

When a Composition needs one composed resource to reference another and the
referenced field is provider-written identity (external-name/ARN), route the
value through the XR status with ToCompositeFieldPath/FromCompositeFieldPath
Required patches instead of using the provider reference-selector mechanism.

Selectors remain acceptable where the same Composition explicitly patches
the referenced MR's `crossplane.io/external-name` (deterministic identity) —
e.g. the IAM Role / EKS Cluster selectors in `platform-cluster.yaml`, which
worked throughout because their external-names are patched from `spec.name`.

## Alternatives considered

- **Keep selectors and hand-write the missing external-name on the live
  MR.** Rejected: banned live mutation (AGENTS done-contract) — it validates
  nothing and recurs every rebuild.
- **Keep selectors and wait for the upstream provider fix.** Rejected: the
  pin is v2.5.0 today; the platform must build from nothing today. Upstream
  tracking stays open under OI-2026-06-10-1.
- **Patch external-name onto identity-from-provider MRs ourselves.**
  Rejected: for ACM the external-name IS the ARN, which is unknowable before
  create — exactly why the provider must write it back; we cannot.

## Consequences

- Cross-resource data flow is uniform and observable (every fact visible on
  the XR status), and Required-policy gating means dependent MRs are created
  complete-or-absent rather than created-broken.
- One extra reconcile pass of latency per hop (composite-routed values land
  on the next pass) — already the accepted behavior of the validation
  Record and the ADR-0010 producer.
- XRD status schemas grow a field per routed fact (declared, documented).
- The remaining selector uses are load-bearing exceptions; the Part 3 R1
  lint proposal (flag selectors whose target lacks an explicit
  external-name patch) is the mechanical enforcement of this decision.

## References

- [`../../retrospective/2026-06-11-224.md`](../../retrospective/2026-06-11-224.md) — the source retrospective (Phase 4).
- `docs/open-issues.md` OI-2026-06-10-1 — the live evidence + undiagnosed upstream half.
- `crossplane/compositions/platform-cluster.yaml` (cluster-cert-validation, PR #223) and `crossplane/compositions/xspokeaccess.yaml` (spoke-cluster-secret, PR #220) — the two in-tree users of the idiom.
- docs/decisions/0008 — the prior v2.5.0 identity-bug observation this generalizes.
