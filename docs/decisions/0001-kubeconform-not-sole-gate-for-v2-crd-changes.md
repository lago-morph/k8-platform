# 0001 — Kubeconform is not a sufficient gate for v2 CRD changes

- **ID**: ADR-c7f74e2fb6
- **Status**: Accepted
- **Date**: 2026-05-26
- **Source retrospective**: [`../../retrospective/2026-05-26-106.md`](../../retrospective/2026-05-26-106.md)
- **PRs covered**: #103 (SEG-4 PR-T1), #104 (Wave 2), #105 (Wave 2 hotfix)

## Context

The repo's `tests/unit/test_kubeconform_manifests.sh` (SPEC-S6) runs on every push and validates every YAML under `crossplane/`, `argocd/`, `clusters/`, `policies/` against a committed JSON-schema store under `kubeconform-schemas/`. The store is regenerated from upstream CRD YAMLs by `scripts/fetch-crds-for-kubeconform.sh`. The contract is: kubeconform green → manifests are admission-valid.

During the 2026-05-26 v1→v2 migration, this contract broke at a v2-specific failure mode:

- The v2 `provider-family-aws` v2.5.0 release publishes both v1 (`*.aws.upbound.io_*.yaml`) and v2 (`*.aws.m.upbound.io_*.yaml`) CRDs in the same package, plus updated `apiextensions.crossplane.io_compositeresourcedefinitions.yaml`.
- The `compositeresourcedefinition_v2.json` schema (generated from the v2 CRD) accepts `connectionSecretKeys` on a `apiextensions.crossplane.io/v2` XRD. The field exists in the CRD's `openAPIV3Schema`.
- The v2 admission webhook has additional handler logic that REJECTS the field at apply time: `XR connection secrets aren't supported in apiextensions.crossplane.io/v2`.

The schema and the webhook disagree. SPEC-S6's "kubeconform is the first line of schema defense" promise is broken for v2 admission-handler logic. The same migration cost a hotfix PR (#105) plus two extra chainsaw iterations because the SEG-1 subagent trusted kubeconform alone.

## Decision

For PRs that modify Crossplane manifests across a major API-version boundary (v1 → v2 group rename, XRD `apiextensions/v1` → `/v2`, Composition rewrites with new `providerConfigRef` shapes), **kubeconform schema-pass is NECESSARY but NOT SUFFICIENT**. A live `chainsaw.yml` dispatch against the branch SHA — including at minimum the `xrd-establishes` scenario — is REQUIRED before merge. The chainsaw run surfaces admission-webhook rejections that the static schema cannot express.

This does NOT replace kubeconform; kubeconform still catches the field-structure mismatches (the 2026-05-26 migration caught `vpcConfig[0]` → `vpcConfig` and `scalingConfig[0]` → `scalingConfig` via kubeconform locally — they're CRD-shape changes the schema correctly reflects). It supplements kubeconform with a live-admission gate for the specific class of failures the schema can't express.

The operational contract is codified in `AGENTS.md` §6.8.

## Alternatives considered

- **Trust kubeconform alone, fix admission failures as hotfixes post-merge.** This is what happened in the 2026-05-26 run — cost one hotfix PR (#105) + 3 chainsaw iterations + ~30 min wall clock. Rejected for future v2-shape work: the hotfix cost is real and the rule is cheap (~5 min per dispatch).
- **Generate kubeconform schemas from the live API discovery instead of upstream CRDs.** The v2 admission webhook's handler-based rejections aren't exposed in the API discovery either; this wouldn't help. Rejected.
- **Maintain a hand-written denylist of "fields kubeconform accepts but admission rejects".** Fragile; would drift behind upstream Crossplane releases. Rejected.
- **Run chainsaw on every push instead of `workflow_dispatch`-only.** Per AGENTS.md §6.7 this is the explicit anti-pattern the verifier was built to prevent (heavy CI burns runner minutes during iteration). Rejected.

## Consequences

- **Easier**: explicit checkpoint before merging v2-shape PRs surfaces admission failures pre-merge instead of post-merge.
- **Harder**: lead-agent and operators must remember to dispatch chainsaw before opening v2-shape PRs. Mitigated by `AGENTS.md` §6.8 (the new rule) and the `kubeconform-vs-admission-check` skill spec (`retrospective/2026-05-26-106/SKILL-SPEC-ac65496714-kubeconform-vs-admission-check.md`).
- **Trade-off accepted**: ~5 minutes of chainsaw wall clock per v2-shape PR, in exchange for catching admission failures in the iteration loop rather than as post-merge hotfixes. The trade was already paid (involuntarily) in the 2026-05-26 run.

## References

- [`../../retrospective/2026-05-26-106.md`](../../retrospective/2026-05-26-106.md) — the source retrospective.
- [`../../retrospective/2026-05-26-106/SKILL-SPEC-ac65496714-kubeconform-vs-admission-check.md`](../../retrospective/2026-05-26-106/SKILL-SPEC-ac65496714-kubeconform-vs-admission-check.md) — the skill that implements this decision.
- [`../../retrospective/2026-05-26-106/ADR-80191c7707-xr-conn-secrets-removed.md`](../../retrospective/2026-05-26-106/ADR-80191c7707-xr-conn-secrets-removed.md) — the specific v2 admission-handler rejection that motivated this ADR.
- `AGENTS.md` §6.7 — manual-verify-then-PR contract for heavy CI workflows (the broader pattern this ADR specializes).
- `AGENTS.md` §6.8 — the agents-file rule that codifies this decision.
- `ai/brainstorming/specs/SPEC-S6-kubeconform-precommit.md` — the original SPEC that promised kubeconform as the first line of schema defense.
- Chainsaw runs https://github.com/lago-morph/k8-platform/actions/runs/26439096757 and https://github.com/lago-morph/k8-platform/actions/runs/26439680403 — the runs that surfaced the failure mode.
