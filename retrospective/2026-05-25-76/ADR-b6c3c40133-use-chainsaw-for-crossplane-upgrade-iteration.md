# ADR: Use kind+chainsaw as the primary iteration loop for Crossplane version upgrades

- **ID**: ADR-b6c3c40133
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-05-25
- **Source retrospective**: ../2026-05-25-76.md
- **PRs covered**: #74

## Context

Crossplane version upgrades produce regression classes (beta features, SSA schema rejections,
RBAC gaps, provider incompatibilities) that can only be confirmed by actually running the
Composition pipeline end-to-end. The alternative iteration loops available are:

1. **Live EKS cluster (`management apply-and-verify` + integration test 11)**: ~15–20 minutes
   per iteration (Terraform apply + ArgoCD sync + probe claim), requires a running cluster with
   real IRSA, and produces noisy CI history.
2. **kind+chainsaw (`chainsaw.yml` dispatch)**: ~10 minutes per iteration, uses real AWS
   credentials for the provider calls, and runs against a clean cluster each time.

During the 2.0.1 → 2.3.0 upgrade, chainsaw was used as the primary loop. It successfully
caught all three regression classes (SSA schema, RBAC, flag name) before the live cluster
was touched. The `test_chainsaw_crossplane_matches_management.sh` unit test enforces that
kind and EKS run identical versions, so a green chainsaw run is a valid proxy for production.

## Decision

Validate Crossplane version compatibility in the kind+chainsaw harness before applying any
upgrade to the live EKS management cluster. The live cluster is only updated (via
`management apply-and-verify`) after all three PlatformSecret chainsaw scenarios are green.

## Alternatives considered

- **Iterate directly on the live cluster.** Rejected: 15–20 minutes per iteration vs ~10
  minutes for chainsaw. More importantly, failed iterations leave the live cluster in an
  intermediate state (partially upgraded providers, rolled-back helm release) that requires
  manual cleanup. Kind clusters are disposable; the EKS cluster is not.

- **Use a staging kind cluster without real AWS credentials.** Rejected: PlatformSecret
  scenarios require real AWS Secrets Manager calls. A mock would not catch provider
  incompatibilities (e.g. Bug 3 — provider v1.12.0 delayed CreateSecret under 2.3.0 core).

## Consequences

**Easier:**
- Each chainsaw iteration is isolated (fresh kind cluster); no cleanup needed on failure.
- Regression classes are caught before they affect the live cluster or its state files.
- The 10-minute iteration loop allows multiple fix attempts within a reasonable session.

**Harder:**
- Chainsaw requires real AWS credentials and a working provider-family-aws install. If the
  provider itself is broken (e.g. incompatible version), chainsaw can't validate the scenario
  either.
- Provider incompatibilities that only manifest under EKS IRSA (vs kind static-cred
  ProviderConfig) won't be caught by chainsaw. A live cluster smoke test is still required
  after chainsaw green.

**Trade-off accepted:**
- We accept the additional ~10-minute chainsaw step before live cluster apply in exchange for
  isolating regressions and preserving live cluster state.

## References

- [`../2026-05-25-76.md`](../2026-05-25-76.md) — source retrospective.
- [`./SKILL-SPEC-befefff7cb-crossplane-v2-upgrade-triage.md`](./SKILL-SPEC-befefff7cb-crossplane-v2-upgrade-triage.md) — upgrade triage skill (step 8: "only after all scenarios pass").
- PRs: #74 (upgrade; chainsaw used as primary iteration loop).

<!--
PROMOTION NOTE:
When this draft is adopted into docs/adr/ via the `adr` skill, preserve
the `**ID**: ADR-b6c3c40133` line verbatim.
-->
